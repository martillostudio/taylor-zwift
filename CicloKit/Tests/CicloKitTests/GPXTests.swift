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
}
