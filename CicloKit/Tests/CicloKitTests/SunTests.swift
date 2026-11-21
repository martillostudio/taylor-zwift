import Foundation
import Testing
@testable import CicloKit

@Suite struct SunTests {
    let lat = 41.39, lon = 2.17 // Barcelona

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func summerNoonIsHigh() {
        // Mediodía solar en Barcelona ≈ 12:00 UTC − 9 min; en junio el sol sube a ~72°.
        let p = Sun.position(at: date("2026-06-21T11:51:00Z"), latitude: lat, longitude: lon)
        #expect(abs(p.elevation - 72) < 1.5)
    }

    @Test func winterNoonIsLow() {
        let p = Sun.position(at: date("2026-12-21T11:51:00Z"), latitude: lat, longitude: lon)
        #expect(abs(p.elevation - 25.2) < 1.5)
    }

    @Test func nightAndMorning() {
        let night = Sun.position(at: date("2026-11-21T23:00:00Z"), latitude: lat, longitude: lon)
        #expect(night.elevation < -30)
        // 21-nov: amanece en Barcelona hacia las 7:45 hora local (6:45 UTC).
        let sunrise = Sun.position(at: date("2026-11-21T06:45:00Z"), latitude: lat, longitude: lon)
        #expect(abs(sunrise.elevation) < 2)
        #expect(sunrise.isMorning)
        let sunset = Sun.position(at: date("2026-11-21T16:25:00Z"), latitude: lat, longitude: lon)
        #expect(abs(sunset.elevation) < 2.5)
        #expect(!sunset.isMorning)
    }
}
