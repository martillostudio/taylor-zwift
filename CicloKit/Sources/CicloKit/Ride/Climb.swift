/// Banda de pendiente para colorear perfiles, como en los Garmin (ClimbPro) y Wahoo:
/// verde 0–3 %, amarillo 3–6 %, naranja 6–9 %, rojo 9–12 %, rojo oscuro > 12 %.
public enum GradeBand: Int, CaseIterable, Comparable, Sendable {
    case descent
    case easy
    case moderate
    case hard
    case veryHard
    case extreme

    public init(gradePercent g: Double) {
        switch g {
        case ..<(-1): self = .descent
        case ..<3: self = .easy
        case ..<6: self = .moderate
        case ..<9: self = .hard
        case ..<12: self = .veryHard
        default: self = .extreme
        }
    }

    public var label: String {
        switch self {
        case .descent: "Bajada"
        case .easy: "0–3 %"
        case .moderate: "3–6 %"
        case .hard: "6–9 %"
        case .veryHard: "9–12 %"
        case .extreme: "> 12 %"
        }
    }

    public static func < (a: GradeBand, b: GradeBand) -> Bool { a.rawValue < b.rawValue }
}

/// Categoría de una subida según su puntuación (metros × pendiente media en %),
/// con los umbrales de Garmin ClimbPro.
public enum ClimbCategory: Int, CaseIterable, Comparable, Sendable {
    case uncategorized
    case cat4
    case cat3
    case cat2
    case cat1
    case hc

    public init(score: Double) {
        switch score {
        case 80_000...: self = .hc
        case 64_000...: self = .cat1
        case 32_000...: self = .cat2
        case 16_000...: self = .cat3
        case 8_000...: self = .cat4
        default: self = .uncategorized
        }
    }

    public var label: String {
        switch self {
        case .uncategorized: "Sin categoría"
        case .cat4: "4.ª categoría"
        case .cat3: "3.ª categoría"
        case .cat2: "2.ª categoría"
        case .cat1: "1.ª categoría"
        case .hc: "Especial (HC)"
        }
    }

    /// Banda de color con la que se pinta (como en Garmin: verde, amarillo, naranja, rojo, rojo oscuro).
    public var band: GradeBand {
        switch self {
        case .uncategorized, .cat4: .easy
        case .cat3: .moderate
        case .cat2: .hard
        case .cat1: .veryHard
        case .hc: .extreme
        }
    }

    public static func < (a: ClimbCategory, b: ClimbCategory) -> Bool { a.rawValue < b.rawValue }
}

/// Una subida de la ruta (distancias dentro de una vuelta).
public struct Climb: Identifiable, Hashable, Sendable {
    public var startMeters: Double
    public var endMeters: Double
    public var startElevation: Double
    public var endElevation: Double

    public var id: Double { startMeters }
    public var lengthMeters: Double { endMeters - startMeters }
    public var ascentMeters: Double { endElevation - startElevation }
    public var averageGradePercent: Double { ascentMeters / lengthMeters * 100 }
    /// Metros × pendiente media (%): lo que usa Garmin para decidir si es subida y su categoría.
    public var score: Double { lengthMeters * averageGradePercent }
    public var category: ClimbCategory { ClimbCategory(score: score) }

    /// Criterio de Garmin ClimbPro: al menos 500 m, 3 % de media y puntuación ≥ 3.500.
    public static func qualifies(lengthMeters: Double, ascentMeters: Double) -> Bool {
        guard lengthMeters >= 500 else { return false }
        let avg = ascentMeters / lengthMeters * 100
        return avg >= 3 && lengthMeters * avg >= 3_500
    }
}

/// Dónde estás respecto a una subida: en ella o acercándote.
public struct ClimbStatus: Equatable, Sendable {
    public var climb: Climb
    /// Metros hasta el pie de la subida (0 si ya estás en ella).
    public var distanceToStart: Double
    public var remainingMeters: Double
    public var remainingAscentMeters: Double
    /// Fracción de la subida ya hecha (0…1).
    public var progress: Double

    public var isOnClimb: Bool { distanceToStart <= 0 }
    public var remainingAverageGradePercent: Double {
        remainingMeters > 0 ? remainingAscentMeters / remainingMeters * 100 : 0
    }
}

/// Un trozo del perfil para pintarlo con el color de su pendiente.
public struct RouteChunk: Identifiable, Hashable, Sendable {
    public var id: Int
    public var startMeters: Double
    public var endMeters: Double
    public var startElevation: Double
    public var endElevation: Double

    public var gradePercent: Double {
        (endElevation - startElevation) / (endMeters - startMeters) * 100
    }
    public var band: GradeBand { GradeBand(gradePercent: gradePercent) }
}

extension Route {
    /// Tramos que dejan de contar como «subiendo» sin cortar la subida: un descansillo de
    /// hasta 300 m o que pierde hasta 10 m.
    static let climbGapMeters = 300.0
    static let climbGapLossMeters = 10.0

    /// Subidas de una vuelta, con el criterio de Garmin ClimbPro.
    public var climbs: [Climb] {
        var result: [Climb] = []
        var start: (meters: Double, elevation: Double)?
        var peak = (meters: 0.0, elevation: 0.0)
        var distance = 0.0
        var elevation = 0.0

        func close() {
            if let s = start, Climb.qualifies(lengthMeters: peak.meters - s.meters, ascentMeters: peak.elevation - s.elevation) {
                result.append(Climb(startMeters: s.meters, endMeters: peak.meters,
                                    startElevation: s.elevation, endElevation: peak.elevation))
            }
            start = nil
        }

        for segment in segments {
            let segmentStart = (meters: distance, elevation: elevation)
            distance += segment.lengthMeters
            elevation += segment.lengthMeters * segment.gradePercent / 100

            if segment.gradePercent >= 1 {
                if start == nil {
                    start = segmentStart
                    peak = (distance, elevation)
                } else if elevation > peak.elevation {
                    peak = (distance, elevation)
                }
            } else if start != nil {
                if distance - peak.meters > Self.climbGapMeters || peak.elevation - elevation > Self.climbGapLossMeters {
                    close()
                }
            }
        }
        close()
        return result
    }

    /// La subida en la que estás o la siguiente si está a menos de `lookAhead` metros.
    public func climbStatus(atDistance d: Double, lookAhead: Double = 2_000) -> ClimbStatus? {
        let all = climbs
        guard !all.isEmpty else { return nil }
        if !isLoop, d >= lengthMeters { return nil }
        let pos = positionInLap(d)

        if let c = all.first(where: { pos >= $0.startMeters && pos < $0.endMeters }) {
            let here = elevationInLap(pos)
            return ClimbStatus(
                climb: c, distanceToStart: 0,
                remainingMeters: c.endMeters - pos,
                remainingAscentMeters: c.endElevation - here,
                progress: (pos - c.startMeters) / c.lengthMeters
            )
        }

        var best: (climb: Climb, distance: Double)?
        for c in all {
            var gap = c.startMeters - pos
            if gap < 0 {
                guard isLoop else { continue }
                gap += lengthMeters // la de la vuelta siguiente
            }
            if gap <= lookAhead, gap < (best?.distance ?? .infinity) { best = (c, gap) }
        }
        guard let best else { return nil }
        return ClimbStatus(
            climb: best.climb, distanceToStart: best.distance,
            remainingMeters: best.climb.lengthMeters,
            remainingAscentMeters: best.climb.ascentMeters,
            progress: 0
        )
    }

    /// Trozos de `size` metros entre `from` y `to` (distancias absolutas: pueden pasar de vuelta).
    public func chunks(from: Double, to: Double, size: Double) -> [RouteChunk] {
        guard to > from, size > 0 else { return [] }
        let n = Int(((to - from) / size).rounded(.up))
        return (0..<n).map { i in
            let a = from + Double(i) * size
            let b = min(a + size, to)
            return RouteChunk(id: i, startMeters: a, endMeters: b,
                              startElevation: elevation(atDistance: a), endElevation: elevation(atDistance: b))
        }
    }
}
