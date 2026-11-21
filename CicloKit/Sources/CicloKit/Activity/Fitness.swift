import Foundation

/// Forma, cansancio y frescura de un día (modelo de Banister, el de intervals.icu y TrainingPeaks).
///
/// - Forma (CTL, «fitness»): media de la carga de unas 6 semanas. Sube despacio.
/// - Cansancio (ATL, «fatigue»): media de la última semana. Sube y baja rápido.
/// - Frescura (TSB, «form»): forma − cansancio. Negativa mientras entrenas; positiva al descansar.
public struct FitnessDay: Codable, Equatable, Sendable, Identifiable {
    public var date: Date
    public var fitness: Double
    public var fatigue: Double
    public var id: Date { date }
    public var freshness: Double { fitness - fatigue }

    public init(date: Date, fitness: Double, fatigue: Double) {
        self.date = date
        self.fitness = fitness
        self.fatigue = fatigue
    }

    /// Lee `GET /api/v1/athlete/0/wellness?oldest=…&newest=…` (un objeto por día, `id` = fecha).
    /// intervals.icu también da los días futuros: la proyección con los entrenos planificados.
    public static func parseWellness(_ data: Data, timeZone: TimeZone = .current) -> [FitnessDay] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return list.compactMap { o in
            guard let id = o["id"] as? String, let date = formatter.date(from: id),
                  let ctl = (o["ctl"] as? NSNumber)?.doubleValue,
                  let atl = (o["atl"] as? NSNumber)?.doubleValue
            else { return nil }
            return FitnessDay(date: date, fitness: ctl, fatigue: atl)
        }
        .sorted { $0.date < $1.date }
    }
}

/// Cómo estás según la frescura (franjas clásicas de intervals.icu).
public enum FormState: Equatable, Sendable {
    /// > 20: descansas tanto que pierdes forma.
    case transition
    /// 5…20: fresco, buen momento para un test o una salida exigente.
    case fresh
    /// −10…5: ni cargado ni descansado.
    case neutral
    /// −30…−10: cargado: es donde se gana forma.
    case optimal
    /// < −30: demasiado cansancio acumulado.
    case highRisk

    public init(freshness t: Double) {
        switch t {
        case 20...: self = .transition
        case 5..<20: self = .fresh
        case -10..<5: self = .neutral
        case -30 ..< -10: self = .optimal
        default: self = .highRisk
        }
    }

    public var name: String {
        switch self {
        case .transition: "Perdiendo forma"
        case .fresh: "Fresco"
        case .neutral: "Neutro"
        case .optimal: "Entrenando"
        case .highRisk: "Demasiado cansado"
        }
    }

    public var advice: String {
        switch self {
        case .transition: "Llevas días con poca carga: retoma el plan."
        case .fresh: "Buen momento para un test o una sesión dura."
        case .neutral: "Sigue el plan tal cual."
        case .optimal: "Estás cargando bien: así se gana forma. Duerme y come bien."
        case .highRisk: "Mucho cansancio acumulado: cambia la próxima sesión dura por Z2 o descansa."
        }
    }
}

extension Array where Element == FitnessDay {
    /// El día de `date` (o el último anterior).
    public func day(on date: Date, calendar: Calendar = .current) -> FitnessDay? {
        let end = calendar.startOfDay(for: date)
        return last { $0.date <= end }
    }
}
