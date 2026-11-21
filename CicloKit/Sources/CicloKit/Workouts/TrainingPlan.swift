import Foundation

/// Una sesión del plan: un entreno de la biblioteca o una salida en exterior.
public struct PlanSession: Identifiable, Equatable, Sendable {
    public var id: String { "\(day)-\(workoutID ?? note)" }
    /// «Mar», «Jue», «Sáb»…
    public var day: String
    /// Entreno de `Workout.library`; `nil` = salida en exterior o libre (ver `note`).
    public var workoutID: String?
    public var note: String

    public init(_ day: String, _ workoutID: String?, _ note: String = "") {
        self.day = day
        self.workoutID = workoutID
        self.note = note
    }

    public var workout: Workout? {
        workoutID.flatMap { id in Workout.library.first { $0.id == id } }
    }
}

public struct PlanWeek: Identifiable, Equatable, Sendable {
    public var number: Int
    public var block: String
    public var focus: String
    public var sessions: [PlanSession]
    public var id: Int { number }

    /// Semana de descarga (menos carga para asimilar).
    public var isRecovery: Bool { block.hasPrefix("Descarga") }

    /// TSS previsto de los entrenos del rodillo (sin contar las salidas en exterior).
    public var plannedTSS: Int {
        Int(sessions.compactMap(\.workout).reduce(0) { $0 + $1.tss }.rounded())
    }

    public var plannedSeconds: Int {
        sessions.compactMap(\.workout).reduce(0) { $0 + $1.durationSeconds }
    }
}

public struct TrainingPlan: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var weeks: [PlanWeek]

    /// Semana del plan (1…) que toca en `date` si empezó el lunes `start`. `nil` si aún no ha
    /// empezado o ya ha terminado.
    public func weekNumber(on date: Date, start: Date, calendar: Calendar = .current) -> Int? {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: date)).day ?? 0
        guard days >= 0 else { return nil }
        let n = days / 7 + 1
        return n <= weeks.count ? n : nil
    }

    /// El lunes de la semana de `date` (o el siguiente, si `next`).
    public static func monday(onOrAfter date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        let start = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: start) // 1 = domingo, 2 = lunes
        let offset = (9 - weekday) % 7 // días hasta el próximo lunes (0 si ya es lunes)
        return cal.date(byAdding: .day, value: offset, to: start) ?? start
    }

    /// El lunes de la semana de `date` (el mismo día si ya es lunes). El plan siempre empieza en
    /// lunes: si eliges otro día, empieza el lunes de esa semana.
    public static func monday(onOrBefore date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start) // 1 = domingo, 2 = lunes
        let back = (weekday + 5) % 7 // días desde el lunes
        return calendar.date(byAdding: .day, value: -back, to: start) ?? start
    }
}

extension TrainingPlan {
    /// Plan de invierno de 16 semanas en el rodillo: 3 sesiones por semana (martes, jueves y
    /// sábado o domingo), bloques de 3 semanas de carga + 1 de descarga, la mayor parte suave
    /// (Z2) y 2 sesiones de calidad por semana (fuerza a cadencia baja, sweet spot/umbral y
    /// VO2max), con un test de FTP al principio y en cada descarga. Las últimas semanas pasan a
    /// salidas largas en exterior.
    public static let winter = TrainingPlan(
        id: "invierno-16",
        name: "Invierno en el rodillo (16 semanas)",
        summary: "Mantener y mejorar la forma en invierno para llegar a la primavera con más fondo, más fuerza en las subidas y más FTP. 3 días por semana (unas 3–5 h).",
        weeks: [
            PlanWeek(number: 1, block: "Base 1", focus: "Saber tu FTP y empezar suave", sessions: [
                PlanSession("Mar", "test-rampa", "Test para fijar tu FTP: todo el plan va en % de él."),
                PlanSession("Jue", "z2-60"),
                PlanSession("Sáb", "z2-90"),
            ]),
            PlanWeek(number: 2, block: "Base 1", focus: "Fondo y primera fuerza", sessions: [
                PlanSession("Mar", "fuerza-5x5"),
                PlanSession("Jue", "z2-60"),
                PlanSession("Sáb", "z2-90", "Si hace bueno, salida en exterior de 2 h sin pasar de Z2 de pulso."),
            ]),
            PlanWeek(number: 3, block: "Base 1", focus: "Más fondo y tempo", sessions: [
                PlanSession("Mar", "tempo-3x10"),
                PlanSession("Jue", "z2-fuerza-75"),
                PlanSession("Sáb", "z2-120"),
            ]),
            PlanWeek(number: 4, block: "Descarga 1", focus: "Asimilar: todo suave", sessions: [
                PlanSession("Mar", "z2-60"),
                PlanSession("Jue", "recuperacion-30"),
                PlanSession("Sáb", "z2-90"),
            ]),
            PlanWeek(number: 5, block: "Construcción 1", focus: "Sweet spot: subir el FTP", sessions: [
                PlanSession("Mar", "ss-2x20"),
                PlanSession("Jue", "z2-fuerza-75"),
                PlanSession("Sáb", "z2-120"),
            ]),
            PlanWeek(number: 6, block: "Construcción 1", focus: "Sweet spot y primeros intervalos cortos", sessions: [
                PlanSession("Mar", "ss-3x15"),
                PlanSession("Jue", "vo2-30-30"),
                PlanSession("Sáb", "z2-120"),
            ]),
            PlanWeek(number: 7, block: "Construcción 1", focus: "Fuerza-resistencia y VO2max", sessions: [
                PlanSession("Mar", "fuerza-4x8"),
                PlanSession("Jue", "vo2-5x3"),
                PlanSession("Sáb", "z2-120", "O 2–2,5 h en exterior en Z2."),
            ]),
            PlanWeek(number: 8, block: "Descarga 2", focus: "Asimilar y volver a medir", sessions: [
                PlanSession("Mar", "z2-60"),
                PlanSession("Jue", "test-rampa", "Nuevo FTP: acepta el valor que te proponga al terminar."),
                PlanSession("Sáb", "z2-90"),
            ]),
            PlanWeek(number: 9, block: "Construcción 2", focus: "Umbral y VO2max", sessions: [
                PlanSession("Mar", "umbral-3x12"),
                PlanSession("Jue", "vo2-4x4"),
                PlanSession("Sáb", "z2-120"),
            ]),
            PlanWeek(number: 10, block: "Construcción 2", focus: "Cambios de ritmo y fuerza", sessions: [
                PlanSession("Mar", "over-unders"),
                PlanSession("Jue", "fuerza-4x8"),
                PlanSession("Sáb", nil, "Salida en exterior de 2,5–3 h en Z2 (o «Resistencia 2 h» en el rodillo)."),
            ]),
            PlanWeek(number: 11, block: "Construcción 2", focus: "La semana más dura", sessions: [
                PlanSession("Mar", "umbral-3x12"),
                PlanSession("Jue", "vo2-30-15"),
                PlanSession("Sáb", "z2-120"),
            ]),
            PlanWeek(number: 12, block: "Descarga 3", focus: "Asimilar", sessions: [
                PlanSession("Mar", "z2-60"),
                PlanSession("Jue", "recuperacion-30"),
                PlanSession("Sáb", "z2-90"),
            ]),
            PlanWeek(number: 13, block: "Hacia la primavera", focus: "Mantener la intensidad y alargar fuera", sessions: [
                PlanSession("Mar", "ss-3x15"),
                PlanSession("Jue", "vo2-4x4"),
                PlanSession("Sáb", nil, "Salida en exterior de 3 h, en Z2 en llano y a ritmo constante en las subidas."),
            ]),
            PlanWeek(number: 14, block: "Hacia la primavera", focus: "Fuerza para las subidas largas", sessions: [
                PlanSession("Mar", "over-unders"),
                PlanSession("Jue", "fuerza-4x8"),
                PlanSession("Sáb", nil, "Salida en exterior de 3–3,5 h con tus subidas habituales a ritmo de tempo."),
            ]),
            PlanWeek(number: 15, block: "Hacia la primavera", focus: "La salida más larga", sessions: [
                PlanSession("Mar", "umbral-3x12"),
                PlanSession("Jue", "vo2-30-15"),
                PlanSession("Sáb", nil, "Salida en exterior de 3,5–4 h: come cada 45' y no te pases de ritmo al principio."),
            ]),
            PlanWeek(number: 16, block: "Descarga 4", focus: "Test final y a disfrutar", sessions: [
                PlanSession("Mar", "z2-60"),
                PlanSession("Jue", "test-rampa", "Compara con el de la semana 1."),
                PlanSession("Sáb", nil, "Salida libre en exterior."),
            ]),
        ]
    )
}
