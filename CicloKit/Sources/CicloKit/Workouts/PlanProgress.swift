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
    /// Salida en exterior (de Garmin vía intervals.icu): cuenta para las sesiones sin entreno.
    public var isOutdoor: Bool

    public init(start: Date, workoutID: String?, seconds: Double, isOutdoor: Bool = false) {
        self.start = start
        self.workoutID = workoutID
        self.seconds = seconds
        self.isOutdoor = isOutdoor
    }
}

extension Activity {
    public var asCompletedWorkout: CompletedWorkout {
        CompletedWorkout(start: start, workoutID: workoutID, seconds: timerSeconds)
    }
}

extension PlanSession {
    /// Lo mínimo que tiene que durar una salida en exterior para darla por hecha.
    public static let outdoorMinimumSeconds: Double = 90 * 60
    /// Si hace malo, la salida en exterior se puede cambiar por «Resistencia 2 h» en el rodillo.
    public static let indoorAlternativeID = "z2-120"

    /// Los días tal como van en el plan y en las sesiones movidas, de lunes a domingo.
    public static let dayNames = ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"]

    /// Días desde el lunes: «Lun» = 0 … «Dom» = 6.
    public var weekdayOffset: Int {
        let key = day.lowercased().prefix(3)
        return Self.dayNames.firstIndex { $0.lowercased() == key } ?? 0
    }

    /// Clave estable para guardar las marcas manuales.
    public func key(week: Int) -> String { "s\(week)-\(id)" }

    /// Clave de la sesión en el plan original, aunque la hayas movido o cambiado de entreno:
    /// es la que usan `sesionesMovidas` y `sesionesCambiadas`.
    public func stableKey(week: Int) -> String { originalKey ?? key(week: week) }
}

extension TrainingPlan {
    /// Lunes de la semana `number` (1…) si el plan empieza el lunes `start`.
    public func startOfWeek(_ number: Int, start: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: (number - 1) * 7, to: calendar.startOfDay(for: start)) ?? start
    }

    /// Días desde el lunes de la semana `number` hasta `date` (0 = lunes).
    public func dayOffset(on date: Date, week number: Int, start: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: startOfWeek(number, start: start, calendar: calendar),
                                to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Estado de cada sesión de una semana. Un entreno cuenta para una sesión si es el mismo
    /// entreno y se hizo esa semana (da igual el día). Una salida en exterior cuenta para las
    /// sesiones sin entreno («Salida en exterior»): hecha si dura al menos 1 h 30 min.
    /// Cada entreno o salida cuenta una sola vez.
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
                // El test de rampa acaba cuando no puedes más: vale con pasar del calentamiento
                // y unos cuantos escalones (10'), no con llegar al final previsto.
                let needed = w.ftpTest == .ramp ? 600 : Double(max(w.durationSeconds, 1))
                for (i, c) in pool.enumerated() where c.workoutID == w.id {
                    let f = min(c.seconds / needed, 1)
                    if best == nil || f > best!.fraction { best = (i, f) }
                }
            } else {
                for (i, c) in pool.enumerated() where c.isOutdoor || c.workoutID == PlanSession.indoorAlternativeID {
                    let f = c.seconds / PlanSession.outdoorMinimumSeconds
                    if best == nil || f > best!.fraction { best = (i, f) }
                }
            }
            if let best {
                let c = pool.remove(at: best.index)
                result[session.id] = best.fraction >= (session.workout == nil ? 1 : 0.8) ? .done(on: c.start) : .partial(fraction: best.fraction, on: c.start)
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
