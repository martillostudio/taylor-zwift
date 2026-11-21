import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Lee rutas GPX (las que exportan Garmin Connect, Strava, Komoot, Wikiloc…) y las convierte
/// en una `Route` con la pendiente real.
///
/// La altura de un GPS baila mucho, así que: se remuestrea la traza cada 25 m, se suaviza la
/// altura con una media de 200 m y se trocea en tramos de 50 m con la pendiente limitada a ±20 %.
public enum GPXParser {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidXML(String)
        case tooFewPoints
        case noElevation

        public var errorDescription: String? {
            switch self {
            case .invalidXML(let m): "El fichero no es un GPX válido (\(m))."
            case .tooFewPoints: "La ruta es demasiado corta (hace falta al menos 1 km con puntos)."
            case .noElevation: "El GPX no trae altura. Expórtalo de nuevo con altitud (en Garmin Connect, desde «Recorridos»)."
            }
        }
    }

    public struct TrackPoint: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var elevation: Double?
    }

    static let resampleMeters = 25.0
    static let smoothingMeters = 200.0
    static let segmentMeters = 50.0
    static let maxGrade = 20.0

    public static func parse(_ data: Data, id: String, fallbackName: String = "Ruta importada") throws -> Route {
        let (name, points) = try readPoints(data)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try route(from: points, id: id, name: clean.isEmpty ? fallbackName : clean)
    }

    public static func readPoints(_ data: Data) throws -> (name: String, points: [TrackPoint]) {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw Error.invalidXML(parser.parserError?.localizedDescription ?? "XML no válido")
        }
        // Si hay track, ese; si no, la ruta (rtept).
        return (delegate.name, delegate.trackPoints.isEmpty ? delegate.routePoints : delegate.trackPoints)
    }

    /// Distancia en metros entre dos puntos (fórmula del semiverseno).
    public static func distance(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let r = 6_371_000.0
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = φ2 - φ1
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    public static func route(from points: [TrackPoint], id: String, name: String) throws -> Route {
        let withElevation = points.compactMap { p in p.elevation.map { (p, $0) } }
        guard withElevation.count >= 2 else {
            throw points.count >= 2 ? Error.noElevation : Error.tooFewPoints
        }

        // Distancia acumulada y altura en cada punto.
        var dist: [Double] = [0]
        var ele: [Double] = [withElevation[0].1]
        for i in 1..<withElevation.count {
            let d = distance(withElevation[i - 1].0, withElevation[i].0)
            guard d > 0.5 else { continue } // puntos repetidos
            dist.append(dist[dist.count - 1] + d)
            ele.append(withElevation[i].1)
        }
        let total = dist[dist.count - 1]
        guard total >= 1_000 else { throw Error.tooFewPoints }

        // Remuestreo cada 25 m (interpolación lineal).
        let step = resampleMeters
        let n = Int(total / step) + 1
        var grid = [Double](repeating: 0, count: n)
        var j = 0
        for k in 0..<n {
            let d = Double(k) * step
            while j < dist.count - 2 && dist[j + 1] < d { j += 1 }
            let span = dist[j + 1] - dist[j]
            let t = span > 0 ? min(max((d - dist[j]) / span, 0), 1) : 0
            grid[k] = ele[j] + (ele[j + 1] - ele[j]) * t
        }

        // Media móvil centrada de ~200 m.
        let half = Int(smoothingMeters / step / 2)
        var smooth = grid
        for k in 0..<n {
            let a = max(0, k - half), b = min(n - 1, k + half)
            smooth[k] = grid[a...b].reduce(0, +) / Double(b - a + 1)
        }

        // Tramos de 50 m.
        let per = Int(segmentMeters / step)
        var segments: [RouteSegment] = []
        var k = 0
        while k < n - 1 {
            let e = min(k + per, n - 1)
            let length = Double(e - k) * step
            let g = (smooth[e] - smooth[k]) / length * 100
            segments.append(RouteSegment(length, min(max(g, -maxGrade), maxGrade)))
            k = e
        }
        return Route(id: id, name: name, isLoop: false, segments: segments)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var name = ""
        var trackPoints: [TrackPoint] = []
        var routePoints: [TrackPoint] = []
        private var current: TrackPoint?
        private var isTrack = false
        private var text = ""
        private var depthInPoint = false
        private var nameLocked = false

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            let tag = element.lowercased()
            if tag == "trkpt" || tag == "rtept" {
                if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
                    current = TrackPoint(latitude: lat, longitude: lon, elevation: nil)
                    isTrack = tag == "trkpt"
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let tag = element.lowercased()
            switch tag {
            case "ele":
                current?.elevation = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "trkpt", "rtept":
                if let p = current {
                    if isTrack { trackPoints.append(p) } else { routePoints.append(p) }
                }
                current = nil
            case "name":
                // El primer nombre de la ruta o del track (no el de los waypoints sueltos).
                if !nameLocked, current == nil {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { name = t; nameLocked = true }
                }
            default:
                break
            }
            text = ""
        }
    }
}
