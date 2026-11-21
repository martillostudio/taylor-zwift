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

extension TrainingPlan {
    /// Todas las sesiones del plan con su fecha, si empieza el lunes `start`.
    public func calendarEvents(start: Date, calendar: Calendar = .current) -> [PlannedEvent] {
        weeks.flatMap { week in
            week.sessions.map { session in
                let day = calendar.date(byAdding: .day, value: session.weekdayOffset,
                                        to: startOfWeek(week.number, start: start, calendar: calendar)) ?? start
                let w = session.workout
                var text = "Semana \(week.number) · \(week.block): \(week.focus)."
                if let w { text += "\n\n" + w.summary }
                if !session.note.isEmpty { text += "\n\n" + session.note }
                return PlannedEvent(
                    externalID: "taylorzwift-\(id)-\(session.key(week: week.number))",
                    date: day,
                    name: w?.name ?? "Salida en exterior",
                    description: text,
                    workout: w,
                    // La rampa acaba cuando no puedes más: unos 25' en vez de los 37' escritos.
                    seconds: w.map { $0.ftpTest == .ramp ? 1_500 : $0.durationSeconds } ?? 3 * 3_600,
                    load: w.map { Int($0.tss.rounded()) }
                )
            }
        }
    }
}
