import Foundation
import Testing
@testable import CicloKit

@Suite struct GPXTests {
    /// Recta hacia el norte: `n` puntos cada ~11 m (0,0001° de latitud) con la altura dada.
    func gpx(name: String = "Mi subida", points n: Int, elevation: (Int) -> Double?) -> Data {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(name)</name></metadata>
          <trk><name>\(name)</name><trkseg>
        """
        for i in 0..<n {
            let lat = 41.0 + Double(i) * 0.0001
            if let e = elevation(i) {
                s += "<trkpt lat=\"\(lat)\" lon=\"2.0\"><ele>\(e)</ele></trkpt>\n"
            } else {
                s += "<trkpt lat=\"\(lat)\" lon=\"2.0\"></trkpt>\n"
            }
        }
        s += "</trkseg></trk></gpx>"
        return Data(s.utf8)
    }

    @Test func distanceIsRight() {
        let a = GPXParser.TrackPoint(latitude: 41, longitude: 2, elevation: nil)
        let b = GPXParser.TrackPoint(latitude: 41.01, longitude: 2, elevation: nil)
        #expect(abs(GPXParser.distance(a, b) - 1_112) < 5)
    }

    @Test func steadyClimbKeepsItsGrade() throws {
        // ~3,3 km subiendo 0,667 m cada 11,1 m ≈ 6 %.
        let step = GPXParser.distance(.init(latitude: 41, longitude: 2, elevation: nil),
                                      .init(latitude: 41.0001, longitude: 2, elevation: nil))
        let r = try GPXParser.parse(gpx(points: 300) { Double($0) * step * 0.06 }, id: "t")
        #expect(r.name == "Mi subida")
        #expect(abs(r.lengthMeters - 299 * step) < 30)
        #expect(abs(r.grade(atDistance: 1_500) - 6) < 0.3)
        #expect(abs(r.climbMeters - 299 * step * 0.06) < 10)
    }

    @Test func noisyElevationIsSmoothedAndClamped() throws {
        // Llano con saltos de ±8 m cada punto (ruido típico de GPS): la pendiente no se dispara.
        let r = try GPXParser.parse(gpx(points: 300) { $0 % 2 == 0 ? 100 : 108 }, id: "t")
        for d in stride(from: 200.0, to: 3_000, by: 100) {
            #expect(abs(r.grade(atDistance: d)) < 3)
        }
        #expect(r.segments.allSatisfy { abs($0.gradePercent) <= GPXParser.maxGrade })
    }

    @Test func missingElevationFails() {
        #expect(throws: GPXParser.Error.noElevation) {
            try GPXParser.parse(gpx(points: 300) { _ in nil }, id: "t")
        }
    }

    @Test func tooShortFails() {
        #expect(throws: GPXParser.Error.tooFewPoints) {
            try GPXParser.parse(gpx(points: 20) { Double($0) }, id: "t")
        }
    }

    @Test func trackForTheMap() throws {
        let r = try GPXParser.parse(gpx(points: 300) { _ in 100 }, id: "t")
        let track = try #require(r.track)
        #expect(abs(track.lengthMeters - r.lengthMeters) < 30)
        #expect(track.points.count < 300) // reducido a un punto cada ~20 m
        #expect(track.points.first == GeoPoint(latitude: 41.0, longitude: 2.0))
        // A mitad de ruta, a mitad de latitud.
        let mid = try #require(r.mapPosition(atDistance: r.lengthMeters / 2))
        #expect(abs(mid.point.latitude - (41.0 + 299 * 0.0001 / 2)) < 0.0002)
        // Después del final, en el último punto.
        let end = try #require(r.mapPosition(atDistance: r.lengthMeters + 500))
        #expect(abs(end.point.latitude - track.points.last!.latitude) < 1e-9)
        // Lo recorrido acaba donde estás.
        let done = track.points(upTo: 1_000)
        #expect(done.last == track.point(atDistance: 1_000))
        #expect(track.points(upTo: 0).count == 1)
    }

    @Test func builtInRoutesHaveNoMap() {
        #expect(Route.rolling.track == nil)
        #expect(Route.rolling.mapPosition(atDistance: 100) == nil)
    }

    @Test func readsDate() throws {
        let base = String(decoding: gpx(points: 200) { _ in 50 }, as: UTF8.self)
        let withMeta = base.replacingOccurrences(of: "<metadata>", with: "<metadata><time>2026-09-27T08:15:00Z</time>")
        let r = try GPXParser.parse(Data(withMeta.utf8), id: "t")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(r.date.map { cal.component(.year, from: $0) } == 2026)
        #expect(r.date.map { cal.component(.month, from: $0) } == 9)
        // Con milisegundos, en el primer punto.
        let inPoint = base.replacingOccurrences(of: "<ele>50.0</ele></trkpt>", with: "<ele>50.0</ele><time>2025-05-01T10:00:00.000Z</time></trkpt>")
        #expect(try GPXParser.parse(Data(inPoint.utf8), id: "t").date.map { cal.component(.year, from: $0) } == 2025)
        // Sin fecha.
        #expect(try GPXParser.parse(Data(base.utf8), id: "t").date == nil)
    }

    @Test func climbPerKm() {
        #expect(abs(Route.climb.climbPerKm - 48) < 0.5) // 480 m en 10 km
    }
}

@Suite struct RouteElevationTableTests {
    @Test func matchesRouteEverywhere() {
        for route in Route.builtIn {
            let table = RouteElevationTable(route)
            var d = -300.0
            while d < route.lengthMeters * 2.3 {
                #expect(abs(table.elevation(atDistance: d) - route.elevation(atDistance: d)) < 1e-6)
                #expect(abs(table.grade(atDistance: d) - route.grade(atDistance: d)) < 0.11)
                d += 7.3
            }
        }
    }
}
