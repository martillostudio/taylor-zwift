import Testing
@testable import CicloKit

@Suite struct DemoRiderTests {
    private func ride(_ rider: inout DemoRider, _ target: TrainerTarget?, seconds: Int) {
        for _ in 0..<(seconds * 2) { rider.step(target: target, dt: 0.5) }
    }

    @Test func ergFollowsTarget() {
        var r = DemoRider(ftp: 185)
        ride(&r, .targetPower(watts: 150), seconds: 20)
        #expect(abs(r.powerWatts - 150) < 6)
        #expect(r.cadenceRpm > 84 && r.cadenceRpm < 92)
        let d = r.bikeData
        #expect(abs((d.speedKmh ?? 0) - (d.cadenceRpm ?? 0) * 0.356) < 0.1)
    }

    @Test func harderGearLowersCadenceInSim() {
        let gears = VirtualGears()
        let easy = VirtualGears(index: 3)
        let hard = VirtualGears(index: gears.count - 1)
        var a = DemoRider(ftp: 185), b = DemoRider(ftp: 185)
        ride(&a, .simulation(easy.simulation(gradePercent: 2)), seconds: 30)
        ride(&b, .simulation(hard.simulation(gradePercent: 2)), seconds: 30)
        #expect(b.cadenceRpm < a.cadenceRpm)
    }

    @Test func pushesMoreUphill() {
        let r = DemoRider(ftp: 200, effort: 0.6)
        #expect(r.simPower(gradePercent: 6) > r.simPower(gradePercent: 0))
        #expect(r.simPower(gradePercent: -10) >= 50)
    }

    @Test func heartRateLagsAndRises() {
        var r = DemoRider(ftp: 185)
        ride(&r, .targetPower(watts: 120), seconds: 5)
        let early = r.heartRate
        ride(&r, .targetPower(watts: 120), seconds: 300)
        #expect(r.heartRate > early + 30)
        #expect(r.heartRate > 110 && r.heartRate < 140)
    }

    @Test func rampTestEndsAroundThirtyPercentAboveFTP() {
        var r = DemoRider(ftp: 185)
        var watts = 100.0
        var failedAt: Double?
        for _ in 0..<(30 * 60 * 2) {
            r.step(target: .targetPower(watts: Int(watts)), dt: 0.5)
            if r.exhaustedSeconds > 0 { failedAt = watts; break }
            watts += 20.0 / 120 // +20 W por minuto
        }
        let f = try! #require(failedAt)
        #expect(f > 185 * 1.15 && f < 185 * 1.5)
    }

    @Test func recoversAfterExhaustion() {
        var r = DemoRider(ftp: 185)
        ride(&r, .targetPower(watts: 400), seconds: 120)
        ride(&r, .targetPower(watts: 100), seconds: 30)
        #expect(r.exhaustedSeconds == 0)
        #expect(r.powerWatts > 80)
    }
}
