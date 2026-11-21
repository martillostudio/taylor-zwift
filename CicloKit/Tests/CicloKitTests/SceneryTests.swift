import Foundation
import Testing
@testable import CicloKit

@Suite struct SceneryTests {
    private func date(month: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: 15))!
    }

    private func route(perKm: Double, km: Double = 20, start: Double? = nil, lat: Double = 41.4) -> Route {
        // Sube y baja: la mitad al +g %, la mitad al −g % (g = perKm / 10 para dar perKm m/km).
        let g = perKm / 10 * 2
        var r = Route(id: "t", name: "t", isLoop: false,
                      segments: [RouteSegment(km * 500, g), RouteSegment(km * 500, -g)],
                      track: RouteTrack(points: [GeoPoint(latitude: lat, longitude: 2), GeoPoint(latitude: lat + 0.01, longitude: 2)], distances: [0, 1112]))
        r.startAltitude = start
        return r
    }

    @Test func flatIsMeadowAndHillyIsForest() {
        #expect(Scenery.forRoute(route(perKm: 2), on: date(month: 6)) == .meadow)
        #expect(Scenery.forRoute(route(perKm: 8), on: date(month: 6)) == .rolling)
        #expect(Scenery.forRoute(route(perKm: 15), on: date(month: 6)) == .forest)
        #expect(Scenery.forRoute(route(perKm: 30), on: date(month: 6)) == .mountain)
    }

    @Test func altitudeAndSeason() {
        // Puerto de 1.200 m: montaña en verano, nieve en enero.
        let pass = route(perKm: 15, km: 20, start: 900)
        #expect(Scenery.forRoute(pass, on: date(month: 7)) == .mountain)
        #expect(Scenery.forRoute(pass, on: date(month: 1)) == .snow)
        // Collserola (≈ 500 m) en enero: bosque, no nieve.
        #expect(Scenery.forRoute(route(perKm: 15, start: 100), on: date(month: 1)) == .forest)
        // Muy al norte en invierno: nieve aunque sea llano.
        #expect(Scenery.forRoute(route(perKm: 2, lat: 63), on: date(month: 12)) == .snow)
    }
}
