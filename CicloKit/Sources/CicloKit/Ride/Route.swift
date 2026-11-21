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

/// Un punto en el mapa.
public struct GeoPoint: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// El recorrido de una ruta en el mapa (solo las importadas de GPX), con la distancia
/// acumulada en cada punto para saber dónde estás.
public struct RouteTrack: Hashable, Sendable {
    public let points: [GeoPoint]
    /// Metros desde la salida en cada punto (el primero, 0).
    public let distances: [Double]

    public init(points: [GeoPoint], distances: [Double]) {
        precondition(points.count == distances.count && points.count >= 2)
        self.points = points
        self.distances = distances
    }

    public var lengthMeters: Double { distances[distances.count - 1] }

    /// Punto a `d` metros de la salida (interpolado entre los dos más cercanos).
    public func point(atDistance d: Double) -> GeoPoint {
        let x = min(max(d, 0), lengthMeters)
        var lo = 0, hi = distances.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if distances[mid] <= x { lo = mid } else { hi = mid }
        }
        let span = distances[hi] - distances[lo]
        let t = span > 0 ? (x - distances[lo]) / span : 0
        let a = points[lo], b = points[hi]
        return GeoPoint(latitude: a.latitude + (b.latitude - a.latitude) * t,
                        longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Los puntos hasta `d` metros (lo ya recorrido), terminando justo donde estás.
    public func points(upTo d: Double) -> [GeoPoint] {
        guard d > 0 else { return [points[0]] }
        let n = distances.firstIndex { $0 > d } ?? points.count
        return Array(points.prefix(n)) + [point(atDistance: d)]
    }

    // Comparar y «hashear» miles de puntos en cada repintado sale caro: basta con lo esencial.
    public static func == (a: RouteTrack, b: RouteTrack) -> Bool {
        a.points.count == b.points.count && a.lengthMeters == b.lengthMeters
            && a.points.first == b.points.first && a.points.last == b.points.last
    }

    public func hash(into h: inout Hasher) {
        h.combine(points.count)
        h.combine(lengthMeters)
    }
}

/// Ruta sencilla: una lista de tramos con pendiente. Puede ser circular (se repite).
public struct Route: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var segments: [RouteSegment]
    /// Si es circular, al acabar se vuelve a empezar; si no, después del final es llano.
    public var isLoop: Bool
    /// Recorrido en el mapa (rutas GPX); `nil` en las rutas inventadas.
    public var track: RouteTrack?

    /// Distancia sobre la que se suaviza un cambio de pendiente (para que no dé tirones).
    public static let smoothingMeters = 50.0

    public init(id: String, name: String, isLoop: Bool, segments: [RouteSegment], track: RouteTrack? = nil) {
        precondition(!segments.isEmpty)
        self.id = id
        self.name = name
        self.isLoop = isLoop
        self.segments = segments
        self.track = track
    }

    /// Dónde estás en el mapa tras `d` metros (escalado por si el perfil y la traza difieren
    /// un poco en longitud). `nil` si la ruta no tiene mapa.
    public func mapPosition(atDistance d: Double) -> (point: GeoPoint, trackMeters: Double)? {
        guard let track else { return nil }
        let meters = positionInLap(d) / lengthMeters * track.lengthMeters
        return (track.point(atDistance: meters), meters)
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
            let lapGain = elevationInLap(length)
            return laps * lapGain + elevationInLap(d - laps * length)
        }
        if d <= 0 { return d * segments[0].gradePercent / 100 }
        if d >= length { return elevationInLap(length) } // después del final: llano
        return elevationInLap(d)
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
            return RoutePoint(distanceMeters: d, elevationMeters: elevationInLap(d))
        }
    }

    /// Altura dentro de una vuelta (`d` entre 0 y la longitud).
    func elevationInLap(_ d: Double) -> Double {
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

    /// Dos subidas cortas: una sin categoría (1,5 km al 5 %) y una de 4.ª (2 km al 7 %).
    public static let punchy = Route(id: "rompepiernas", name: "Rompepiernas (12,8 km, circular)", isLoop: true, segments: [
        RouteSegment(1_000, 0), RouteSegment(1_500, 5), RouteSegment(1_000, -4), RouteSegment(1_000, 0),
        RouteSegment(2_000, 7), RouteSegment(2_000, -6), RouteSegment(1_500, 0), RouteSegment(2_750, -2),
    ])

    public static let builtIn: [Route] = [.flat, .rolling, .punchy, .climb]
}
