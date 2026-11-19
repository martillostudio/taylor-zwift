import CicloBluetooth
import CicloKit
import Foundation
import Observation

/// El entrenamiento en marcha: junta la ruta, las marchas virtuales, el modo ERG,
/// los botones de los Click y lo que manda el rodillo.
///
/// Solo manda órdenes al rodillo mientras el entrenamiento está en marcha, para no
/// pisar lo que hagas a mano en la pestaña «Rodillo».
@MainActor
@Observable
final class RideController {
    enum Mode: String, CaseIterable, Identifiable {
        case route = "Ruta (SIM)"
        case erg = "ERG"
        var id: String { rawValue }
    }

    let hub: BluetoothHub

    var mode: Mode = .route {
        didSet { if mode != oldValue { applyTarget(force: true) } }
    }
    var route: Route = .rolling {
        didSet { if route != oldValue { reset() } }
    }
    private(set) var gears = VirtualGears()
    private(set) var ergWatts = 150
    private(set) var session = RideSession()
    private(set) var isRunning = false
    /// Pendiente real de la ruta donde estás (sin el efecto de las marchas).
    private(set) var currentGrade = 0.0
    /// Velocidad «de carretera»: la del rodillo × la relación de la marcha (en ERG, la del rodillo).
    private(set) var speedKmh: Double?

    static let ergStep = 10
    static let ergRange = 50...1000

    @ObservationIgnored private var lastSentTime = 0.0
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(hub: BluetoothHub) {
        self.hub = hub
        hub.onButtonPress = { [weak self] pressed in self?.handleButtons(pressed) }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: Acciones

    func start() {
        guard !isRunning else { return }
        isRunning = true
        hub.appendLog("▶︎ Entrenamiento en marcha (\(mode == .route ? route.name : "ERG \(ergWatts) W"))")
        applyTarget(force: true)
    }

    func pause() {
        guard isRunning else { return }
        isRunning = false
        session.pause()
        hub.appendLog("⏸ Entrenamiento en pausa")
    }

    func reset() {
        session = RideSession()
        currentGrade = route.grade(atDistance: 0)
        hub.appendLog("⟲ Entrenamiento a cero (\(route.name))")
        applyTarget(force: true)
    }

    /// Más duro: una marcha más en SIM, +10 W en ERG.
    func harder() {
        switch mode {
        case .route:
            if gears.shiftUp() { hub.appendLog("⚙️ Marcha \(gears.number)/\(gears.count) (×\(ratioText))") }
        case .erg:
            ergWatts = min(ergWatts + Self.ergStep, Self.ergRange.upperBound)
            hub.appendLog("⚙️ ERG \(ergWatts) W")
        }
        applyTarget(force: true)
    }

    /// Más blando: una marcha menos en SIM, −10 W en ERG.
    func easier() {
        switch mode {
        case .route:
            if gears.shiftDown() { hub.appendLog("⚙️ Marcha \(gears.number)/\(gears.count) (×\(ratioText))") }
        case .erg:
            ergWatts = max(ergWatts - Self.ergStep, Self.ergRange.lowerBound)
            hub.appendLog("⚙️ ERG \(ergWatts) W")
        }
        applyTarget(force: true)
    }

    var ratioText: String { gears.ratio.formatted(.number.precision(.fractionLength(2))) }

    // MARK: Interno

    /// Los mismos botones que en «Taylor Mandos»: + / Z suben marcha, − / Y bajan.
    private func handleButtons(_ pressed: ZwiftButton) {
        for action in BridgeMapping.actions(for: pressed) {
            switch action {
            case .shiftUp: harder()
            case .shiftDown: easier()
            default: break
            }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let data = hub.bikeData
        let trainerConnected = hub.trainerConnection == .connected

        if trainerConnected, let kmh = data.speedKmh {
            speedKmh = mode == .route ? gears.virtualSpeed(fromTrainerKmh: kmh) : kmh
        } else {
            speedKmh = nil
        }

        if isRunning {
            if trainerConnected {
                session.update(
                    speedKmh: speedKmh ?? 0,
                    powerWatts: data.powerWatts ?? 0,
                    cadenceRpm: data.cadenceRpm ?? 0,
                    at: now
                )
            } else {
                session.pause() // sin datos: no integramos el hueco
            }
            if mode == .route {
                currentGrade = route.grade(atDistance: session.distanceMeters)
            }
        }
        applyTarget(force: false, now: now)
    }

    private var desiredTarget: TrainerTarget {
        switch mode {
        case .route: .simulation(gears.simulation(gradePercent: currentGrade))
        case .erg: .targetPower(watts: ergWatts)
        }
    }

    /// Manda el objetivo al rodillo si ha cambiado. Los cambios de la ruta se mandan como
    /// mucho una vez por segundo; los de botones y modo (`force`), al momento.
    private func applyTarget(force: Bool, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard isRunning, hub.trainerConnection == .connected else { return }
        let target = desiredTarget
        // Comparamos con lo último que tiene el hub (también lo que mandes a mano en «Rodillo»
        // o lo que recupera él solo al reconectar).
        guard !target.isSameOnTheWire(as: hub.trainerTarget) else { return }
        guard force || now - lastSentTime >= 1 else { return }
        lastSentTime = now
        hub.apply(target)
    }
}
