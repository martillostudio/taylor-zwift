import CicloBluetooth
import CicloKit
import Foundation
import Observation

/// Resumen al terminar un entrenamiento (o al pulsar «Terminar»).
struct RideSummary: Equatable {
    var title: String
    var best1Min: Double?
    var best5Min: Double?
    var best20Min: Double?
    var ftpTest: FTPTest?
    var suggestedFTP: Int?
    /// ml/kg/min, estimado con la mejor potencia de 5 minutos.
    var vo2max: Double?
}

/// El entrenamiento en marcha: junta la ruta, las marchas virtuales, el modo ERG,
/// los entrenamientos estructurados, los botones de los Click y lo que mandan el rodillo
/// y el pulsómetro.
///
/// Solo manda órdenes al rodillo mientras el entrenamiento está en marcha, para no
/// pisar lo que hagas a mano en la pestaña «Rodillo».
@MainActor
@Observable
final class RideController {
    enum Mode: String, CaseIterable, Identifiable {
        case route = "Ruta (SIM)"
        case erg = "ERG"
        case workout = "Entreno"
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

    // MARK: Entrenamientos

    /// Tu FTP en vatios (se guarda entre sesiones).
    var ftp: Int {
        didSet {
            UserDefaults.standard.set(ftp, forKey: Self.ftpKey)
            applyTarget(force: true)
        }
    }
    /// Tu peso en kg (para W/kg y el VO2max estimado).
    var weightKg: Double {
        didSet { UserDefaults.standard.set(weightKg, forKey: Self.weightKey) }
    }
    /// Tu frecuencia cardiaca máxima (para las zonas de pulso).
    var maxHeartRate: Int {
        didSet { UserDefaults.standard.set(maxHeartRate, forKey: Self.maxHRKey) }
    }
    /// Lunes en que empieza (o empezó) el plan.
    var planStart: Date {
        didSet { UserDefaults.standard.set(planStart.timeIntervalSince1970, forKey: Self.planStartKey) }
    }
    let plan = TrainingPlan.winter

    /// Semana del plan que toca hoy (`nil` si aún no ha empezado o ya terminó).
    var currentPlanWeek: PlanWeek? {
        plan.weekNumber(on: Date(), start: planStart).map { plan.weeks[$0 - 1] }
    }
    private(set) var workout: Workout?
    /// Segundos transcurridos del entrenamiento (avanzan mientras está en marcha).
    private(set) var workoutSeconds = 0.0
    /// Ajuste de intensidad sobre el entreno (1 = 100 %), con los botones de los Click.
    private(set) var intensity = 1.0
    private(set) var powerHistory = PowerHistory()
    private(set) var summary: RideSummary?
    private(set) var importedWorkouts: [Workout] = []

    static let ergStep = 10
    static let ergRange = 50...1000
    static let intensityStep = 0.02
    /// Cada cuánto se escribe en el log una línea con el estado del entrenamiento.
    static let statusLogSeconds = 5.0
    private static let ftpKey = "ftp"
    private static let weightKey = "pesoKg"
    private static let maxHRKey = "fcMax"
    private static let planStartKey = "inicioPlan"
    private static let importedKey = "entrenosImportados"

    @ObservationIgnored private var calibration = TrainerCalibration()
    @ObservationIgnored private var lastSentTime = 0.0
    @ObservationIgnored private var lastStatusLog = 0.0
    @ObservationIgnored private var lastTick: Double?
    @ObservationIgnored private var powerSampleDebt = 0.0
    @ObservationIgnored private var lastClimbAnnounced: Double?
    @ObservationIgnored private var lastSegmentID: Int?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(hub: BluetoothHub) {
        self.hub = hub
        let defaults = UserDefaults.standard
        let savedFTP = defaults.integer(forKey: Self.ftpKey)
        ftp = savedFTP > 0 ? savedFTP : 200
        let savedWeight = defaults.double(forKey: Self.weightKey)
        weightKg = savedWeight > 0 ? savedWeight : 72
        let savedHR = defaults.integer(forKey: Self.maxHRKey)
        maxHeartRate = savedHR > 0 ? savedHR : 185
        let savedStart = defaults.double(forKey: Self.planStartKey)
        planStart = savedStart > 0 ? Date(timeIntervalSince1970: savedStart) : TrainingPlan.monday(onOrAfter: Date())
        importedWorkouts = Self.loadImported()
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

    /// Dónde vas dentro del entrenamiento estructurado.
    var workoutProgress: WorkoutProgress? {
        guard mode == .workout else { return nil }
        return workout?.progress(at: workoutSeconds)
    }

    /// Vatios objetivo ahora mismo (ERG o tramo del entreno); `nil` si vas libre.
    var targetWatts: Int? {
        switch mode {
        case .route: nil
        case .erg: ergWatts
        case .workout: workoutProgress?.target.map { Int(($0 * intensity * Double(ftp)).rounded()) }
        }
    }

    /// En ruta y en los tramos libres de un entreno se va con marchas (SIM); si no, en ERG.
    var usesGears: Bool {
        switch mode {
        case .route: true
        case .erg: false
        case .workout: workoutProgress.map { $0.target == nil } ?? true
        }
    }

    // MARK: Acciones

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastTick = nil
        let what = switch mode {
        case .route: "\(route.name), marcha \(gearText)"
        case .erg: "ERG \(ergWatts) W"
        case .workout: "\(workout?.name ?? "sin entreno") con FTP \(ftp) W"
        }
        hub.appendLog("▶︎ En marcha: \(what)")
        applyTarget(force: true)
    }

    func pause() {
        guard isRunning else { return }
        isRunning = false
        session.pause()
        hub.appendLog("⏸ En pausa")
    }

    func reset() {
        session = RideSession()
        currentGrade = route.grade(atDistance: 0)
        lastClimbAnnounced = nil
        workoutSeconds = 0
        intensity = 1
        powerHistory = PowerHistory()
        summary = nil
        lastSegmentID = nil
        hub.appendLog("⟲ A cero (\(mode == .workout ? workout?.name ?? "entreno" : route.name))")
        applyTarget(force: true)
    }

    /// Prepara un entrenamiento estructurado (en pausa, desde el principio).
    func load(_ w: Workout) {
        pause()
        workout = w
        mode = .workout
        reset()
        let minutes = w.durationSeconds / 60
        hub.appendLog("🏋️ Entreno cargado: \(w.name) · \(minutes)' · TSS \(Int(w.tss.rounded())) · FTP \(ftp) W")
    }

    /// Termina el entreno (o el test) y calcula el resumen.
    func finish() {
        pause()
        let best5 = powerHistory.bestAverage(seconds: 300)
        let s = RideSummary(
            title: mode == .workout ? workout?.name ?? "Entreno" : "Salida",
            best1Min: powerHistory.bestAverage(seconds: 60),
            best5Min: best5,
            best20Min: powerHistory.bestAverage(seconds: 1_200),
            ftpTest: mode == .workout ? workout?.ftpTest : nil,
            suggestedFTP: mode == .workout ? workout?.ftpTest?.estimate(from: powerHistory) : nil,
            vo2max: best5.flatMap { Physiology.vo2maxEstimate(best5MinWatts: $0, weightKg: weightKg) }
        )
        summary = s
        func w(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) W" } ?? "—" }
        var line = "🏁 \(s.title): mejor 1' \(w(s.best1Min)) · 5' \(w(s.best5Min)) · 20' \(w(s.best20Min))"
        if let ftp = s.suggestedFTP { line += " · FTP estimado \(ftp) W" }
        if let v = s.vo2max { line += " · VO2max ≈ \(Int(v.rounded()))" }
        hub.appendLog(line)
    }

    func acceptSuggestedFTP() {
        guard let new = summary?.suggestedFTP else { return }
        hub.appendLog("💪 FTP actualizado: \(ftp) → \(new) W")
        ftp = new
    }

    /// Más duro: marcha más dura (SIM y tramos libres), +10 W en ERG, +2 % de intensidad en un entreno.
    func harder() {
        if usesGears {
            if gears.shiftUp() {
                hub.appendLog("⚙️ Marcha \(gearText)")
            } else {
                hub.appendLog("⚙️ Ya vas en la marcha más dura (\(gearText))")
            }
        } else if mode == .erg {
            ergWatts = min(ergWatts + Self.ergStep, Self.ergRange.upperBound)
            hub.appendLog("⚙️ ERG \(ergWatts) W")
        } else {
            intensity = min(intensity + Self.intensityStep, 1.5)
            hub.appendLog("⚙️ Intensidad \(Int((intensity * 100).rounded())) %")
        }
        applyTarget(force: true)
    }

    /// Más blando: lo contrario de `harder()`.
    func easier() {
        if usesGears {
            if gears.shiftDown() {
                hub.appendLog("⚙️ Marcha \(gearText)")
            } else {
                hub.appendLog("⚙️ Ya vas en la marcha más blanda (\(gearText))")
            }
        } else if mode == .erg {
            ergWatts = max(ergWatts - Self.ergStep, Self.ergRange.lowerBound)
            hub.appendLog("⚙️ ERG \(ergWatts) W")
        } else {
            intensity = max(intensity - Self.intensityStep, 0.5)
            hub.appendLog("⚙️ Intensidad \(Int((intensity * 100).rounded())) %")
        }
        applyTarget(force: true)
    }

    // MARK: Entrenos importados (.zwo)

    func importZwo(_ data: Data, fileName: String) throws -> Workout {
        let id = "importado-\(UUID().uuidString.prefix(8))"
        let name = (fileName as NSString).deletingPathExtension
        let w = try ZwoParser.parse(data, id: id, fallbackName: name)
        var stored = UserDefaults.standard.dictionary(forKey: Self.importedKey) as? [String: Data] ?? [:]
        stored[id] = data
        UserDefaults.standard.set(stored, forKey: Self.importedKey)
        importedWorkouts.append(w)
        hub.appendLog("📥 Entreno importado: \(w.name)")
        return w
    }

    func deleteImported(_ w: Workout) {
        var stored = UserDefaults.standard.dictionary(forKey: Self.importedKey) as? [String: Data] ?? [:]
        stored[w.id] = nil
        UserDefaults.standard.set(stored, forKey: Self.importedKey)
        importedWorkouts.removeAll { $0.id == w.id }
    }

    private static func loadImported() -> [Workout] {
        let stored = UserDefaults.standard.dictionary(forKey: importedKey) as? [String: Data] ?? [:]
        return stored.compactMap { id, data in try? ZwoParser.parse(data, id: id) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Interno

    /// Los mismos botones que en «Taylor Mandos»: + / Z suben, − / Y bajan.
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
        let dt = lastTick.map { min(now - $0, 2) } ?? 0
        lastTick = now
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
            speedKmh = usesGears ? gears.virtualSpeed(fromTrainerKmh: kmh) : kmh
        } else {
            speedKmh = nil
        }

        guard isRunning else { return }
        if trainerConnected {
            session.update(
                speedKmh: speedKmh ?? 0,
                powerWatts: data.powerWatts ?? 0,
                cadenceRpm: data.cadenceRpm ?? 0,
                heartRateBpm: hub.heartRateBpm,
                at: now
            )
            powerSampleDebt += dt
            while powerSampleDebt >= 1 {
                powerHistory.append(data.powerWatts ?? 0)
                powerSampleDebt -= 1
            }
        } else {
            session.pause() // sin datos: no integramos el hueco
        }

        switch mode {
        case .route:
            currentGrade = route.grade(atDistance: session.distanceMeters)
            announceClimb()
        case .erg:
            break
        case .workout:
            workoutSeconds += dt
            if let w = workout, workoutSeconds >= Double(w.durationSeconds) {
                hub.appendLog("✅ Entreno completado")
                finish()
                return
            }
            if let p = workoutProgress, p.segment.id != lastSegmentID {
                lastSegmentID = p.segment.id
                hub.appendLog("⏱ Tramo \(p.segment.id + 1)/\(workout?.segments.count ?? 0): \(p.segment.summary)")
                applyTarget(force: true, now: now)
            }
        }

        if now - lastStatusLog >= Self.statusLogSeconds {
            lastStatusLog = now
            logStatus()
        }
        applyTarget(force: false, now: now)
    }

    private func logStatus() {
        let km = (session.distanceMeters / 1000).formatted(.number.precision(.fractionLength(2)))
        let speed = speedKmh.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
        let heart = hub.heartRateBpm.map { " · ❤️ \($0)" } ?? ""
        let power = hub.bikeData.powerWatts.map { "\($0) W" } ?? "—"
        switch mode {
        case .route:
            let grade = currentGrade.formatted(.number.precision(.fractionLength(1)))
            let k = gears.k.formatted(.number.precision(.fractionLength(2)))
            hub.appendLog("🛣 km \(km) · pendiente \(grade) % · marcha \(gearText) ×\(k) · \(speed) km/h\(heart)")
        case .erg:
            hub.appendLog("🛣 km \(km) · ERG \(ergWatts) W · \(power) · \(speed) km/h\(heart)")
        case .workout:
            let t = Duration.seconds(workoutSeconds).formatted(.time(pattern: .minuteSecond))
            let target = targetWatts.map { "objetivo \($0) W" } ?? "libre (marcha \(gearText))"
            hub.appendLog("🏋️ \(t) · \(target) · \(power) · intensidad \(Int((intensity * 100).rounded())) %\(heart)")
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
        case .route:
            .simulation(gears.simulation(gradePercent: currentGrade))
        case .erg:
            .targetPower(watts: ergWatts)
        case .workout:
            if let watts = targetWatts {
                .targetPower(watts: watts)
            } else {
                .simulation(gears.simulation(gradePercent: 0)) // tramo libre: llano con marchas
            }
        }
    }

    /// Manda el objetivo al rodillo si ha cambiado. Los cambios de la ruta se mandan como
    /// mucho una vez por segundo; los de botones, modo y tramo (`force`), al momento.
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
