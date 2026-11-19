import Foundation

/// Un tramo de ruta con pendiente constante.
public struct RouteSegment: Hashable, Sendable {
    public var lengthMeters: Double
    public var gradePercent: Double

    public init(_ lengthMeters: Double, _ gradePercent: Double) {
        self.lengthMeters = lengthMeters
        self.gradePercent = gradePercent
    }
}

/// Un punto del perfil de una ruta, para dibujarlo.
public struct RoutePoint: Hashable, Sendable {
    public var distanceMeters: Double
    public var elevationMeters: Double
}

/// Ruta sencilla: una lista de tramos con pendiente. Puede ser circular (se repite).
public struct Route: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var segments: [RouteSegment]
    /// Si es circular, al acabar se vuelve a empezar; si no, después del final es llano.
    public var isLoop: Bool

    /// Distancia sobre la que se suaviza un cambio de pendiente (para que no dé tirones).
    public static let smoothingMeters = 50.0

    public init(id: String, name: String, isLoop: Bool, segments: [RouteSegment]) {
        precondition(!segments.isEmpty)
        self.id = id
        self.name = name
        self.isLoop = isLoop
        self.segments = segments
    }

    public var lengthMeters: Double { segments.reduce(0) { $0 + $1.lengthMeters } }

    /// Desnivel positivo acumulado de una vuelta.
    public var climbMeters: Double {
        segments.reduce(0) { $0 + max(0, $1.lengthMeters * $1.gradePercent / 100) }
    }

    /// Altura relativa a la salida en el punto `d` (metros recorridos desde la salida).
    public func elevation(atDistance d: Double) -> Double {
        let length = lengthMeters
        if isLoop {
            let laps = (d / length).rounded(.down)
            let lapGain = elevationWithinLap(length)
            return laps * lapGain + elevationWithinLap(d - laps * length)
        }
        if d <= 0 { return d * segments[0].gradePercent / 100 }
        if d >= length { return elevationWithinLap(length) } // después del final: llano
        return elevationWithinLap(d)
    }

    /// Pendiente en `d`, en %, suavizada en los cambios de tramo.
    public func grade(atDistance d: Double) -> Double {
        let h = Self.smoothingMeters / 2
        let g = (elevation(atDistance: d + h) - elevation(atDistance: d - h)) / Self.smoothingMeters * 100
        return (g * 10).rounded() / 10 // décimas de %: evita mandar cambios minúsculos
    }

    /// Posición dentro de la vuelta actual (para dibujarla sobre el perfil).
    public func positionInLap(_ d: Double) -> Double {
        guard isLoop else { return min(max(d, 0), lengthMeters) }
        let length = lengthMeters
        return d - (d / length).rounded(.down) * length
    }

    /// `true` si la ruta no es circular y ya has llegado al final.
    public func isFinished(atDistance d: Double) -> Bool {
        !isLoop && d >= lengthMeters
    }

    /// Perfil de una vuelta con `points` puntos.
    public func profile(points: Int = 200) -> [RoutePoint] {
        let n = max(points, 2)
        let length = lengthMeters
        return (0..<n).map { i in
            let d = length * Double(i) / Double(n - 1)
            return RoutePoint(distanceMeters: d, elevationMeters: elevationWithinLap(d))
        }
    }

    private func elevationWithinLap(_ d: Double) -> Double {
        var start = 0.0
        var elevation = 0.0
        for s in segments {
            if d <= start + s.lengthMeters {
                return elevation + max(d - start, 0) * s.gradePercent / 100
            }
            start += s.lengthMeters
            elevation += s.lengthMeters * s.gradePercent / 100
        }
        return elevation
    }
}

extension Route {
    public static let flat = Route(id: "llano", name: "Llano (10 km, circular)", isLoop: true, segments: [
        RouteSegment(10_000, 0),
    ])

    public static let rolling = Route(id: "ondulado", name: "Ondulado (12 km, circular)", isLoop: true, segments: [
        RouteSegment(1_000, 0), RouteSegment(800, 3), RouteSegment(600, -2), RouteSegment(1_200, 1),
        RouteSegment(500, 5), RouteSegment(700, -4), RouteSegment(1_500, 0), RouteSegment(900, 2),
        RouteSegment(1_000, -1.5), RouteSegment(800, 4), RouteSegment(1_200, -3), RouteSegment(2_000, -1),
    ])

    public static let climb = Route(id: "puerto", name: "Puerto (8 km al 6 %)", isLoop: false, segments: [
        RouteSegment(1_000, 0), RouteSegment(2_000, 5), RouteSegment(2_000, 6),
        RouteSegment(2_000, 7), RouteSegment(2_000, 6), RouteSegment(1_000, 0),
    ])

    public static let builtIn: [Route] = [.flat, .rolling, .climb]
}
