import CicloKit
@preconcurrency import CoreBluetooth
import Foundation
import Observation
import os

/// Qué tipo de aparato es un dispositivo descubierto.
public enum DeviceKind: String, Sendable {
    case trainer = "Rodillo"
    case click = "Mando"
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

    public private(set) var clicks: [ClickState] = []
    /// Botones pulsados ahora en cualquiera de los mandos (sin duplicados).
    public private(set) var buttonsPressed: ZwiftButton = []
    /// Último botón pulsado (se queda aunque lo sueltes, para verlo bien en pantalla).
    public private(set) var lastButtonNames: [String] = []
    public private(set) var buttonPressCount = 0

    public private(set) var log: [LogEntry] = []

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
            trainerName = device.name
            trainerConnection = .connecting
            hasControl = false
            bikeData = IndoorBikeData()
            lastBikeLog = nil
        case .click:
            if !clicks.contains(where: { $0.id == p.identifier }) {
                clicks.append(ClickState(id: p.identifier, name: device.name))
            }
            updateClick(p.identifier) { $0.connection = .connecting }
        case .other:
            addLog("«\(device.name)» no es ni rodillo ni mando: conecto solo para listar sus servicios")
        }
        addLog("Conectando a «\(device.name)»…")
        central.connect(p, options: nil)
    }

    public func disconnect(_ id: UUID) {
        guard let p = peripherals[id] else { return }
        central.cancelPeripheralConnection(p)
    }

    public func disconnectTrainer() {
        if let trainer { central.cancelPeripheralConnection(trainer) }
    }

    public func requestControl() {
        send(.requestControl)
    }

    /// Modo SIM: cambia la pendiente.
    public func setGrade(_ percent: Double) {
        trainerMode = "SIM \(percent.formatted(.number.precision(.fractionLength(1)))) %"
        sendWithControl(.setSimulation(SimulationParameters(gradePercent: percent)))
    }

    /// Modo ERG: fija la potencia.
    public func setTargetPower(_ watts: Int) {
        trainerMode = "ERG \(watts) W"
        sendWithControl(.setTargetPower(watts: watts))
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
        addLog("🚴 \(power) W · \(cadence) rpm · \(speed) km/h")
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
    }

    private func handleConnect(_ p: CBPeripheral) {
        addLog("Conectado a «\(label(p))». Buscando servicios…")
        p.delegate = self
        p.discoverServices(nil)
        if p.identifier == trainer?.identifier {
            trainerConnection = .connected
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
            trainerMode = "—"
        }
        clickSyncRX[p.identifier] = nil
        updateClick(p.identifier) {
            $0.connection = .disconnected
            $0.handshakeDone = false
            $0.pressed = []
        }
        buttonAggregator.remove(source: p.identifier)
        buttonsPressed = buttonAggregator.pressed
    }

    private func handleServices(_ p: CBPeripheral, error: Error?) {
        if let error { addLog("⚠️ Error buscando servicios: \(error.localizedDescription)"); return }
        let services = p.services ?? []
        addLog("Servicios de «\(label(p))»: \(services.map(\.uuid.uuidString).joined(separator: ", "))")
        for s in services where s.uuid == Self.ftmsService || s.uuid == Self.clickService {
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
            case Self.clickAsyncUUID, Self.clickSyncTXUUID:
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
        // mientras siga encendido. Al conectar lo dejamos en llano para empezar limpios.
        if c.uuid == Self.controlPointUUID, p.identifier == trainer?.identifier {
            addLog("Rodillo listo: lo pongo en llano (SIM 0 %) para borrar el modo anterior")
            setGrade(0)
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
        do {
            switch try ZwiftClickMessage(parsing: bytes) {
            case .rideOnAck(let extra):
                addLog("← «\(label(p))»: RideOn recibido ✅ (extra [\(extra.hexString)])")
                updateClick(p.identifier) { $0.handshakeDone = true }

            case .buttons(let pressed, let raw):
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
