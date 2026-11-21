import Foundation

// MARK: - ¿Qué toca hoy?

/// Lo que conviene hacer hoy, de más a menos exigente.
public enum DayCall: Equatable, Sendable {
    /// Sesión dura y estás para ella.
    case push
    /// Rodaje controlado (Z2) o sesión moderada.
    case steady
    /// Hazlo, pero suave: hay cansancio.
    case easy
    /// Descanso (o ya está hecho).
    case rest
}

public struct TodayAdvice: Equatable, Sendable {
    public var call: DayCall
    public var headline: String
    /// Los porqués, en frases cortas.
    public var reasons: [String]
}

public enum Coach {
    /// Una sesión es «dura» si tiene tramos por encima del 88 % del FTP (sweet spot o más) o es un test.
    public static func isHard(_ workout: Workout) -> Bool {
        workout.ftpTest != nil || workout.peakFraction >= 0.88
    }

    /// El semáforo del día.
    /// - Parameters:
    ///   - freshness: frescura de hoy (forma − cansancio), si la hay.
    ///   - rampPerWeek: cuánto ha subido la forma en los últimos 7 días.
    ///   - session: lo que el plan pone para hoy (`nil` = no hay nada).
    ///   - doneToday: ya has hecho la sesión de hoy.
    ///   - yesterdayLoad: carga (TSS) de ayer.
    ///   - todayLoad: carga que ya llevas hoy (otras salidas que no son la sesión del plan).
    public static func today(freshness: Double?, rampPerWeek: Double?, session: PlanSession?,
                             doneToday: Bool, yesterdayLoad: Double = 0, todayLoad: Double = 0) -> TodayAdvice {
        let tsb = freshness
        let tsbText = tsb.map { "Frescura \(signed($0))" }
        var reasons: [String] = []

        if doneToday {
            return TodayAdvice(call: .rest, headline: "Hecho por hoy", reasons: [
                "Ya has hecho \(session.map(name) ?? "la sesión"). Ahora toca asimilar: come bien, bebe y duerme.",
            ])
        }

        if todayLoad >= 80 {
            reasons.append("Hoy ya llevas \(Int(todayLoad.rounded())) TSS: suficiente para un día.")
            if let session { reasons.append("Deja \(name(session)) para mañana; si no puede ser, sáltala y sigue con el plan.") }
            return TodayAdvice(call: .rest, headline: "Ya has cargado hoy", reasons: reasons)
        }

        let workout = session?.workout
        let hard = workout.map(isHard) ?? false

        if let t = tsb, t < -30 {
            reasons.append("\(tsbText!): mucho cansancio acumulado; seguir apretando es cuando llegan el estancamiento o las lesiones.")
            if let session { reasons.append("Pasa \(name(session)) a otro día o haz 30' muy suaves (Z1).") }
            return TodayAdvice(call: .rest, headline: "Descansa", reasons: reasons)
        }

        guard let session else {
            reasons.append("El plan no tiene sesión hoy. Descansar también entrena: es cuando el cuerpo asimila el trabajo.")
            if let t = tsb, t > 15 {
                reasons.append("\(tsbText!): estás fresco; si te apetece, 45–60' en Z2 no te harán daño.")
            }
            return TodayAdvice(call: .rest, headline: "Día de descanso", reasons: reasons)
        }

        if let t = tsb, t < -20 {
            reasons.append("\(tsbText!): vas cargado.")
            reasons.append(hard ? "Cambia \(name(session)) por 60' en Z2; la intensidad, cuando estés más fresco."
                : "Haz \(name(session)), pero sin pasarte de Z2 aunque te veas bien.")
            return TodayAdvice(call: .easy, headline: "Hoy, suave", reasons: reasons)
        }

        if yesterdayLoad >= 100 {
            reasons.append("Ayer cargaste \(Int(yesterdayLoad.rounded())) TSS: calienta bien antes de nada.")
        }
        if let r = rampPerWeek, r > 8 {
            reasons.append("Tu forma sube \(signed(r)) por semana, rápido: no añadas nada fuera del plan.")
        }

        if hard {
            reasons.insert("\(name(session)): \(describe(session.workout!)).", at: 0)
            if let t = tsbText { reasons.insert("\(t): estás para ello.", at: 1) }
            return TodayAdvice(call: .push, headline: workout?.ftpTest != nil ? "Día de test" : "Toca apretar", reasons: reasons)
        }
        if let w = workout {
            reasons.insert("\(name(session)): \(describe(w)). Pulso controlado, sin cambios de ritmo.", at: 0)
        } else {
            reasons.insert("Salida en exterior de \(hoursText(session.outdoorHours)) en Z2 (o «Resistencia 2 h» en el rodillo si hace malo).", at: 0)
        }
        return TodayAdvice(call: .steady, headline: "Rodaje controlado", reasons: reasons)
    }

    static func name(_ s: PlanSession) -> String {
        s.workout.map { "«\($0.name)»" } ?? "la salida en exterior"
    }

    static func describe(_ w: Workout) -> String {
        "\(w.durationSeconds / 60)' · TSS \(Int(w.tss.rounded()))"
    }

    static func signed(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }

    static func hoursText(_ h: Double) -> String {
        h == h.rounded() ? "\(Int(h)) h" : "\(String(format: "%.1f", h).replacingOccurrences(of: ".", with: ",")) h"
    }
}

// MARK: - Hacia dónde vamos

/// Un bloque del plan (Base 1, Descarga 1…): semanas seguidas con el mismo nombre.
public struct PlanPhase: Identifiable, Equatable, Sendable {
    public var name: String
    public var weeks: ClosedRange<Int>
    public var isRecovery: Bool
    public var id: Int { weeks.lowerBound }
}

extension TrainingPlan {
    public var phases: [PlanPhase] {
        var out: [PlanPhase] = []
        for w in weeks {
            if let last = out.last, last.name == w.block {
                out[out.count - 1].weeks = last.weeks.lowerBound...w.number
            } else {
                out.append(PlanPhase(name: w.block, weeks: w.number...w.number, isRecovery: w.isRecovery))
            }
        }
        return out
    }

    /// La próxima semana de descarga a partir de la semana `week` (incluida).
    public func nextRecoveryWeek(from week: Int) -> PlanWeek? {
        weeks.first { $0.number >= week && $0.isRecovery }
    }

    /// El próximo test (semana y sesión) a partir de la semana `week` (incluida).
    public func nextTest(from week: Int) -> (week: PlanWeek, session: PlanSession)? {
        for w in weeks where w.number >= week {
            if let s = w.sessions.first(where: { $0.workout?.ftpTest != nil }) { return (w, s) }
        }
        return nil
    }

    /// Carga prevista de una semana: los entrenos del rodillo y las salidas en exterior
    /// estimadas (unos 46 de carga por hora).
    public func plannedLoad(of week: PlanWeek) -> Double {
        week.sessions.reduce(0) { sum, s in
            sum + (s.workout?.tss ?? s.outdoorHours * Self.outdoorLoadPerHour)
        }
    }

    /// Carga hecha y prevista por semana del plan, hasta la semana `upTo` (incluida).
    public func weeklyLoads(start: Date, loads: [(date: Date, load: Double)], upTo: Int,
                            calendar: Calendar = .current) -> [WeekLoad] {
        weeks.prefix(max(0, min(upTo, weeks.count))).map { w in
            let from = startOfWeek(w.number, start: start, calendar: calendar)
            let to = calendar.date(byAdding: .day, value: 7, to: from) ?? from
            let done = loads.filter { $0.date >= from && $0.date < to }.reduce(0) { $0 + $1.load }
            return WeekLoad(week: w.number, planned: plannedLoad(of: w), done: done, isRecovery: w.isRecovery)
        }
    }
}

public struct WeekLoad: Identifiable, Equatable, Sendable {
    public var week: Int
    public var planned: Double
    public var done: Double
    public var isRecovery: Bool
    public var id: Int { week }
}

/// Lo rápido que sube la forma (CTL) en una semana.
public enum RampPace: Equatable, Sendable {
    case losing, steady, building, aggressive

    /// Subir la forma 3–7 puntos por semana es lo sostenible; más de 8, riesgo de pasarte.
    public init(perWeek r: Double) {
        switch r {
        case ..<(-1): self = .losing
        case -1..<3: self = .steady
        case 3...8: self = .building
        default: self = .aggressive
        }
    }

    public var text: String {
        switch self {
        case .losing: "Estás perdiendo forma: normal en una semana de descarga, si no, retoma el plan."
        case .steady: "La forma se mantiene."
        case .building: "Subiendo a buen ritmo (3–8 por semana es lo sostenible)."
        case .aggressive: "Subiendo muy rápido: vigila el cansancio y no añadas nada fuera del plan."
        }
    }
}

extension Array where Element == FitnessDay {
    /// Cambio de forma en los últimos 7 días hasta `date`.
    public func rampPerWeek(on date: Date, calendar: Calendar = .current) -> Double? {
        guard let now = day(on: date, calendar: calendar),
              let weekAgo = calendar.date(byAdding: .day, value: -7, to: date),
              let before = day(on: weekAgo, calendar: calendar), before.date < now.date
        else { return nil }
        return now.fitness - before.fitness
    }
}

// MARK: - Mejora aeróbica

extension Activity {
    /// Factor de eficiencia: potencia normalizada / pulso medio. Solo en rodajes aeróbicos
    /// (IF < 0,80) de 30' o más con pulsómetro: si sube con el tiempo, la base mejora.
    public var efficiencyFactor: Double? {
        guard timerSeconds >= 1_800, let hr = averageHeartRate, hr > 60,
              let np = normalizedPower, np > 0, let intensity = intensityFactor, intensity < 0.8
        else { return nil }
        return Double(np) / Double(hr)
    }
}

extension Workout {
    /// El tramo más intenso, en fracción del FTP.
    public var peakFraction: Double {
        segments.compactMap { s in [s.startPower, s.endPower].compactMap { $0 }.max() }.max() ?? 0
    }
}

// MARK: - Sesiones movidas de día

extension TrainingPlan {
    /// El plan con algunas sesiones cambiadas de día. `moves` va de la clave original de la
    /// sesión (`session.key(week:)`, p. ej. «s1-Sáb-z2-90») al día nuevo («Dom»), siempre
    /// dentro de la misma semana.
    public func moving(_ moves: [String: String]) -> TrainingPlan {
        guard !moves.isEmpty else { return self }
        var copy = self
        copy.weeks = weeks.map { week in
            var w = week
            w.sessions = week.sessions.map { s in
                let key = s.originalKey ?? s.key(week: week.number)
                guard let day = moves[key] else { return s }
                var moved = s
                moved.day = day
                moved.originalKey = key
                return moved
            }
            .sorted { $0.weekdayOffset < $1.weekdayOffset }
            return w
        }
        return copy
    }

    /// El plan con algunas sesiones cambiadas por otro entreno de la biblioteca. `swaps` va de la
    /// clave original de la sesión al id del entreno nuevo (p. ej. «s3-Jue-ss-2x20» → «z2-60»).
    public func replacing(_ swaps: [String: String]) -> TrainingPlan {
        guard !swaps.isEmpty else { return self }
        var copy = self
        copy.weeks = weeks.map { week in
            var w = week
            w.sessions = week.sessions.map { s in
                let key = s.originalKey ?? s.key(week: week.number)
                guard let id = swaps[key], Workout.library.contains(where: { $0.id == id }) else { return s }
                var swapped = s
                swapped.workoutID = id
                swapped.originalKey = key
                return swapped
            }
            return w
        }
        return copy
    }
}

// MARK: - FTP automático

public enum FTPUpdate {
    /// El resultado de un test se aplica solo si fuiste a tope: el pulso llegó al 92 % de tu
    /// FC máxima. Un test cortado antes de tiempo daría un FTP demasiado bajo.
    public static func testIsMaximal(maxHeartRate: Int?, athleteMaxHeartRate: Int) -> Bool {
        guard let hr = maxHeartRate else { return false }
        return Double(hr) >= 0.92 * Double(athleteMaxHeartRate)
    }

    /// El eFTP de intervals.icu solo sube el FTP (bajarlo, con un test): sale de tus mejores
    /// esfuerzos y baja solo si no haces nada duro, no porque estés peor.
    public static func raise(current: Int, estimated: Int?) -> Int? {
        guard let e = estimated, e >= current + 5 else { return nil }
        return e
    }
}
