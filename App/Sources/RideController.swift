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
    /// FTP que tenías antes, si el test lo cambió solo.
    var previousFTP: Int?
    /// ml/kg/min, estimado con la mejor potencia de 5 minutos.
    var vo2max: Double?
    /// Análisis del entreno estructurado (intervalos, desacople, tope de pulso, próxima vez).
    var review: WorkoutReview?
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
            hub.setDemoFTP(ftp)
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
    /// El plan, con las sesiones que hayas cambiado de día.
    var plan: TrainingPlan { TrainingPlan.winter.replacing(planSwaps).moving(planMoves) }

    /// Sesiones cambiadas por otro entreno (propuestas aceptadas): clave original → id del entreno.
    private(set) var planSwaps: [String: String] =
        UserDefaults.standard.dictionary(forKey: "sesionesCambiadas") as? [String: String] ?? [:]

    /// Intensidad con la que empieza cada tipo de entreno (propuestas aceptadas). 1 = 100 %.
    private(set) var categoryIntensity: [WorkoutCategory: Double] = {
        let raw = UserDefaults.standard.dictionary(forKey: "intensidadPorTipo") as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in WorkoutCategory(rawValue: k).map { ($0, v) } })
    }()

    /// Propuestas que has descartado («Ahora no»): no vuelven a salir.
    private(set) var dismissedProposals: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "propuestasDescartadas") ?? [])

    /// Con qué intensidad empieza un entreno: la de su tipo (los tests, siempre al 100 %).
    func startIntensity(for w: Workout) -> Double {
        w.ftpTest == nil ? categoryIntensity[w.category] ?? 1 : 1
    }

    /// Lo que el «entrenador» propone cambiar del plan esta semana (ver `PlanAdvisor`).
    var planProposals: [PlanProposal] {
        guard let week = currentPlanWeek else { return [] }
        let cal = Calendar.current
        let todayOffset = cal.dateComponents([.day], from: plan.startOfWeek(week.number, start: planStart),
                                             to: cal.startOfDay(for: Date())).day ?? 0
        let monthAgo = Date().addingTimeInterval(-30 * 86_400)
        let all = Workout.library + importedWorkouts
        let outcomes = store.activities.filter { $0.start > monthAgo }.compactMap { a -> WorkoutOutcome? in
            guard let id = a.workoutID, let w = all.first(where: { $0.id == id }) else { return nil }
            let base = a.baseIntensity ?? 1
            return WorkoutOutcome(date: a.start, category: w.category, compliance: review(of: a)?.compliance,
                                  baseIntensity: base, finalIntensity: a.intensity ?? base)
        }
        return PlanAdvisor.proposals(week: week, statuses: planStatus(week), todayOffset: todayOffset,
                                     freshness: intervals.fitness.day(on: Date())?.freshness,
                                     outcomes: outcomes, categoryIntensity: categoryIntensity)
            .filter { !dismissedProposals.contains($0.id) }
    }

    func accept(_ p: PlanProposal) {
        switch p.change {
        case .move(let key, let day):
            let originalDay = TrainingPlan.winter.weeks.flatMap { w in w.sessions.map { (w.number, $0) } }
                .first { $0.1.key(week: $0.0) == key }?.1.day
            planMoves[key] = day == originalDay ? nil : day
            UserDefaults.standard.set(planMoves, forKey: "sesionesMovidas")
        case .swap(let key, let id):
            planSwaps[key] = id
            UserDefaults.standard.set(planSwaps, forKey: "sesionesCambiadas")
        case .intensity(let category, let to):
            categoryIntensity[category] = to
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: categoryIntensity.map { ($0.key.rawValue, $0.value) }),
                                      forKey: "intensidadPorTipo")
        }
        hub.appendLog("🧭 Propuesta aceptada: \(p.title)")
        show("✅ \(p.title)", seconds: 3)
        // Los cambios de día o de entreno van también al calendario de intervals.icu (y a Garmin).
        if case .intensity = p.change { return }
        if planPushedStart != nil { Task { await pushPlanToIntervals() } }
    }

    func dismiss(_ p: PlanProposal) {
        dismissedProposals.insert(p.id)
        UserDefaults.standard.set(Array(dismissedProposals), forKey: "propuestasDescartadas")
        hub.appendLog("🧭 Propuesta descartada: \(p.title)")
    }

    /// Sesiones cambiadas de día: clave original («s1-Sáb-z2-90») → día nuevo («Dom»).
    private(set) var planMoves: [String: String] =
        UserDefaults.standard.dictionary(forKey: "sesionesMovidas") as? [String: String] ?? [:]

    /// Cambia una sesión de día (dentro de su semana) y, si el plan ya está en intervals.icu,
    /// lo actualiza allí.
    func moveSession(_ session: PlanSession, week: PlanWeek, to day: String) {
        let key = session.originalKey ?? session.key(week: week.number)
        guard let original = TrainingPlan.winter.weeks.first(where: { $0.number == week.number })?.sessions
            .first(where: { $0.key(week: week.number) == key }) else { return }
        if day == original.day { planMoves[key] = nil } else { planMoves[key] = day }
        UserDefaults.standard.set(planMoves, forKey: "sesionesMovidas")
        hub.appendLog("📅 \(session.workout?.name ?? "Salida") de la semana \(week.number) pasa al \(day)")
        if planPushedStart != nil { Task { await pushPlanToIntervals() } }
    }

    /// Lo que se mandó a intervals.icu la última vez (sesiones y fechas), para saber si hay que
    /// volver a mandarlo.
    private var planSignature: String {
        plan.calendarEvents(start: planStart)
            .map { "\($0.externalID)@\(Int($0.date.timeIntervalSince1970))" }
            .joined(separator: ",")
    }

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
        // Si el plan cambió desde que se mandó (sesiones movidas, otra fecha), se actualiza solo.
        if planPushedStart != nil, UserDefaults.standard.string(forKey: "planEnIntervalsFirma") != planSignature {
            await pushPlanToIntervals()
            return
        }
        await intervals.sync(since: from, fitnessUntil: planEnd, force: force)
        // El eFTP de intervals.icu solo sube el FTP (bajarlo, con un test a tope).
        if let new = FTPUpdate.raise(current: ftp, estimated: intervals.estimatedFTP) {
            hub.appendLog("💪 FTP actualizado con el eFTP de intervals.icu: \(ftp) → \(new) W")
            show("💪 FTP actualizado a \(new) W (has mejorado)", seconds: 5)
            ftp = new
        }
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
            UserDefaults.standard.set(planSignature, forKey: "planEnIntervalsFirma")
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
            show(hub.isDemo ? "🏁 Terminado (modo prueba: no se guarda)" : "🏁 Terminado y guardado", seconds: 3)
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
    /// Intensidad con la que empezó el entreno (la de su tipo).
    private(set) var baseIntensity = 1.0
    private(set) var powerHistory = PowerHistory()
    private(set) var summary: RideSummary?
    private(set) var importedWorkouts: [Workout] = []

    /// Un punto por segundo del entreno, para pintar lo que llevas sobre el perfil.
    struct TracePoint: Identifiable, Equatable {
        var id: Int { Int(t) }
        let t: Double
        let power: Int
        let heartRate: Int?
        var cadence: Int? = nil
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
    /// Desde cuándo (reloj de la sesión) llevas parado en un test de rampa.
    @ObservationIgnored private var rampStoppedSince: Double?
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
        // Para desarrollar: `open TaylorZwift.app --args -modoPrueba 30 -entreno test-rampa` arranca
        // el modo prueba con el tiempo ×30 y, si se indica, empieza ese entreno solo.
        let demoScale = UserDefaults.standard.double(forKey: "modoPrueba")
        if demoScale > 0 {
            startDemo()
            hub.timeScale = demoScale
            if let id = UserDefaults.standard.string(forKey: "entreno"),
               let w = (Workout.library + importedWorkouts).first(where: { $0.id == id }) {
                load(w)
                start()
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                // Cada tick son ~0,5 s del reloj de la sesión, también con el tiempo acelerado.
                let scale = self?.hub.timeScale ?? 1
                try? await Task.sleep(for: .milliseconds(Int(500 / max(scale, 1))))
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
        guard mode == .workout, let w = workout else { return nil }
        return heartRateCap(for: w)
    }

    func heartRateCap(for w: Workout) -> Int? {
        guard w.ftpTest == nil, w.mainZone <= .z2 else { return nil }
        return Int((Double(maxHeartRate) * HeartRateZone.z2.highFraction).rounded())
    }

    /// Análisis de un entreno guardado (si fue un entreno de la biblioteca o importado).
    /// Hay una muestra por segundo pedaleado, así que su posición es el segundo del entreno.
    func review(of a: Activity) -> WorkoutReview? {
        guard let id = a.workoutID,
              let w = (Workout.library + importedWorkouts).first(where: { $0.id == id }) else { return nil }
        let samples = a.samples.enumerated().map { i, s in
            ReviewSample(t: Double(i), power: s.power ?? 0, heartRate: s.heartRate, cadence: s.cadence)
        }
        return WorkoutReview(workout: w, ftp: a.ftp, samples: samples, heartRateCap: heartRateCap(for: w),
                             baseIntensity: a.baseIntensity ?? 1)
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

    /// Rodillo, pulsómetro y mandos de mentira para probar sin el Kickr (ver `DemoRider`).
    func startDemo() {
        hub.startDemo(ftp: ftp, maxHeartRate: maxHeartRate)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastTick = nil
        rampStoppedSince = nil
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
        intensity = mode == .workout ? workout.map(startIntensity) ?? 1 : 1
        baseIntensity = intensity
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
        let start = intensity == 1 ? "" : " · empieza al \(Int((intensity * 100).rounded())) % (\(w.category.rawValue))"
        hub.appendLog("🏋️ Entreno cargado: \(w.name) · \(minutes)' · TSS \(Int(w.tss.rounded())) · FTP \(ftp) W\(start)")
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
            vo2max: best5.flatMap { Physiology.vo2maxEstimate(best5MinWatts: $0, weightKg: weightKg) },
            review: mode == .workout ? workout.map { w in
                WorkoutReview(workout: w, ftp: ftp,
                              samples: trace.map { ReviewSample(t: $0.t, power: $0.power, heartRate: $0.heartRate, cadence: $0.cadence) },
                              heartRateCap: heartRateCap, baseIntensity: baseIntensity)
            } : nil
        )
        summary = s
        // El test a tope (pulso ≥ 92 % de tu FC máx.) cambia el FTP solo; si no, se pregunta.
        if let new = s.suggestedFTP, new != ftp, !hub.isDemo,
           FTPUpdate.testIsMaximal(maxHeartRate: session.maxHeartRateBpm, athleteMaxHeartRate: maxHeartRate) {
            hub.appendLog("💪 FTP actualizado con el test: \(ftp) → \(new) W")
            show("💪 FTP actualizado a \(new) W", seconds: 5)
            summary?.previousFTP = ftp
            ftp = new
        }
        saveRecording()
        func w(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) W" } ?? "—" }
        var line = "🏁 \(s.title): mejor 1' \(w(s.best1Min)) · 5' \(w(s.best5Min)) · 20' \(w(s.best20Min))"
        if let ftp = s.suggestedFTP { line += " · FTP estimado \(ftp) W" }
        if let v = s.vo2max { line += " · VO2max ≈ \(Int(v.rounded()))" }
        hub.appendLog(line)
        if let r = s.review {
            for i in r.intervals {
                let cad = i.targetCadence.map { " · \(i.averageCadence ?? 0)/\($0) rpm" } ?? ""
                hub.appendLog("   Intervalo \(i.number): \(i.averageWatts)/\(i.targetWatts) W\(cad)")
            }
            for n in r.notes { hub.appendLog("   \(n.tone == .good ? "✅" : n.tone == .warning ? "⚠️" : "ℹ️") \(n.text)") }
            hub.appendLog("   ➡️ Próxima vez: \(r.nextTime)")
        }
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
        guard !hub.isDemo else {
            show("🧪 Modo prueba: el FTP no cambia")
            return
        }
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
        guard var rec = recording else { return }
        if mode == .workout {
            rec.baseIntensity = baseIntensity
            rec.intensity = intensity
        }
        recording = nil
        guard !hub.isDemo else {
            hub.appendLog("🧪 Modo prueba: no se guarda ni se sube")
            return
        }
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
            #if os(macOS)
            if GarminExport.opensOnFinish {
                GarminExport.open(rec, store: store)
                hub.appendLog("🟦 Garmin Connect: abierta la página de importar; arrastra el .fit seleccionado")
            }
            #endif
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
        let now = hub.now() // en modo prueba acelerado, más deprisa
        let dt = lastTick.map { min(max(now - $0, 0), 2) } ?? 0
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
            // Sin rodillo no avanza el entreno: al volver sigues en el mismo tramo (y la grabación,
            // una muestra por segundo de entreno, sigue alineada con los tramos para el análisis).
            if trainerConnected { workoutSeconds += dt }
            if let w = workout, workoutSeconds >= Double(w.durationSeconds) {
                hub.appendLog("✅ Entreno completado")
                finish()
                return
            }
            if rampHasEnded(data, now: now) {
                hub.appendLog("🏁 Test de rampa: has dejado de pedalear; lo termino")
                finish()
                show("🏁 Test terminado", seconds: 4)
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

    /// El test de rampa acaba cuando no puedes más: a partir de 10', 10 s sin pedalear lo terminan
    /// (sin tener que pulsar nada).
    private func rampHasEnded(_ data: IndoorBikeData, now: Double) -> Bool {
        guard workout?.ftpTest == .ramp, workoutSeconds >= 600,
              (data.powerWatts ?? 0) == 0, (data.cadenceRpm ?? 0) == 0 else {
            rampStoppedSince = nil
            return false
        }
        let since = rampStoppedSince ?? now
        rampStoppedSince = since
        return now - since >= 10
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
            trace.append(TracePoint(t: workoutSeconds, power: data.powerWatts ?? 0, heartRate: hub.heartRateBpm,
                                    cadence: data.cadenceRpm.map { Int($0.rounded()) }))
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
    private func applyTarget(force: Bool, now: Double? = nil) {
        let now = now ?? hub.now()
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
