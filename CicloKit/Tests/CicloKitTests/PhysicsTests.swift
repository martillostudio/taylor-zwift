import Testing
@testable import CicloKit

@Suite struct PhysicsTests {
    let rider = RiderPhysics(riderKg: 72)

    @Test func flatSpeedIsRealistic() {
        let v = rider.speed(powerWatts: 200, gradePercent: 0)
        #expect(v > 30 && v < 35)
    }

    @Test func climbIsSlow() {
        let v = rider.speed(powerWatts: 250, gradePercent: 8)
        #expect(v > 10 && v < 14)
    }

    @Test func gradeRoundTrip() {
        let p = rider.power(speedKmh: 18, gradePercent: 5)
        let g = rider.grade(powerWatts: p, speedKmh: 18)
        #expect(g != nil)
        #expect(abs((g ?? 0) - 5) < 0.01)
    }

    @Test func gradeNeedsSpeed() {
        #expect(rider.grade(powerWatts: 200, speedKmh: 2) == nil)
    }

    @Test func gradeIsClamped() {
        #expect(rider.grade(powerWatts: 2000, speedKmh: 8) == 25)
        #expect(rider.grade(powerWatts: 0, speedKmh: 100) == -15)
    }
}
