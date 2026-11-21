import Foundation

/// Una sesión del plan puesta en un calendario (intervals.icu, y de ahí a Garmin).
public struct PlannedEvent: Equatable, Sendable {
    /// Estable para cada semana y sesión: al volver a mandar el plan se actualiza, no se duplica.
    public var externalID: String
    public var date: Date
    public var name: String
    public var description: String
    /// `nil` = salida en exterior (sin entreno estructurado).
    public var workout: Workout?
    public var seconds: Int
    public var load: Int?
}

extension PlanSession {
    /// Horas previstas de una salida en exterior, sacadas de la nota («3–3,5 h» → 3,25).
    /// Sin horas en la nota, 3 h.
    public var outdoorHours: Double {
        guard let r = note.range(of: #"[\d,–-]+(?= h)"#, options: .regularExpression) else { return 3 }
        let numbers = note[r].split(whereSeparator: { $0 == "–" || $0 == "-" })
            .compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        return numbers.isEmpty ? 3 : numbers.reduce(0, +) / Double(numbers.count)
    }
}

extension TrainingPlan {
    /// Carga por hora de una salida en exterior (media de tus salidas de gravel, jul–nov 2026).
    public static let outdoorLoadPerHour = 46.0

    /// El test de rampa está escrito hasta el 224 % del FTP para que nadie se quede sin escalones,
    /// pero casi todo el mundo para hacia el 130 %. En el calendario se corta ahí (+ 5' suaves)
    /// para que la duración y la carga previstas sean realistas.
    static func forCalendar(_ w: Workout) -> Workout {
        guard w.ftpTest == .ramp else { return w }
        var steps: [WorkoutStep] = []
        for step in w.steps {
            if case .steady(_, let p) = step, p > 1.31 { break }
            steps.append(step)
        }
        steps.append(.ramp(seconds: 300, from: 0.50, to: 0.40))
        return Workout(id: w.id, name: w.name, category: w.category, summary: w.summary,
                       tagline: w.tagline, ftpTest: w.ftpTest, steps: steps)
    }

    /// Todas las sesiones del plan con su fecha, si empieza el lunes `start`.
    public func calendarEvents(start: Date, calendar: Calendar = .current) -> [PlannedEvent] {
        weeks.flatMap { week in
            week.sessions.map { session in
                let day = calendar.date(byAdding: .day, value: session.weekdayOffset,
                                        to: startOfWeek(week.number, start: start, calendar: calendar)) ?? start
                let w = session.workout.map(Self.forCalendar)
                var text = "Semana \(week.number) · \(week.block): \(week.focus)."
                if let w { text += "\n\n" + w.summary }
                if !session.note.isEmpty { text += "\n\n" + session.note }
                return PlannedEvent(
                    externalID: "taylorzwift-\(id)-\(session.key(week: week.number))",
                    date: day,
                    name: w?.name ?? "Salida en exterior",
                    description: text,
                    workout: w,
                    seconds: w?.durationSeconds ?? Int(session.outdoorHours * 3_600),
                    // Tus salidas por la calle dan unos 46 de carga por hora (por pulso, sin potenciómetro).
                    load: w.map { Int($0.tss.rounded()) } ?? Int((session.outdoorHours * Self.outdoorLoadPerHour).rounded())
                )
            }
        }
    }
}
