import CicloKit
@preconcurrency import CoreBluetooth
import Foundation
import Observation
import os

/// Qué tipo de aparato es un dispositivo descubierto.
public enum DeviceKind: String, Sendable {
    case trainer = "Rodillo"
    case click = "Mando"
    case heartRate = "Pulsómetro"
    case other = "Otro"
}

public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var rssi: Int
    public var kind: DeviceKind
    public var advertisedServices: [String]
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected

    public var description: String {
        switch self {
        case .disconnected: "desconectado"
        case .connecting: "conectando…"
        case .connected: "conectado"
        }
    }
}

/// Estado de un mando Zwift Click conectado.
public struct ClickState: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var connection: ConnectionState = .connecting
    public var handshakeDone = false
    /// Botones que **este** mando dice que están pulsados (puede incluir los reenviados del otro).
    public var pressed: ZwiftButton = []
    public var rawMap: UInt32?
    public var batteryPercent: Int?
    /// Se ha dormido: los Click se apagan solos tras un rato sin pulsarlos (para ahorrar batería).
    /// La app lo tiene en espera; una pulsación lo despierta, pero esa primera no cuenta.
    public var asleep = false

    /// Los dos Click se llaman igual: usamos el principio de su identificador para distinguirlos.
    public var shortID: String { String(id.uuidString.prefix(4)) }
    public var label: String { "\(name) \(shortID)" }
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let text: String
}

/// Toda la parte de Bluetooth: escanear, conectar al rodillo (FTMS) y a los mandos (Zwift Click).
///
/// Esta clase es la capa fina que solo se puede probar con hardware real.
/// La interpretación de bytes está en `CicloKit` y tiene tests.
@MainActor
@Observable
public final class BluetoothHub: NSObject {
    // MARK: Estado visible

    public private(set) var bluetoothState = "iniciando…"
    public private(set) var isScanning = false
    public private(set) var devices: [DiscoveredDevice] = []

    public private(set) var trainerName: String?
    public private(set) var trainerConnection: ConnectionState = .disconnected
    public private(set) var bikeData = IndoorBikeData()
    public private(set) var hasControl = false
    public private(set) var lastControlResult = "—"
    public private(set) var lastMachineStatus = "—"
    /// Último modo que le hemos mandado al rodillo («SIM 0,0 %», «ERG 150 W»…).
    public private(set) var trainerMode = "—"
    /// Último objetivo mandado: se vuelve a mandar si el rodillo se desconecta y vuelve.
    public private(set) var trainerTarget: TrainerTarget?

    public private(set) var clicks: [ClickState] = []

    public private(set) var heartRateName: String?
    public private(set) var heartRateConnection: ConnectionState = .disconnected
    /// Pulsaciones del pulsómetro (o del rodillo, si se lo pasa él). `nil` si no hay dato.
    public private(set) var heartRateBpm: Int?
    /// Botones pulsados ahora en cualquiera de los mandos (sin duplicados).
    public private(set) var buttonsPressed: ZwiftButton = []
    /// Último botón pulsado (se queda aunque lo sueltes, para verlo bien en pantalla).
    public private(set) var lastButtonNames: [String] = []
    public private(set) var buttonPressCount = 0

    public private(set) var log: [LogEntry] = []

    // MARK: Modo puente (app «Taylor Mandos»)

    /// Busca y conecta solos los mandos, y los reconecta si se caen. Ver `startBridgeMode()`.
    public private(set) var autoConnectClicks = false
    /// Se llama con cada pulsación nueva, ya sin ecos del otro mando.
    @ObservationIgnored public var onButtonPress: (@MainActor (ZwiftButton) -> Void)?
    /// Un mando se ha dormido (`false`) o se ha despertado y está listo (`true`).
    @ObservationIgnored public var onClickAwake: (@MainActor (_ label: String, _ awake: Bool) -> Void)?
    /// Segundos sin noticias de un mando (los Click mandan la batería cada ~5 s) antes de reconectarlo.
    @ObservationIgnored public var silenceBeforeReconnect: Double = 20
    @ObservationIgnored private var lastClickMessage: [UUID: Double] = [:]
    /// Segundos sin pulsaciones del mando izquierdo antes de «refrescarlo» (reconectarlo).
    /// El izquierdo puede seguir conectado y mandando estado pero dejar de mandar botones
    /// a apps que no son Zwift (guía §5.1); reconectarlo es lo que hace BikeControl.
    @ObservationIgnored public var leftRefreshSeconds: Double = 60
    @ObservationIgnored private var lastClickButtons: [UUID: Double] = [:]
    /// Conectar solo el primer rodillo que aparezca (ver `connectEverything()`).
    @ObservationIgnored private var autoConnectTrainer = false
    @ObservationIgnored private var heartRateMonitor: CBPeripheral?
    @ObservationIgnored private var heartRateWanted = false
    /// El usuario quiere el rodillo conectado: si se cae, lo reconectamos.
    @ObservationIgnored private var trainerWanted = false
    /// Mandos que el usuario ha desconectado a mano: esos no se reconectan solos.
    @ObservationIgnored private var userDisconnected: Set<UUID> = []
    @ObservationIgnored private var watchdog: Timer?

    // MARK: CoreBluetooth

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var trainer: CBPeripheral?
    @ObservationIgnored private var controlPoint: CBCharacteristic?
    @ObservationIgnored private var clickSyncRX: [UUID: CBCharacteristic] = [:]
    /// Comando que espera a que el rodillo nos conceda el control.
    @ObservationIgnored private var commandAfterControl: FTMSCommand?
    @ObservationIgnored private var buttonAggregator = ZwiftButtonAggregator<UUID>()
    @ObservationIgnored private var lastBikeLog: (date: Date, idle: Bool)?

    @ObservationIgnored private let logger = Logger(subsystem: "studio.martillo.taylorzwift", category: "bluetooth")

    private static let ftmsService = CBUUID(string: FTMSUUID.service)
    private static let bikeDataUUID = CBUUID(string: FTMSUUID.indoorBikeData)
    private static let controlPointUUID = CBUUID(string: FTMSUUID.controlPoint)
    private static let machineStatusUUID = CBUUID(string: FTMSUUID.machineStatus)
    private static let clickService = CBUUID(string: ZwiftClickUUID.service)
    private static let clickAsyncUUID = CBUUID(string: ZwiftClickUUID.async)
    private static let clickSyncRXUUID = CBUUID(string: ZwiftClickUUID.syncRX)
    private static let clickSyncTXUUID = CBUUID(string: ZwiftClickUUID.syncTX)
    private static let heartRateService = CBUUID(string: HeartRateUUID.service)
    private static let heartRateMeasurementUUID = CBUUID(string: HeartRateUUID.measurement)

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        addLog("App iniciada")
    }

    // MARK: Acciones

    public func startScan() {
        guard central.state == .poweredOn else {
            addLog("No se puede escanear: Bluetooth \(bluetoothState)")
            return
        }
        devices.removeAll { !isConnected($0.id) }
        central.scanForPeripherals(withServices: nil, options: nil)
        isScanning = true
        addLog("Escaneando…")
    }

    public func stopScan() {
        central.stopScan()
        isScanning = false
        addLog("Escaneo parado")
    }

    public func connect(_ device: DiscoveredDevice) {
        guard let p = peripherals[device.id] else { return }
        switch device.kind {
        case .trainer:
            if let old = trainer, old.identifier != p.identifier { central.cancelPeripheralConnection(old) }
            trainer = p
            trainerWanted = true
            trainerName = device.name
            trainerConnection = .connecting
            hasControl = false
            bikeData = IndoorBikeData()
            lastBikeLog = nil
        case .click:
            if !clicks.contains(where: { $0.id == p.identifier }) {
                clicks.append(ClickState(id: p.identifier, name: device.name))
            }
            userDisconnected.remove(p.identifier)
            updateClick(p.identifier) { $0.connection = .connecting }
        case .heartRate:
            if let old = heartRateMonitor, old.identifier != p.identifier { central.cancelPeripheralConnection(old) }
            heartRateMonitor = p
            heartRateWanted = true
            heartRateName = device.name
            heartRateConnection = .connecting
            heartRateBpm = nil
        case .other:
            addLog("«\(device.name)» no es ni rodillo ni mando: conecto solo para listar sus servicios")
        }
        addLog("Conectando a «\(device.name)»…")
        central.connect(p, options: nil)
    }

    public func disconnect(_ id: UUID) {
        guard let p = peripherals[id] else { return }
        userDisconnected.insert(id)
        central.cancelPeripheralConnection(p)
    }

    public func disconnectHeartRate() {
        heartRateWanted = false
        if let heartRateMonitor { central.cancelPeripheralConnection(heartRateMonitor) }
    }

    public func disconnectTrainer() {
        trainerWanted = false
        autoConnectTrainer = false
        if let trainer { central.cancelPeripheralConnection(trainer) }
    }

    public func requestControl() {
        send(.requestControl)
    }

    /// Modo SIM: cambia la pendiente.
    public func setGrade(_ percent: Double) {
        apply(.simulation(SimulationParameters(gradePercent: percent)))
    }

    /// Modo ERG: fija la potencia.
    public func setTargetPower(_ watts: Int) {
        apply(.targetPower(watts: watts))
    }

    /// Manda un objetivo al rodillo (pidiendo antes el control si hace falta) y lo recuerda
    /// para volver a mandarlo si el rodillo se reconecta.
    public func apply(_ target: TrainerTarget) {
        trainerTarget = target
        trainerMode = target.description
        sendWithControl(target.command)
    }

    /// Conecta solo el rodillo y los mandos que encuentre, y los reconecta si se caen.
    public func connectEverything() {
        autoConnectTrainer = true
        if !autoConnectClicks {
            startAutoConnectClicks(log: "Conexión automática: rodillo y mandos (y reconexión si se caen)")
        } else if central.state == .poweredOn, !isScanning {
            startScan()
        }
        // Si ya habíamos visto un rodillo, no hace falta esperar al escaneo.
        if trainerConnection == .disconnected, let t = devices.first(where: { $0.kind == .trainer }) {
            connect(t)
        }
        if heartRateConnection == .disconnected, let h = devices.first(where: { $0.kind == .heartRate }) {
            connect(h)
        }
    }

    /// Modo puente: escanea, conecta todos los Click que encuentre y los mantiene conectados.
    /// No toca el rodillo (lo controla la otra app, p. ej. MyWhoosh).
    public func startBridgeMode() {
        guard !autoConnectClicks else { return }
        startAutoConnectClicks(log: "Modo puente: conecto los mandos automáticamente y los reconecto si se caen")
    }

    private func startAutoConnectClicks(log text: String) {
        autoConnectClicks = true
        addLog(text)
        if central.state == .poweredOn {
            startScan()
            adoptSystemConnectedClicks()
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkSilentClicks()
                self?.adoptSystemConnectedClicks()
            }
        }
    }

    /// Añade una línea al log desde fuera (p. ej. el servidor OpenBikeControl).
    public func appendLog(_ text: String) {
        addLog(text)
    }

    public func clearLog() {
        log.removeAll()
    }

    public var logText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return log.map { "\(f.string(from: $0.date))  \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Interno

    private func isConnected(_ id: UUID) -> Bool {
        peripherals[id]?.state == .connected
    }

    /// Un mando que ya está conectado al sistema (por otra app o por macOS) deja de anunciarse
    /// y el escaneo no lo ve. Se los pedimos directamente a CoreBluetooth.
    private func adoptSystemConnectedClicks() {
        guard autoConnectClicks, central.state == .poweredOn else { return }
        for p in central.retrieveConnectedPeripherals(withServices: [Self.clickService]) {
            let known = clicks.first(where: { $0.id == p.identifier })
            guard (known?.connection ?? .disconnected) == .disconnected else { continue }
            if known == nil {
                addLog("Mando ya conectado al sistema: «\(p.name ?? "?")» [\(p.identifier.uuidString.prefix(4))]; me conecto también")
            }
            handleDiscovery(p, localName: nil, services: [ZwiftClickUUID.service], rssi: 0)
        }
    }

    /// Si un mando conectado se queda callado (¿bloqueado?), lo desconectamos para que se reconecte.
    private func checkSilentClicks() {
        let now = ProcessInfo.processInfo.systemUptime
        // Solo vigilamos los mandos que mandan la batería cada pocos segundos (el izquierdo);
        // el derecho se queda callado en reposo y reconectarlo solo haría perder pulsaciones.
        for click in clicks where click.connection == .connected && click.handshakeDone && click.batteryPercent != nil {
            guard let last = lastClickMessage[click.id] else { continue }
            if now - last > silenceBeforeReconnect, let p = peripherals[click.id] {
                addLog("⏱ «\(click.label)» lleva \(Int(now - last)) s sin mandar nada: lo reconecto")
                lastClickMessage[click.id] = now
                central.cancelPeripheralConnection(p)
            } else if let buttons = lastClickButtons[click.id], now - buttons > leftRefreshSeconds,
                      let p = peripherals[click.id] {
                // Conectado pero sin botones: puede estar bloqueado. Lo refrescamos en silencio
                // (tarda 1–2 s; una pulsación justo en ese momento se pierde).
                addLog("🔄 «\(click.label)» lleva \(Int(now - buttons)) s sin botones: lo refresco por si se ha bloqueado")
                lastClickButtons[click.id] = now
                central.cancelPeripheralConnection(p)
            }
        }
    }

    private func sendWithControl(_ command: FTMSCommand) {
        if hasControl {
            send(command)
        } else {
            commandAfterControl = command
            send(.requestControl)
        }
    }

    private func send(_ command: FTMSCommand) {
        guard let trainer, let controlPoint, trainer.state == .connected else {
            addLog("⚠️ No hay rodillo conectado (o aún no se ha encontrado su Control Point)")
            return
        }
        addLog("→ Rodillo: \(FTMSCommand.name(ofOpcode: command.opcode)) [\(command.bytes.hexString)]")
        trainer.writeValue(Data(command.bytes), for: controlPoint, type: .withResponse)
    }

    private func updateClick(_ id: UUID, _ change: (inout ClickState) -> Void) {
        guard let i = clicks.firstIndex(where: { $0.id == id }) else { return }
        change(&clicks[i])
    }

    /// Nombre para el log: los mandos llevan además el principio de su identificador.
    private func label(_ p: CBPeripheral) -> String {
        clicks.first(where: { $0.id == p.identifier })?.label ?? p.name ?? "?"
    }

    private func logBikeDataIfNeeded() {
        let d = bikeData
        let idle = (d.powerWatts ?? 0) == 0 && (d.cadenceRpm ?? 0) == 0
        let now = Date()
        if let last = lastBikeLog {
            if now.timeIntervalSince(last.date) < 1 { return }
            if idle && last.idle { return } // parado: no llenamos el log de ceros
        }
        lastBikeLog = (now, idle)
        let power = d.powerWatts.map { "\($0)" } ?? "—"
        let cadence = d.cadenceRpm.map { "\(Int($0))" } ?? "—"
        let speed = d.speedKmh.map { String(format: "%.1f", $0) } ?? "—"
        let heart = heartRateBpm.map { " · ❤️ \($0)" } ?? ""
        addLog("🚴 \(power) W · \(cadence) rpm · \(speed) km/h\(heart)")
    }

    private func addLog(_ text: String) {
        logger.log("\(text, privacy: .public)")
        log.append(LogEntry(date: Date(), text: text))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }

    private static func classify(name: String, services: [String]) -> DeviceKind {
        let services = services.map { $0.uppercased() }
        if services.contains(FTMSUUID.service) { return .trainer }
        if services.contains(ZwiftClickUUID.service) { return .click }
        if services.contains(HeartRateUUID.service) { return .heartRate }
        let lower = name.lowercased()
        if lower.contains("zwift click") || lower.contains("zwift ride") { return .click }
        if lower.hasPrefix("kickr") { return .trainer }
        return .other
    }

    // MARK: Gestión de eventos (siempre en el hilo principal)

    private func handleStateUpdate(_ state: CBManagerState) {
        bluetoothState = switch state {
        case .poweredOn: "encendido"
        case .poweredOff: "apagado"
        case .unauthorized: "sin permiso (Ajustes → Privacidad → Bluetooth)"
        case .unsupported: "no soportado en este dispositivo"
        case .resetting: "reiniciándose"
        case .unknown: "desconocido"
        @unknown default: "estado \(state.rawValue)"
        }
        addLog("Bluetooth: \(bluetoothState)")
        if state != .poweredOn {
            isScanning = false
        } else if autoConnectClicks && !isScanning {
            startScan()
            adoptSystemConnectedClicks()
        }
    }

    private func handleDiscovery(_ p: CBPeripheral, localName: String?, services: [String], rssi: Int) {
        let name = p.name ?? localName ?? "(sin nombre)"
        let kind = Self.classify(name: name, services: services)
        peripherals[p.identifier] = p

        let device = DiscoveredDevice(
            id: p.identifier, name: name, rssi: rssi, kind: kind,
            advertisedServices: services
        )
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            devices[i] = device
        } else {
            devices.append(device)
            if kind != .other {
                addLog("Encontrado \(kind.rawValue.lowercased()): «\(name)» [\(p.identifier.uuidString.prefix(4))] (RSSI \(rssi), servicios \(device.advertisedServices))")
            }
        }

        if autoConnectClicks, kind == .click, !userDisconnected.contains(p.identifier),
           (clicks.first(where: { $0.id == p.identifier })?.connection ?? .disconnected) == .disconnected {
            connect(device)
        }
        if autoConnectTrainer, kind == .trainer, trainer == nil, trainerConnection == .disconnected {
            connect(device)
        }
        // El primer pulsómetro que aparezca (junto con el rodillo, en la conexión automática).
        if autoConnectTrainer, kind == .heartRate, heartRateMonitor == nil, heartRateConnection == .disconnected {
            connect(device)
        }
    }

    private func handleConnect(_ p: CBPeripheral) {
        addLog("Conectado a «\(label(p))». Buscando servicios…")
        p.delegate = self
        p.discoverServices(nil)
        if p.identifier == trainer?.identifier {
            trainerConnection = .connected
        } else if p.identifier == heartRateMonitor?.identifier {
            heartRateConnection = .connected
        } else {
            updateClick(p.identifier) { $0.connection = .connected }
        }
    }

    private func handleDisconnect(_ p: CBPeripheral, error: Error?) {
        addLog("Desconectado de «\(label(p))»\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if p.identifier == trainer?.identifier {
            trainerConnection = .disconnected
            hasControl = false
            controlPoint = nil
            commandAfterControl = nil
            if trainerWanted {
                // CoreBluetooth deja la conexión pendiente y conecta en cuanto el rodillo vuelve.
                trainerConnection = .connecting
                addLog("↻ Reconectando «\(label(p))»…")
                central.connect(p, options: nil)
            } else {
                trainerMode = "—"
                trainerTarget = nil
            }
        }
        if p.identifier == heartRateMonitor?.identifier {
            heartRateBpm = nil
            if heartRateWanted {
                heartRateConnection = .connecting
                addLog("↻ Reconectando «\(label(p))»…")
                central.connect(p, options: nil)
            } else {
                heartRateConnection = .disconnected
            }
        }
        clickSyncRX[p.identifier] = nil
        updateClick(p.identifier) {
            $0.connection = .disconnected
            $0.handshakeDone = false
            $0.pressed = []
        }
        buttonAggregator.remove(source: p.identifier)
        buttonsPressed = buttonAggregator.pressed

        // Volvemos a pedir la conexión (salvo que el usuario lo haya desconectado a mano).
        // CoreBluetooth la deja pendiente y conecta en cuanto el mando vuelve a estar a tiro.
        if clicks.contains(where: { $0.id == p.identifier }), !userDisconnected.contains(p.identifier) {
            // Si se cae solo (no lo hemos cortado nosotros), casi siempre es que se ha dormido:
            // los Click se apagan tras un rato sin pulsarlos y solo vuelven al pulsar un botón.
            let slept = error != nil
            updateClick(p.identifier) {
                $0.connection = .connecting
                $0.asleep = slept
            }
            if slept {
                addLog("💤 «\(label(p))» se ha dormido (un rato sin pulsarlo). Lo espero: púlsalo una vez para despertarlo (esa pulsación no cuenta)")
                onClickAwake?(label(p), false)
            } else {
                addLog("↻ Reconectando «\(label(p))»…")
            }
            central.connect(p, options: nil)
        }
    }

    private func handleServices(_ p: CBPeripheral, error: Error?) {
        if let error { addLog("⚠️ Error buscando servicios: \(error.localizedDescription)"); return }
        let services = p.services ?? []
        addLog("Servicios de «\(label(p))»: \(services.map(\.uuid.uuidString).joined(separator: ", "))")
        for s in services where s.uuid == Self.ftmsService || s.uuid == Self.clickService || s.uuid == Self.heartRateService {
            p.discoverCharacteristics(nil, for: s)
        }
        if p.identifier == trainer?.identifier, !services.contains(where: { $0.uuid == Self.ftmsService }) {
            addLog("⚠️ Este dispositivo no tiene el servicio FTMS (1826)")
        }
    }

    private func handleCharacteristics(_ p: CBPeripheral, service: CBService, error: Error?) {
        if let error { addLog("⚠️ Error buscando características: \(error.localizedDescription)"); return }
        let chars = service.characteristics ?? []
        addLog("Características de \(service.uuid.uuidString): \(chars.map(\.uuid.uuidString).joined(separator: ", "))")

        for c in chars {
            switch c.uuid {
            case Self.bikeDataUUID, Self.machineStatusUUID:
                p.setNotifyValue(true, for: c)
            case Self.controlPointUUID:
                controlPoint = c
                p.setNotifyValue(true, for: c) // las respuestas llegan como «indicate»
            case Self.clickAsyncUUID, Self.clickSyncTXUUID, Self.heartRateMeasurementUUID:
                p.setNotifyValue(true, for: c)
            case Self.clickSyncRXUUID:
                clickSyncRX[p.identifier] = c
            default:
                break
            }
        }
    }

    private func handleNotificationState(_ p: CBPeripheral, characteristic c: CBCharacteristic, error: Error?) {
        if let error {
            addLog("⚠️ No se pudo suscribir a \(c.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        addLog("Suscrito a \(c.uuid.uuidString)")
        // El rodillo recuerda el último modo (p. ej. un ERG de otra sesión o de otra app)
        // mientras siga encendido. Al conectar lo dejamos en llano para empezar limpios;
        // si es una reconexión, recuperamos lo que estábamos haciendo.
        if c.uuid == Self.controlPointUUID, p.identifier == trainer?.identifier {
            if let target = trainerTarget {
                addLog("Rodillo listo: recupero el modo anterior (\(target.description))")
                apply(target)
            } else {
                addLog("Rodillo listo: lo pongo en llano (SIM 0 %) para borrar el modo anterior")
                apply(.flat)
            }
        }
        // Cuando ya escuchamos las respuestas del mando, le mandamos el saludo.
        if c.uuid == Self.clickSyncTXUUID, let rx = clickSyncRX[p.identifier] {
            let type: CBCharacteristicWriteType = rx.properties.contains(.write) ? .withResponse : .withoutResponse
            addLog("→ «\(label(p))»: RideOn [\(ZwiftClickProtocol.rideOn.hexString)]")
            p.writeValue(Data(ZwiftClickProtocol.rideOn), for: rx, type: type)
        }
    }

    private func handleValue(_ p: CBPeripheral, characteristic c: CBCharacteristic, error: Error?) {
        if let error { addLog("⚠️ Error leyendo \(c.uuid.uuidString): \(error.localizedDescription)"); return }
        let bytes = [UInt8](c.value ?? Data())

        switch c.uuid {
        case Self.bikeDataUUID:
            do {
                bikeData = bikeData.merging(try IndoorBikeData(parsing: bytes))
                // Si no hay pulsómetro conectado y el rodillo trae pulsaciones, las usamos.
                if heartRateConnection != .connected, let hr = bikeData.heartRateBpm, hr > 0 {
                    heartRateBpm = hr
                }
                logBikeDataIfNeeded()
            } catch { addLog("⚠️ Indoor Bike Data no válido [\(bytes.hexString)]: \(error)") }

        case Self.controlPointUUID:
            handleControlPointResponse(bytes)

        case Self.machineStatusUUID:
            do {
                let status = try MachineStatus(parsing: bytes)
                lastMachineStatus = status.description
                addLog("← Estado del rodillo: \(status.description)")
                if status == .controlPermissionLost { hasControl = false }
            } catch { addLog("⚠️ Machine Status no válido [\(bytes.hexString)]") }

        case Self.clickAsyncUUID, Self.clickSyncTXUUID:
            handleClickMessage(p, bytes: bytes, channel: c.uuid == Self.clickAsyncUUID ? "async" : "syncTX")

        case Self.heartRateMeasurementUUID:
            do {
                let m = try HeartRateMeasurement(parsing: bytes)
                heartRateBpm = m.skinContact == false || m.bpm == 0 ? nil : m.bpm
            } catch { addLog("⚠️ Medida del pulsómetro no válida [\(bytes.hexString)]") }

        default:
            addLog("← \(c.uuid.uuidString): [\(bytes.hexString)]")
        }
    }

    private func handleControlPointResponse(_ bytes: [UInt8]) {
        do {
            let r = try ControlPointResponse(parsing: bytes)
            let what = FTMSCommand.name(ofOpcode: r.requestOpcode)
            lastControlResult = "\(what): \(r.result.description)"
            addLog("← Rodillo: \(lastControlResult)")

            if r.requestOpcode == FTMSCommand.requestControl.opcode {
                hasControl = r.result == .success
                if hasControl, let next = commandAfterControl {
                    commandAfterControl = nil
                    send(next)
                } else if !hasControl {
                    commandAfterControl = nil
                }
            } else if r.result == .controlNotPermitted {
                hasControl = false
            }
        } catch {
            addLog("⚠️ Respuesta del Control Point no válida [\(bytes.hexString)]")
        }
    }

    private func handleClickMessage(_ p: CBPeripheral, bytes: [UInt8], channel: String) {
        lastClickMessage[p.identifier] = ProcessInfo.processInfo.systemUptime
        do {
            switch try ZwiftClickMessage(parsing: bytes) {
            case .rideOnAck(let extra):
                addLog("← «\(label(p))»: RideOn recibido ✅ (extra [\(extra.hexString)])")
                var wasAsleep = false
                updateClick(p.identifier) {
                    wasAsleep = $0.asleep
                    $0.handshakeDone = true
                    $0.asleep = false
                }
                lastClickButtons[p.identifier] = ProcessInfo.processInfo.systemUptime
                if wasAsleep {
                    addLog("☀️ «\(label(p))» despierto y listo")
                    onClickAwake?(label(p), true)
                }

            case .buttons(let pressed, let raw):
                lastClickButtons[p.identifier] = ProcessInfo.processInfo.systemUptime
                var newForThisClick: ZwiftButton = []
                updateClick(p.identifier) { s in
                    newForThisClick = pressed.subtracting(s.pressed)
                    s.pressed = pressed
                    s.rawMap = raw
                    s.handshakeDone = true
                }
                let newOverall = buttonAggregator.update(
                    source: p.identifier, pressed: pressed, at: ProcessInfo.processInfo.systemUptime)
                buttonsPressed = buttonAggregator.pressed
                if !newOverall.isEmpty {
                    lastButtonNames = newOverall.names
                    buttonPressCount += 1
                    addLog("🔘 \(newOverall.names.joined(separator: " + ")) — vía «\(label(p))» (mapa 0x\(String(raw, radix: 16, uppercase: true)))")
                    onButtonPress?(newOverall)
                } else if !newForThisClick.isEmpty {
                    addLog("   ↺ eco de \(newForThisClick.names.joined(separator: " + ")) vía «\(label(p))» (ignorado)")
                }

            case .battery(let percent):
                var changed = false
                updateClick(p.identifier) { s in
                    changed = s.batteryPercent != percent
                    s.batteryPercent = percent
                }
                if changed { addLog("🔋 «\(label(p))»: \(percent) %") }

            case .other(0xFF, _):
                break // estado interno del mando (cada pocos minutos); no aporta nada al log
            case .other(let opcode, let payload):
                addLog(String(format: "← «%@» (%@) opcode 0x%02X: [%@]", label(p), channel, opcode, payload.hexString))
            }
        } catch {
            addLog("⚠️ Mensaje del mando no válido (\(channel)) [\(bytes.hexString)]")
        }
    }

    private func handleWrite(_ p: CBPeripheral, characteristic c: CBCharacteristic, error: Error?) {
        if let error {
            addLog("⚠️ Error escribiendo en \(c.uuid.uuidString): \(error.localizedDescription)")
        }
    }
}

// MARK: - Delegados de CoreBluetooth
// CoreBluetooth nos llama en la cola principal (la pasamos en `CBCentralManager(queue: .main)`),
// así que podemos saltar al MainActor sin esperas.

extension BluetoothHub: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { handleStateUpdate(state) }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map(\.uuidString)
        MainActor.assumeIsolated {
            handleDiscovery(peripheral, localName: localName, services: services, rssi: rssi)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { handleConnect(peripheral) }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        MainActor.assumeIsolated {
            addLog("⚠️ No se pudo conectar a «\(peripheral.name ?? "?")»: \(error?.localizedDescription ?? "sin detalle")")
            handleDisconnect(peripheral, error: nil)
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        MainActor.assumeIsolated { handleDisconnect(peripheral, error: error) }
    }
}

extension BluetoothHub: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { handleServices(peripheral, error: error) }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        MainActor.assumeIsolated { handleCharacteristics(peripheral, service: service, error: error) }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        MainActor.assumeIsolated { handleNotificationState(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        MainActor.assumeIsolated { handleValue(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        MainActor.assumeIsolated { handleWrite(peripheral, characteristic: characteristic, error: error) }
    }
}
