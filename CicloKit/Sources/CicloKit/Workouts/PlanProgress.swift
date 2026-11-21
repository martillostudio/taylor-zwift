import Foundation

/// Cómo va una sesión del plan.
public enum PlanSessionStatus: Equatable, Sendable {
    /// Hecha con un entreno guardado (al menos el 80 % del tiempo previsto) o marcada a mano.
    case done(on: Date?)
    /// Empezada pero cortada antes del 80 %.
    case partial(fraction: Double, on: Date)
    /// Toca hoy.
    case today
    /// Su día ya pasó y no se hizo. No se recupera: se sigue con la siguiente.
    case skipped
    case upcoming

    public var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}

/// Un entreno hecho, lo justo para cruzarlo con el plan.
public struct CompletedWorkout: Equatable, Sendable {
    public var start: Date
    public var workoutID: String?
    public var seconds: Double

    public init(start: Date, workoutID: String?, seconds: Double) {
        self.start = start
        self.workoutID = workoutID
        self.seconds = seconds
    }
}

extension Activity {
    public var asCompletedWorkout: CompletedWorkout {
        CompletedWorkout(start: start, workoutID: workoutID, seconds: timerSeconds)
    }
}

extension PlanSession {
    /// Días desde el lunes: «Lun» = 0 … «Dom» = 6.
    public var weekdayOffset: Int {
        let days = ["lun", "mar", "mié", "jue", "vie", "sáb", "dom"]
        let key = day.lowercased().prefix(3)
        return days.firstIndex { $0 == key } ?? 0
    }

    /// Clave estable para guardar las marcas manuales.
    public func key(week: Int) -> String { "s\(week)-\(id)" }
}

extension TrainingPlan {
    /// Lunes de la semana `number` (1…) si el plan empieza el lunes `start`.
    public func startOfWeek(_ number: Int, start: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: (number - 1) * 7, to: calendar.startOfDay(for: start)) ?? start
    }

    /// Estado de cada sesión de una semana. Un entreno cuenta para una sesión si es el mismo
    /// entreno y se hizo esa semana (da igual el día). Cada entreno cuenta una sola vez.
    public func status(
        of week: PlanWeek, start: Date, completed: [CompletedWorkout], manuallyDone: Set<String> = [],
        now: Date = Date(), calendar: Calendar = .current
    ) -> [String: PlanSessionStatus] {
        let weekStart = startOfWeek(week.number, start: start, calendar: calendar)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        var pool = completed
            .filter { $0.start >= weekStart && $0.start < weekEnd }
            .sorted { $0.start < $1.start }
        let today = calendar.startOfDay(for: now)
        var result: [String: PlanSessionStatus] = [:]

        for session in week.sessions {
            if manuallyDone.contains(session.key(week: week.number)) {
                result[session.id] = .done(on: nil)
                continue
            }
            var best: (index: Int, fraction: Double)?
            if let w = session.workout {
                for (i, c) in pool.enumerated() where c.workoutID == w.id {
                    let f = c.seconds / Double(max(w.durationSeconds, 1))
                    if best == nil || f > best!.fraction { best = (i, f) }
                }
            }
            if let best {
                let c = pool.remove(at: best.index)
                result[session.id] = best.fraction >= 0.8 ? .done(on: c.start) : .partial(fraction: best.fraction, on: c.start)
                continue
            }
            let day = calendar.date(byAdding: .day, value: session.weekdayOffset, to: weekStart) ?? weekStart
            result[session.id] = day == today ? .today : (day < today ? .skipped : .upcoming)
        }
        return result
    }

    /// La sesión que toca hacer ahora: la primera de la semana que no está hecha ni pasada
    /// (si hoy no toca nada, la siguiente).
    public func nextSession(
        in week: PlanWeek, statuses: [String: PlanSessionStatus]
    ) -> PlanSession? {
        week.sessions.first { s in
            switch statuses[s.id] {
            case .today, .upcoming, .partial: true
            default: false
            }
        }
    }
}
