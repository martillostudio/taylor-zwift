import CicloKit
import Foundation
@preconcurrency import Network
import Observation
import os

/// Se anuncia en la red local como un mando OpenBikeControl (Bonjour `_openbikecontrol._tcp`)
/// y manda las pulsaciones a las apps que se conecten (MyWhoosh, TrainingPeaks Virtual…).
///
/// En MyWhoosh: pantalla de conexión → icono de OpenBikeControl (arriba a la derecha).
@MainActor
@Observable
public final class OpenBikeControlServer {
    public struct Client: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var endpoint: String
        public var ready = false
        /// Lo que la app nos cuenta de sí misma (mensaje 0x04), p. ej. «mywhoosh 5.1.0».
        public var appName: String?
    }

    public private(set) var state = "parado"
    public private(set) var isAdvertising = false
    public private(set) var port: UInt16?
    public private(set) var clients: [Client] = []
    public let deviceName: String

    /// Batería que contamos a las apps en el mensaje de estado (la del mando más bajo).
    @ObservationIgnored public var batteryPercent: Int?
    /// Mandar el mensaje 0x02 (estado/batería). Apagado: MyWhoosh no parece entenderlo
    /// y BikeControl, que funciona con MyWhoosh, no lo manda nunca.
    @ObservationIgnored public var sendsDeviceStatus = false
    /// Para mezclar nuestras líneas con el log de Bluetooth.
    @ObservationIgnored public var onLog: (@MainActor (String) -> Void)?

    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [UUID: NWConnection] = [:]
    @ObservationIgnored private var parsers: [UUID: OBCInboundParser] = [:]
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private let logger = Logger(subsystem: "studio.martillo.taylorzwift", category: "openbikecontrol")

    public init(deviceName: String, deviceID: String) {
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    // MARK: Arrancar / parar

    public func start() {
        wantsRunning = true
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let l = try NWListener(using: parameters)
            let txt = OpenBikeControl.txtRecord(
                id: deviceID, name: deviceName, manufacturer: "Taylor", model: "Zwift Click V2 bridge")
            l.service = NWListener.Service(
                name: deviceName, type: OpenBikeControl.bonjourType, domain: nil, txtRecord: NWTXTRecord(txt))
            l.stateUpdateHandler = { [weak self] newState in
                let text = "\(newState)"
                MainActor.assumeIsolated { self?.handleListenerState(newState, text: text) }
            }
            l.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            l.start(queue: .main)
            listener = l
            state = "arrancando…"
        } catch {
            state = "error: \(error.localizedDescription)"
            log("⚠️ No se pudo abrir el servidor OpenBikeControl: \(error.localizedDescription)")
        }

        if statusTimer == nil {
            statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.broadcastStatus() }
            }
        }
    }

    public func stop() {
        wantsRunning = false
        statusTimer?.invalidate()
        statusTimer = nil
        listener?.cancel()
        listener = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
        parsers.removeAll()
        clients.removeAll()
        isAdvertising = false
        port = nil
        state = "parado"
        log("Servidor OpenBikeControl parado")
    }

    // MARK: Enviar

    /// Pulsa y suelta una acción (las apps cuentan una pulsación por cada par pulsar/soltar).
    public func tap(_ action: OpenBikeControl.Action) {
        log("→ OpenBikeControl: \(action) [\(OpenBikeControl.buttonState([(action, true)]).map { String(format: "%02X", $0) }.joined(separator: " "))]")
        send(OpenBikeControl.buttonState([(action, true)]))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            self?.send(OpenBikeControl.buttonState([(action, false)]))
        }
    }

    public var readyClientCount: Int { clients.filter(\.ready).count }

    private func send(_ bytes: [UInt8]) {
        for (id, c) in connections where clients.first(where: { $0.id == id })?.ready == true {
            c.send(content: Data(bytes), completion: .contentProcessed { _ in })
        }
    }

    private func broadcastStatus() {
        guard sendsDeviceStatus else { return }
        send(OpenBikeControl.deviceStatus(batteryPercent: batteryPercent, connected: true))
    }

    // MARK: Eventos de red (todo en la cola principal)

    private func handleListenerState(_ newState: NWListener.State, text: String) {
        switch newState {
        case .ready:
            port = listener?.port?.rawValue
            isAdvertising = true
            state = "anunciado como «\(deviceName)» (puerto \(port.map(String.init) ?? "?"))"
            log("📡 OpenBikeControl: \(state)")
        case .failed(let error):
            isAdvertising = false
            state = "error: \(error)"
            log("⚠️ OpenBikeControl falló: \(error). Reintento en 3 s")
            listener?.cancel()
            listener = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if let self, self.wantsRunning { self.start() }
            }
        case .waiting(let error):
            state = "esperando red: \(error)"
            log("OpenBikeControl esperando red: \(error)")
        case .cancelled:
            isAdvertising = false
        default:
            log("OpenBikeControl: \(text)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        parsers[id] = OBCInboundParser()
        clients.append(Client(id: id, endpoint: "\(connection.endpoint)"))
        log("🔌 Una app se conecta desde \(connection.endpoint)")

        connection.stateUpdateHandler = { [weak self] newState in
            let text = "\(newState)"
            MainActor.assumeIsolated { self?.handleConnectionState(id, newState, text: text) }
        }
        connection.start(queue: .main)
        receive(id, on: connection)
    }

    private func handleConnectionState(_ id: UUID, _ newState: NWConnection.State, text: String) {
        switch newState {
        case .ready:
            updateClient(id) { $0.ready = true }
            log("✅ App conectada: \(clientName(id))")
            broadcastStatus()
        case .failed, .cancelled:
            drop(id, reason: text)
        default:
            break
        }
    }

    private func receive(_ id: UUID, on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            let bytes = data.map { [UInt8]($0) } ?? []
            let errorText = error.map { "\($0)" }
            MainActor.assumeIsolated {
                self?.handleReceived(id, bytes: bytes, isComplete: isComplete, errorText: errorText)
            }
        }
    }

    private func handleReceived(_ id: UUID, bytes: [UInt8], isComplete: Bool, errorText: String?) {
        guard let connection = connections[id] else { return }
        if !bytes.isEmpty, var parser = parsers[id] {
            let messages = parser.feed(bytes)
            parsers[id] = parser
            for m in messages { handle(m, from: id) }
        }
        if let errorText {
            drop(id, reason: errorText)
        } else if isComplete {
            drop(id, reason: "la app cerró la conexión")
        } else {
            receive(id, on: connection)
        }
    }

    private func handle(_ message: OBCInboundMessage, from id: UUID) {
        switch message {
        case .appInfo(let info):
            let name = "\(info.appID) \(info.appVersion)".trimmingCharacters(in: .whitespaces)
            updateClient(id) { $0.appName = name.isEmpty ? nil : name }
            let buttons = info.supportsAllButtons
                ? "todos"
                : info.supportedButtons.map { String(format: "0x%02X", $0) }.joined(separator: " ")
            log("ℹ️ La app es «\(name)»; entiende los botones: \(buttons)")
        case .haptic(let pattern, _, _):
            log("〰️ La app pide vibración (patrón \(pattern)); los Click no vibran, se ignora")
        case .unknown(0x00):
            break // MyWhoosh manda un 0x00 cada 4 s (¿para comprobar que seguimos vivos?)
        case .unknown(let type):
            log(String(format: "← OpenBikeControl: byte desconocido 0x%02X", type))
        }
    }

    private func drop(_ id: UUID, reason: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        log("App desconectada (\(clientName(id))): \(reason)")
        connection.stateUpdateHandler = nil
        connection.cancel()
        parsers[id] = nil
        clients.removeAll { $0.id == id }
    }

    // MARK: Utilidades

    private func updateClient(_ id: UUID, _ change: (inout Client) -> Void) {
        guard let i = clients.firstIndex(where: { $0.id == id }) else { return }
        change(&clients[i])
    }

    private func clientName(_ id: UUID) -> String {
        guard let c = clients.first(where: { $0.id == id }) else { return "?" }
        return c.appName.map { "\($0) (\(c.endpoint))" } ?? c.endpoint
    }

    private func log(_ text: String) {
        logger.log("\(text, privacy: .public)")
        onLog?(text)
    }
}
