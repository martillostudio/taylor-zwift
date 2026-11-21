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
    let store: ActivityStore
    let strava: StravaService
    let intervals: IntervalsService

    /// Entreno que se está grabando (se guarda al terminar).
    private(set) var recording: Activity?
    /// Último entreno guardado (para el resumen y la subida a Strava).
    private(set) var lastSaved: Activity?
    @ObservationIgnored private var virtualElevation = 0.0
    @ObservationIgnored private var lastDistance = 0.0
    /// Menos de esto no se guarda (pruebas, arranques en falso).
    static let minimumSecondsToSave = 60

    var mode: Mode = .route {
        didSet { if mode != oldValue { applyTarget(force: true) } }
    }
    /// Ruta elegida. Solo hay rutas tuyas (GPX); `.flat` es lo que queda si no tienes ninguna.
    var route: Route = .flat {
        didSet {
            guard route != oldValue else { return }
            reset()
            if route.id.hasPrefix("gpx-") { UserDefaults.standard.set(route.id, forKey: "rutaElegida") }
        }
    }
    private(set) var gears: VirtualGears
    /// Pendiente que eliges en los tramos libres de un entreno (−10 % a 20 %).
    private(set) var freeGrade = 0.0
    /// Pestaña visible (para saltar de «Entrenar» a «Rodar»).
    /// Pestaña al abrir (para desarrollar: `open TaylorZwift.app --args -pestanaInicial entrenar`).
    var selectedTab = UserDefaults.standard.string(forKey: "pestanaInicial") ?? "rodar"
    static let freeGradeStep = 0.5
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
            scheduleFTPSync()
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
        didSet {
            // Siempre en lunes: si eliges otro día, el lunes de esa semana.
            let monday = TrainingPlan.monday(onOrBefore: planStart)
            if monday != planStart { planStart = monday; return }
            UserDefaults.standard.set(planStart.timeIntervalSince1970, forKey: Self.planStartKey)
        }
    }
    let plan = TrainingPlan.winter

    /// Semana del plan que toca hoy (`nil` si aún no ha empezado o ya terminó).
    var currentPlanWeek: PlanWeek? {
        plan.weekNumber(on: Date(), start: planStart).map { plan.weeks[$0 - 1] }
    }

    /// Sesiones marcadas a mano como hechas (salidas en exterior, o entrenos hechos en otra app).
    private(set) var manualPlanMarks: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "sesionesHechas") ?? [])

    /// Estado de cada sesión de la semana, cruzando el plan con el historial.
    func planStatus(_ week: PlanWeek) -> [String: PlanSessionStatus] {
        plan.status(of: week, start: planStart,
                    completed: store.activities.map(\.asCompletedWorkout)
                        + intervals.outdoorRides.map(\.asCompletedWorkout),
                    manuallyDone: manualPlanMarks)
    }

    /// Trae de intervals.icu las salidas desde que empezó el plan (como mucho 16 semanas atrás)
    /// y al menos las de las últimas 6 semanas (para su FTP estimado).
    func syncIntervals(force: Bool = false) async {
        guard intervals.isConnected else { return }
        let now = Date()
        let from = min(max(planStart, now.addingTimeInterval(-112 * 86_400)), now.addingTimeInterval(-42 * 86_400))
        let planEnd = plan.startOfWeek(plan.weeks.count + 1, start: planStart)
        await intervals.sync(since: from, fitnessUntil: planEnd, force: force)
    }

    /// Cuando cambias el FTP (a mano o tras un test), se copia a intervals.icu a los 3 s
    /// (así el «Stepper» no manda una petición por cada clic).
    @ObservationIgnored private var ftpSyncTask: Task<Void, Never>?
    private func scheduleFTPSync() {
        guard intervals.isConnected else { return }
        ftpSyncTask?.cancel()
        ftpSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            await intervals.pushFTP(ftp)
        }
    }

    /// Manda las 16 semanas del plan al calendario de intervals.icu.
    func pushPlanToIntervals() async {
        do {
            let n = try await intervals.pushPlan(plan.calendarEvents(start: planStart), planID: plan.id)
            hub.appendLog("🔵 Plan en intervals.icu: \(n) sesiones")
            UserDefaults.standard.set(planStart.timeIntervalSince1970, forKey: "planEnIntervals")
            planPushedStart = planStart
            await syncIntervals(force: true) // la proyección de la forma cambia con el plan
        } catch {
            hub.appendLog("⚠️ intervals.icu (plan): \(error.localizedDescription)")
        }
    }

    /// Fecha de inicio con la que se mandó el plan a intervals.icu por última vez.
    private(set) var planPushedStart: Date? = {
        let t = UserDefaults.standard.double(forKey: "planEnIntervals")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()

    func toggleManualMark(_ session: PlanSession, week: PlanWeek) {
        let key = session.key(week: week.number)
        if manualPlanMarks.contains(key) { manualPlanMarks.remove(key) } else { manualPlanMarks.insert(key) }
        UserDefaults.standard.set(Array(manualPlanMarks), forKey: "sesionesHechas")
    }

    /// Fecha de una sesión del plan.
    func date(of session: PlanSession, in week: PlanWeek) -> Date {
        Calendar.current.date(byAdding: .day, value: session.weekdayOffset,
                              to: plan.startOfWeek(week.number, start: planStart)) ?? planStart
    }

    // MARK: Botones A / B del mando derecho

    /// Mensaje corto que se enseña unos segundos encima de todo (p. ej. «Pulsa B otra vez…»).
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var finishArmedUntil: Double = 0
    static let finishConfirmSeconds = 3.0

    func show(_ text: String, seconds: Double = 2.5) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// A: empezar o pausar (lo que haría el botón grande).
    func togglePlayPause() {
        if isRunning {
            pause()
            show("⏸ En pausa · A para seguir")
        } else if hub.trainerConnection != .connected {
            show("Conecta el rodillo para empezar")
        } else if summary != nil {
            show("Entreno terminado · pulsa «A cero» para otro")
        } else if mode == .workout && workout == nil {
            show("Elige un entreno en «Entrenar»")
        } else {
            start()
            show("▶︎ En marcha")
        }
    }

    /// B: terminar, pero pidiendo una segunda pulsación para no acabar sin querer.
    func requestFinish() {
        let now = ProcessInfo.processInfo.systemUptime
        let hasSomething = session.movingSeconds > 0 || workoutSeconds > 0
        guard hasSomething, summary == nil else {
            show("No hay nada que terminar")
            return
        }
        if now < finishArmedUntil {
            finishArmedUntil = 0
            finish()
            show("🏁 Terminado y guardado", seconds: 3)
        } else {
            finishArmedUntil = now + Self.finishConfirmSeconds
            show("Pulsa B otra vez para terminar", seconds: Self.finishConfirmSeconds)
            hub.appendLog("🏁 B: pulsa otra vez en \(Int(Self.finishConfirmSeconds)) s para terminar")
        }
    }
    private(set) var workout: Workout?
    /// Segundos transcurridos del entrenamiento (avanzan mientras está en marcha).
    private(set) var workoutSeconds = 0.0
    /// Ajuste de intensidad sobre el entreno (1 = 100 %), con los botones de los Click.
    private(set) var intensity = 1.0
    private(set) var powerHistory = PowerHistory()
    private(set) var summary: RideSummary?
    private(set) var importedWorkouts: [Workout] = []

    /// Un punto por segundo del entreno, para pintar lo que llevas sobre el perfil.
    struct TracePoint: Identifiable, Equatable {
        var id: Int { Int(t) }
        let t: Double
        let power: Int
        let heartRate: Int?
    }
    private(set) var trace: [TracePoint] = []
    /// Desnivel positivo virtual (ruta, libre o pendiente equivalente en ERG).
    private(set) var elevationGain = 0.0
    /// Segundos en cada zona de pulso.
    private(set) var heartRateZoneSeconds: [HeartRateZone: Double] = [:]
    @ObservationIgnored private var cadenceSum = 0.0
    @ObservationIgnored private var cadenceCount = 0
    private(set) var averageCadence: Int?

    static let ergStep = 10
    static let ergRange = 50...1000
    static let intensityStep = 0.02
    /// Cada cuánto se escribe en el log una línea con el estado del entrenamiento.
    static let statusLogSeconds = 5.0
    private static let ftpKey = "ftp"
    private static let weightKey = "pesoKg"
    private static let maxHRKey = "fcMax"
    private static let planStartKey = "inicioPlan"
    private static let drivetrainKey = "desarrollo"
    private static let importedKey = "entrenosImportados"

    @ObservationIgnored private var calibration = TrainerCalibration()
    @ObservationIgnored private var lastSentTime = 0.0
    @ObservationIgnored private var lastStatusLog = 0.0
    @ObservationIgnored private var lastTick: Double?
    @ObservationIgnored private var powerSampleDebt = 0.0
    @ObservationIgnored private var lastClimbAnnounced: Double?
    @ObservationIgnored private var lastSegmentID: Int?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(hub: BluetoothHub, store: ActivityStore, strava: StravaService, intervals: IntervalsService) {
        self.hub = hub
        self.store = store
        self.strava = strava
        self.intervals = intervals
        let defaults = UserDefaults.standard
        let savedFTP = defaults.integer(forKey: Self.ftpKey)
        ftp = savedFTP > 0 ? savedFTP : 200
        let savedWeight = defaults.double(forKey: Self.weightKey)
        weightKg = savedWeight > 0 ? savedWeight : 72
        let savedHR = defaults.integer(forKey: Self.maxHRKey)
        maxHeartRate = savedHR > 0 ? savedHR : 185
        // Por defecto, el monoplato 1×12 de tu Grizl (se puede cambiar en «Rodar»).
        let savedDrivetrain = defaults.string(forKey: Self.drivetrainKey)
        gears = VirtualGears(drivetrain: Drivetrain.all.first { $0.id == savedDrivetrain } ?? .grx1x12)
        let savedStart = defaults.double(forKey: Self.planStartKey)
        planStart = savedStart > 0 ? TrainingPlan.monday(onOrBefore: Date(timeIntervalSince1970: savedStart))
            : TrainingPlan.monday(onOrAfter: Date())
        importedWorkouts = Self.loadImported()
        // Las rutas GPX se leen en segundo plano: con muchas, tardaría en abrir la ventana.
        Task { [weak self] in
            let routes = await Task.detached(priority: .userInitiated) { Self.loadRoutes() }.value
            guard let self else { return }
            importedRoutes = importedRoutes.filter { r in !routes.contains { $0.id == r.id } } + routes
            importedRoutes.sort { $0.name < $1.name }
            // La última que elegiste (o la primera), si no estás rodando ya otra.
            if !isRunning, !route.id.hasPrefix("gpx-") {
                let saved = UserDefaults.standard.string(forKey: "rutaElegida")
                if let r = importedRoutes.first(where: { $0.id == saved }) ?? importedRoutes.first { route = r }
            }
        }
        hub.onButtonPress = { [weak self] pressed in self?.handleButtons(pressed) }
        // Al despertar un mando dormido, la pulsación que lo despertó se pierde: avisamos de que ya vale.
        hub.onClickAwake = { [weak self] _, awake in
            if awake { self?.show("🎮 Mando listo: ya puedes usar los botones") }
        }
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
            UserDefaults.standard.set(newValue.id, forKey: Self.drivetrainKey)
            hub.appendLog("⚙️ Desarrollo: \(newValue.name) · marcha \(gearText)")
            applyTarget(force: true)
        }
    }

    /// La subida en la que estás o la que viene (en los próximos 2 km).
    var climbStatus: ClimbStatus? {
        mode == .route ? route.climbStatus(atDistance: session.distanceMeters) : nil
    }

    var gearText: String { "\(gears.number)/\(gears.count) (\(gears.gear.label))" }

    /// Tú (con tu peso) más la bici.
    var physics: RiderPhysics { RiderPhysics(riderKg: weightKg) }

    /// Potencia media de los últimos 3 s (lo que se suele mirar: el dato instantáneo baila).
    var power3s: Int? {
        guard isRunning, powerHistory.samples.count >= 3 else { return hub.bikeData.powerWatts }
        return Int((Double(powerHistory.samples.suffix(3).reduce(0, +)) / 3).rounded())
    }

    /// Potencia normalizada de lo que llevas (desde 30 s).
    var normalizedPower: Int? {
        let s = powerHistory.samples
        guard s.count >= 30 else { return nil }
        return Int(Workout.normalized(s.map(Double.init)).rounded())
    }

    var liveIntensityFactor: Double? {
        normalizedPower.map { Double($0) / Double(max(ftp, 1)) }
    }

    /// TSS acumulado: horas × IF² × 100.
    var liveTSS: Int? {
        guard let f = liveIntensityFactor else { return nil }
        return Int((Double(powerHistory.samples.count) / 3600 * f * f * 100).rounded())
    }

    /// Pulso máximo recomendado en los entrenos de base (Z1–Z2): el 70 % de tu FC máxima.
    /// Si lo pasas, estás en la «zona gris» y conviene bajar la intensidad.
    var heartRateCap: Int? {
        guard mode == .workout, let w = workout, w.ftpTest == nil, w.mainZone <= .z2 else { return nil }
        return Int((Double(maxHeartRate) * HeartRateZone.z2.highFraction).rounded())
    }

    var heartRateAboveCap: Bool {
        guard let cap = heartRateCap, let bpm = hub.heartRateBpm, isRunning else { return false }
        return bpm > cap
    }

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
        if recording == nil {
            recording = Activity(start: Date(), name: activityName, kind: mode.rawValue,
                                 workoutID: mode == .workout ? workout?.id : nil, ftp: ftp)
            lastDistance = session.distanceMeters
            virtualElevation = mode == .route ? route.elevation(atDistance: session.distanceMeters) : 0
        }
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

    /// Nombre con el que se guarda (y se sube a Strava).
    var activityName: String {
        switch mode {
        case .route: "\(route.name.components(separatedBy: " (").first ?? route.name) (rodillo)"
        case .erg: "ERG \(ergWatts) W (rodillo)"
        case .workout: workout?.name ?? "Entreno en rodillo"
        }
    }

    func reset() {
        saveRecording()
        session = RideSession()
        currentGrade = route.grade(atDistance: 0)
        lastClimbAnnounced = nil
        workoutSeconds = 0
        intensity = 1
        powerHistory = PowerHistory()
        summary = nil
        lastSegmentID = nil
        trace = []
        elevationGain = 0
        heartRateZoneSeconds = [:]
        cadenceSum = 0
        cadenceCount = 0
        averageCadence = nil
        let what = switch mode {
        case .route: route.name
        case .erg: "ERG"
        case .workout: workout?.name ?? "entreno"
        }
        hub.appendLog("⟲ A cero (\(what))")
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
        saveRecording()
        func w(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) W" } ?? "—" }
        var line = "🏁 \(s.title): mejor 1' \(w(s.best1Min)) · 5' \(w(s.best5Min)) · 20' \(w(s.best20Min))"
        if let ftp = s.suggestedFTP { line += " · FTP estimado \(ftp) W" }
        if let v = s.vo2max { line += " · VO2max ≈ \(Int(v.rounded()))" }
        hub.appendLog(line)
    }

    var freeGradeText: String {
        "\(freeGrade.formatted(.number.precision(.fractionLength(1)))) %"
    }

    /// Tramos libres de un entreno: cambia la pendiente (también con la cruceta ↑/↓ del mando izquierdo).
    func setFreeGrade(_ grade: Double) {
        let g = min(max((grade / Self.freeGradeStep).rounded() * Self.freeGradeStep, -10), 20)
        guard g != freeGrade else { return }
        freeGrade = g
        if mode == .workout && usesGears { currentGrade = g }
        hub.appendLog("⛰ Pendiente libre: \(freeGradeText)")
        applyTarget(force: true)
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
        } else if intensityLocked {
            hub.appendLog("🔒 En los test la intensidad va fija al 100 % (si no, el FTP sale mal)")
        } else {
            intensity = min(intensity + Self.intensityStep, 1.5)
            hub.appendLog("⚙️ Intensidad \(Int((intensity * 100).rounded())) %")
        }
        applyTarget(force: true)
    }

    /// En los test de FTP no se toca la intensidad: los vatios tienen que ser los del protocolo.
    var intensityLocked: Bool { mode == .workout && workout?.ftpTest != nil }

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
        } else if intensityLocked {
            hub.appendLog("🔒 En los test la intensidad va fija al 100 % (si no, el FTP sale mal)")
        } else {
            intensity = max(intensity - Self.intensityStep, 0.5)
            hub.appendLog("⚙️ Intensidad \(Int((intensity * 100).rounded())) %")
        }
        applyTarget(force: true)
    }

    // MARK: Grabación e historial

    private func recordSample(_ data: IndoorBikeData) {
        guard let start = recording?.start else { return }
        let distance = session.distanceMeters
        let before = virtualElevation
        switch mode {
        case .route: virtualElevation = route.elevation(atDistance: distance)
        case .erg, .workout: virtualElevation += currentGrade / 100 * (distance - lastDistance)
        }
        elevationGain += max(virtualElevation - before, 0)
        lastDistance = distance
        recording?.samples.append(ActivitySample(
            t: Date().timeIntervalSince(start),
            power: data.powerWatts,
            cadence: data.cadenceRpm.map { Int($0.rounded()) },
            speedKmh: speedKmh,
            distance: distance,
            heartRate: hub.heartRateBpm,
            elevation: virtualElevation
        ))
    }

    /// Guarda lo grabado (si pasa del minuto) y, si está activado, lo sube a Strava.
    private func saveRecording() {
        guard let rec = recording else { return }
        recording = nil
        guard rec.samples.count >= Self.minimumSecondsToSave else {
            if !rec.samples.isEmpty { hub.appendLog("🗑 No se guarda: menos de 1 minuto grabado") }
            return
        }
        do {
            try store.save(rec)
            lastSaved = rec
            hub.appendLog("💾 Guardado: \(rec.name) · \(Int(rec.timerSeconds / 60))' · \(rec.tss.map { "TSS \($0)" } ?? "")")
            if intervals.autoUpload, intervals.isConnected { uploadToIntervals(rec) }
            if strava.autoUpload, strava.isConnected { uploadToStrava(rec) }
        } catch {
            hub.appendLog("⚠️ No se pudo guardar el entreno: \(error.localizedDescription)")
        }
    }

    /// Sube un entreno guardado a intervals.icu y apunta el id de la actividad.
    func uploadToIntervals(_ a: Activity) {
        Task {
            do {
                let id = try await intervals.upload(a, fit: store.fitData(a))
                // Releemos del historial por si Strava lo ha actualizado mientras tanto.
                var updated = store.activities.first { $0.id == a.id } ?? a
                updated.intervalsActivityID = id
                try? store.save(updated)
                if lastSaved?.id == a.id { lastSaved = updated }
                hub.appendLog("🔵 Subido a intervals.icu: \(a.name) (\(id))")
            } catch {
                hub.appendLog("⚠️ intervals.icu: \(error.localizedDescription)")
            }
        }
    }

    /// Sube un entreno guardado a Strava y apunta el id de la actividad.
    func uploadToStrava(_ a: Activity) {
        Task {
            do {
                let id = try await strava.upload(a, fit: store.fitData(a))
                var updated = store.activities.first { $0.id == a.id } ?? a
                updated.stravaActivityID = id
                try? store.save(updated)
                if lastSaved?.id == a.id { lastSaved = updated }
                hub.appendLog("🟧 Subido a Strava: \(a.name) (actividad \(id))")
            } catch {
                hub.appendLog("⚠️ Strava: \(error.localizedDescription)")
            }
        }
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

    // MARK: Rutas GPX

    /// Rutas importadas de ficheros GPX (se guardan en Application Support/Rutas).
    private(set) var importedRoutes: [Route] = []

    var allRoutes: [Route] { importedRoutes }

    nonisolated private static var routesFolder: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Rutas", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    func importGPX(_ data: Data, fileName: String) throws -> Route {
        let id = "gpx-\(UUID().uuidString.prefix(8))"
        let name = (fileName as NSString).deletingPathExtension
        let r = try GPXParser.parse(data, id: id, fallbackName: name)
        try data.write(to: Self.routesFolder.appendingPathComponent("\(id).gpx"), options: .atomic)
        importedRoutes.append(r)
        importedRoutes.sort { $0.name < $1.name }
        let km = (r.lengthMeters / 1000).formatted(.number.precision(.fractionLength(1)))
        hub.appendLog("📥 Ruta importada: \(r.name) · \(km) km · +\(Int(r.climbMeters)) m")
        return r
    }

    func deleteRoute(_ r: Route) {
        guard r.id.hasPrefix("gpx-") else { return }
        try? FileManager.default.removeItem(at: Self.routesFolder.appendingPathComponent("\(r.id).gpx"))
        importedRoutes.removeAll { $0.id == r.id }
        if route.id == r.id { route = importedRoutes.first ?? .flat }
    }

    nonisolated private static func loadRoutes() -> [Route] {
        let files = (try? FileManager.default.contentsOfDirectory(at: routesFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "gpx" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { data in
                    try? GPXParser.parse(data, id: url.deletingPathExtension().lastPathComponent)
                }
            }
            .sorted { $0.name < $1.name }
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
            case .up where mode == .workout && usesGears: setFreeGrade(freeGrade + Self.freeGradeStep)
            case .down where mode == .workout && usesGears: setFreeGrade(freeGrade - Self.freeGradeStep)
            case .select: togglePlayPause()
            case .back: requestFinish()
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
            if usesGears {
                speedKmh = gears.virtualSpeed(fromTrainerKmh: kmh)
            } else {
                // En ERG el rodillo manda los vatios: la velocidad es la que llevarías en llano
                // con esa potencia (como Zwift o TrainerRoad). Sin pedalear, parado.
                let watts = Double(data.powerWatts ?? 0)
                speedKmh = (data.cadenceRpm ?? 0) > 0 && watts > 0 ? physics.speed(powerWatts: watts, gradePercent: 0) : 0
            }
        } else {
            speedKmh = nil
        }
        updateGrade()

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
                recordSample(data)
                accumulateStats(data)
                powerSampleDebt -= 1
            }
        } else {
            session.pause() // sin datos: no integramos el hueco
        }

        switch mode {
        case .erg:
            break
        case .route:
            announceClimb()
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

    /// Pendiente que se enseña: la de la ruta, la libre, o la equivalente en ERG.
    private func updateGrade() {
        switch mode {
        case .route:
            currentGrade = route.grade(atDistance: session.distanceMeters)
        case .erg, .workout:
            // Tramo libre: la pendiente de la cruceta. ERG: llano.
            currentGrade = usesGears ? freeGrade : 0
        }
    }

    /// Lo que se acumula una vez por segundo: traza del perfil, zonas de pulso, cadencia media.
    private func accumulateStats(_ data: IndoorBikeData) {
        if mode == .workout {
            trace.append(TracePoint(t: workoutSeconds, power: data.powerWatts ?? 0, heartRate: hub.heartRateBpm))
        }
        if let bpm = hub.heartRateBpm, bpm > 0 {
            heartRateZoneSeconds[HeartRateZone(bpm: bpm, max: maxHeartRate), default: 0] += 1
        }
        if let rpm = data.cadenceRpm, rpm > 0 {
            cadenceSum += rpm
            cadenceCount += 1
            averageCadence = Int((cadenceSum / Double(cadenceCount)).rounded())
        }
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
                .simulation(gears.simulation(gradePercent: freeGrade)) // tramo libre: marchas y la pendiente de la cruceta
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
