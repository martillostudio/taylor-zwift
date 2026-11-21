import Foundation

/// Un cambio del plan que propone la app. Nunca se aplica solo: lo aceptas o lo descartas.
public struct PlanProposal: Identifiable, Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        /// Pasar la sesión (clave original) a otro día de su semana.
        case move(key: String, toDay: String)
        /// Cambiar la sesión (clave original) por otro entreno de la biblioteca.
        case swap(key: String, workoutID: String)
        /// Intensidad por defecto para un tipo de entreno (1 = 100 %).
        case intensity(category: WorkoutCategory, to: Double)

        /// Cambia el calendario (y hay que volver a mandarlo a intervals.icu).
        public var affectsCalendar: Bool {
            if case .intensity = self { return false }
            return true
        }
    }

    /// Estable: si la descartas, no vuelve a salir la misma.
    public var id: String
    public var title: String
    public var detail: String
    public var change: Change
}

/// Cómo fue un entreno guardado, para ver tendencias por tipo de entreno.
public struct WorkoutOutcome: Equatable, Sendable {
    public var date: Date
    public var category: WorkoutCategory
    /// Cumplimiento de los intervalos (de `WorkoutReview`), si los había.
    public var compliance: Double?
    public var baseIntensity: Double
    public var finalIntensity: Double

    public init(date: Date, category: WorkoutCategory, compliance: Double?, baseIntensity: Double, finalIntensity: Double) {
        self.date = date
        self.category = category
        self.compliance = compliance
        self.baseIntensity = baseIntensity
        self.finalIntensity = finalIntensity
    }
}

/// El «entrenador» que propone cambios del plan:
/// 1. **Sesión de calidad saltada** → pasarla a un día libre de la misma semana (sin pegarla a otra dura).
/// 2. **Muy cansado** (frescura < −20) y hoy o mañana toca algo duro → cambiarlo por Z2 60'
///    (o por recuperación 30' si la frescura baja de −30).
/// 3. **Intervalos por debajo** dos veces seguidas en un tipo de entreno → bajar ese tipo un 5 %.
/// 4. **Tus ±** en la misma dirección dos veces seguidas en un tipo → usar esa intensidad por defecto.
public enum PlanAdvisor {
    static let dayLongNames = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]

    public static func proposals(
        week: PlanWeek, statuses: [String: PlanSessionStatus], todayOffset: Int,
        freshness: Double?, outcomes: [WorkoutOutcome], categoryIntensity: [WorkoutCategory: Double],
        now: Date = Date()
    ) -> [PlanProposal] {
        var result: [PlanProposal] = []

        // 1. Sesiones de calidad saltadas esta semana.
        for s in week.sessions {
            guard statuses[s.id] == .skipped, let w = s.workout, Coach.isHard(w) else { continue }
            guard let day = freeDay(in: week, from: todayOffset, statuses: statuses) else { continue }
            let key = s.stableKey(week: week.number)
            result.append(PlanProposal(
                id: "mover-\(key)-\(PlanSession.dayNames[day])",
                title: "Recupera «\(w.name)» el \(dayLongNames[day])",
                detail: "Te la saltaste el \(dayLongNames[s.weekdayOffset]). El \(dayLongNames[day]) está libre y no va pegado a otra sesión dura.",
                change: .move(key: key, toDay: PlanSession.dayNames[day])
            ))
        }

        // 2. Muy cansado: lo duro de hoy o mañana, por algo suave.
        if let tsb = freshness, tsb < -20 {
            let veryTired = tsb < -30
            let soon = week.sessions.filter { s in
                let st = statuses[s.id]
                return (st == .today || st == .upcoming) && (s.weekdayOffset - todayOffset) <= 1
            }
            for s in soon {
                guard let w = s.workout, w.category != .recovery else { continue }
                guard veryTired || Coach.isHard(w) else { continue }
                let target = veryTired ? "recuperacion-30" : "z2-60"
                guard w.id != target, let new = Workout.library.first(where: { $0.id == target }) else { continue }
                let key = s.stableKey(week: week.number)
                let when = s.weekdayOffset == todayOffset ? "hoy" : "mañana"
                result.append(PlanProposal(
                    id: "cambiar-\(key)-\(target)",
                    title: "Cambia «\(w.name)» de \(when) por «\(new.name)»",
                    detail: "Frescura \(Int(tsb.rounded())): vas \(veryTired ? "muy " : "")cargado. "
                        + (veryTired ? "Toca asimilar; apretar ahora es cuando llegan el estancamiento o las lesiones."
                                     : "Mejor rodar suave y dejar la intensidad para cuando estés más fresco."),
                    change: .swap(key: key, workoutID: target)
                ))
            }
        }

        // 3 y 4. Tendencias por tipo de entreno (las dos últimas veces, en el último mes).
        let recent = outcomes.filter { now.timeIntervalSince($0.date) < 30 * 86_400 && $0.category != .test }
        for category in WorkoutCategory.allCases {
            let last = recent.filter { $0.category == category }.sorted { $0.date > $1.date }.prefix(2)
            guard last.count == 2 else { continue }
            let current = categoryIntensity[category] ?? 1
            var proposed: Double?
            var why = ""
            if last.allSatisfy({ ($0.compliance ?? 1) < 0.9 }) {
                proposed = max(current - 0.05, 0.8)
                why = "Las dos últimas veces te quedaste por debajo del 90 % en los intervalos."
            } else {
                let deltas = last.map { $0.finalIntensity - $0.baseIntensity }
                if deltas.allSatisfy({ $0 <= -0.02 }) || deltas.allSatisfy({ $0 >= 0.02 }) {
                    proposed = last.map(\.finalIntensity).reduce(0, +) / 2
                    why = "Las dos últimas veces la pusiste ahí con − / + durante el entreno."
                }
            }
            guard var to = proposed else { continue }
            to = min(max((to * 100).rounded() / 100, 0.8), 1.1)
            guard abs(to - current) >= 0.02 else { continue }
            let pct = Int((to * 100).rounded())
            result.append(PlanProposal(
                id: "intensidad-\(category.rawValue)-\(pct)",
                title: "\(category.rawValue): empieza al \(pct) %",
                detail: why + " Los próximos \(category.rawValue.lowercased()) arrancarán al \(pct) % (ahora \(Int((current * 100).rounded())) %); lo puedes seguir cambiando con − / +.",
                change: .intensity(category: category, to: to)
            ))
        }
        return result
    }

    /// Primer día desde `from` sin sesión, que no esté pegado a una sesión dura (ni antes ni después).
    static func freeDay(in week: PlanWeek, from: Int, statuses: [String: PlanSessionStatus]) -> Int? {
        guard from <= 6 else { return nil }
        let busy = Set(week.sessions.map(\.weekdayOffset))
        let hard = Set(week.sessions.filter { s in
            guard let w = s.workout, Coach.isHard(w) else { return false }
            return statuses[s.id] != .skipped
        }.map(\.weekdayOffset))
        return (max(from, 0)...6).first { d in
            !busy.contains(d) && !hard.contains(d - 1) && !hard.contains(d + 1)
        }
    }
}
