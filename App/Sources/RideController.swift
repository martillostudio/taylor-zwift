import CicloBluetooth
import CicloKit
import Foundation
import Observation

/// El entrenamiento en marcha: junta la ruta, las marchas virtuales, el modo ERG,
/// los botones de los Click y lo que mandan el rodillo y el pulsómetro.
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
    /// Cada cuánto se escribe en el log una línea con el estado del entrenamiento.
    static let statusLogSeconds = 5.0

    @ObservationIgnored private var calibration = TrainerCalibration()
    @ObservationIgnored private var lastSentTime = 0.0
    @ObservationIgnored private var lastStatusLog = 0.0
    @ObservationIgnored private var lastClimbAnnounced: Double?
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

    /// Desarrollo de la bici (carretera 2×12, monoplato…). Al cambiarlo te quedas en la marcha más parecida.
    var drivetrain: Drivetrain {
        get { gears.drivetrain }
        set {
            guard newValue != gears.drivetrain else { return }
            gears.change(to: newValue)
            hub.appendLog("⚙️ Desarrollo: \(newValue.name) · marcha \(gearText)")
            applyTarget(force: true)
        }
    }

    /// La subida en la que estás o la que viene (en los próximos 2 km).
    var climbStatus: ClimbStatus? {
        mode == .route ? route.climbStatus(atDistance: session.distanceMeters) : nil
    }

    var gearText: String { "\(gears.number)/\(gears.count) (\(gears.gear.label))" }

    // MARK: Acciones

    func start() {
        guard !isRunning else { return }
        isRunning = true
        hub.appendLog("▶︎ Entrenamiento en marcha (\(mode == .route ? "\(route.name), marcha \(gearText)" : "ERG \(ergWatts) W"))")
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
        lastClimbAnnounced = nil
        hub.appendLog("⟲ Entrenamiento a cero (\(route.name))")
        applyTarget(force: true)
    }

    /// Más duro: una marcha más en SIM, +10 W en ERG.
    func harder() {
        switch mode {
        case .route:
            if gears.shiftUp() {
                hub.appendLog("⚙️ Marcha \(gearText)")
            } else {
                hub.appendLog("⚙️ Ya vas en la marcha más dura (\(gearText))")
            }
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
            if gears.shiftDown() {
                hub.appendLog("⚙️ Marcha \(gearText)")
            } else {
                hub.appendLog("⚙️ Ya vas en la marcha más blanda (\(gearText))")
            }
        case .erg:
            ergWatts = max(ergWatts - Self.ergStep, Self.ergRange.lowerBound)
            hub.appendLog("⚙️ ERG \(ergWatts) W")
        }
        applyTarget(force: true)
    }

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

        // Afinamos cuánto avanza el rodillo por pedalada (de ello depende cómo se sienten las marchas).
        if trainerConnected, let kmh = data.speedKmh, let rpm = data.cadenceRpm {
            calibration.add(speedKmh: kmh, cadenceRpm: rpm)
            if abs(calibration.trainerRatio - gears.trainerRatio) > 0.005 {
                gears.trainerRatio = calibration.trainerRatio
            }
        }

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
                    heartRateBpm: hub.heartRateBpm,
                    at: now
                )
            } else {
                session.pause() // sin datos: no integramos el hueco
            }
            if mode == .route {
                currentGrade = route.grade(atDistance: session.distanceMeters)
                announceClimb()
            }
            if now - lastStatusLog >= Self.statusLogSeconds {
                lastStatusLog = now
                logStatus()
            }
        }
        applyTarget(force: false, now: now)
    }

    private func logStatus() {
        let km = (session.distanceMeters / 1000).formatted(.number.precision(.fractionLength(2)))
        let speed = speedKmh.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
        let heart = hub.heartRateBpm.map { " · ❤️ \($0)" } ?? ""
        switch mode {
        case .route:
            let grade = currentGrade.formatted(.number.precision(.fractionLength(1)))
            let k = gears.k.formatted(.number.precision(.fractionLength(2)))
            hub.appendLog("🛣 km \(km) · pendiente \(grade) % · marcha \(gearText) ×\(k) · \(speed) km/h\(heart)")
        case .erg:
            hub.appendLog("🛣 km \(km) · ERG \(ergWatts) W · \(speed) km/h\(heart)")
        }
    }

    /// Avisa en el log al llegar al pie de una subida.
    private func announceClimb() {
        guard let status = climbStatus, status.isOnClimb else {
            lastClimbAnnounced = nil // así en una ruta circular se vuelve a avisar en cada vuelta
            return
        }
        guard lastClimbAnnounced != status.climb.id else { return }
        lastClimbAnnounced = status.climb.id
        let c = status.climb
        let km = (c.lengthMeters / 1000).formatted(.number.precision(.fractionLength(1)))
        let avg = c.averageGradePercent.formatted(.number.precision(.fractionLength(1)))
        hub.appendLog("⛰ Empieza la subida: \(km) km al \(avg) % (+\(Int(c.ascentMeters)) m, \(c.category.label))")
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
