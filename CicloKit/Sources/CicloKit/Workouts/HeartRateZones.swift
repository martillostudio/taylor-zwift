/// Zonas de pulso por % de la frecuencia cardiaca máxima (las que usa Garmin por defecto).
public enum HeartRateZone: Int, CaseIterable, Comparable, Sendable {
    case z1 = 1, z2, z3, z4, z5

    public var name: String {
        switch self {
        case .z1: "Calentamiento"
        case .z2: "Suave (base aeróbica)"
        case .z3: "Aeróbico / tempo"
        case .z4: "Umbral"
        case .z5: "Máximo"
        }
    }

    /// Fracción de la FC máxima donde empieza la zona.
    public var lowFraction: Double {
        switch self {
        case .z1: 0.50
        case .z2: 0.60
        case .z3: 0.70
        case .z4: 0.80
        case .z5: 0.90
        }
    }

    public var highFraction: Double {
        switch self {
        case .z5: 1.0
        default: HeartRateZone(rawValue: rawValue + 1)!.lowFraction
        }
    }

    public func bpmRange(max: Int) -> ClosedRange<Int> {
        let lo = Int((Double(max) * lowFraction).rounded())
        let hi = Int((Double(max) * highFraction).rounded()) - (self == .z5 ? 0 : 1)
        return lo...hi
    }

    /// Zona de un pulso (por debajo del 50 % cuenta como Z1).
    public init(bpm: Int, max: Int) {
        let f = Double(bpm) / Double(Swift.max(max, 1))
        self = HeartRateZone.allCases.last { f >= $0.lowFraction } ?? .z1
    }

    public static func < (a: HeartRateZone, b: HeartRateZone) -> Bool { a.rawValue < b.rawValue }
}
