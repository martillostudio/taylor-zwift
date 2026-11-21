import Foundation
import Testing
@testable import CicloKit

@Suite("Qué toca hoy y hacia dónde vamos")
struct CoachTests {
    let z2 = PlanSession("Jue", "z2-60")
    let sweetSpot = PlanSession("Mar", "ss-2x20")
    let ramp = PlanSession("Mar", "test-rampa")
    let outdoor = PlanSession("Sáb", nil, "Salida en exterior de 2,5–3 h en Z2.")

    @Test func duraSoloSiPasaDelSweetSpot() {
        #expect(Coach.isHard(sweetSpot.workout!))
        #expect(Coach.isHard(ramp.workout!))
        #expect(!Coach.isHard(z2.workout!))
    }

    @Test func freshAndHardSessionMeansPush() {
        let a = Coach.today(freshness: -5, rampPerWeek: 2, session: sweetSpot, doneToday: false)
        #expect(a.call == .push)
        #expect(a.reasons.first?.contains("Sweet spot") == true)
    }

    @Test func rampTestIsTestDay() {
        #expect(Coach.today(freshness: 8, rampPerWeek: nil, session: ramp, doneToday: false).headline == "Día de test")
    }

    @Test func tiredTurnsHardIntoEasy() {
        let a = Coach.today(freshness: -25, rampPerWeek: 4, session: sweetSpot, doneToday: false)
        #expect(a.call == .easy)
        #expect(a.reasons.contains { $0.contains("60' en Z2") })
    }

    @Test func veryTiredMeansRest() {
        #expect(Coach.today(freshness: -35, rampPerWeek: nil, session: z2, doneToday: false).call == .rest)
    }

    @Test func noSessionIsRestDayButFreshCanRide() {
        let a = Coach.today(freshness: 18, rampPerWeek: nil, session: nil, doneToday: false)
        #expect(a.call == .rest)
        #expect(a.reasons.count == 2)
    }

    @Test func doneIsDone() {
        #expect(Coach.today(freshness: -40, rampPerWeek: nil, session: z2, doneToday: true).headline == "Hecho por hoy")
    }

    @Test func alreadyLoadedTodayMovesTheSession() {
        let a = Coach.today(freshness: -16, rampPerWeek: 3, session: z2, doneToday: false, todayLoad: 173)
        #expect(a.call == .rest)
        #expect(a.reasons.contains { $0.contains("mañana") })
    }

    @Test func z2AndOutdoorAreSteady() {
        #expect(Coach.today(freshness: -12, rampPerWeek: nil, session: z2, doneToday: false).call == .steady)
        let o = Coach.today(freshness: nil, rampPerWeek: nil, session: outdoor, doneToday: false)
        #expect(o.call == .steady)
        #expect(o.reasons[0].contains("2,8 h") || o.reasons[0].contains("2,75") || o.reasons[0].contains("h en Z2"))
    }

    @Test func fastRampWarns() {
        let a = Coach.today(freshness: -15, rampPerWeek: 9, session: z2, doneToday: false, yesterdayLoad: 120)
        #expect(a.reasons.contains { $0.contains("rápido") })
        #expect(a.reasons.contains { $0.contains("Ayer cargaste 120") })
    }

    @Test func phasesGroupConsecutiveBlocks() {
        let p = TrainingPlan.winter.phases
        #expect(p.first?.name == "Base 1")
        #expect(p.first?.weeks == 1...3)
        #expect(p[1].isRecovery)
        #expect(p.map(\.weeks.count).reduce(0, +) == 16)
    }

    @Test func nextRecoveryAndTest() {
        let plan = TrainingPlan.winter
        #expect(plan.nextRecoveryWeek(from: 1)?.number == 4)
        #expect(plan.nextRecoveryWeek(from: 5)?.number == 8)
        #expect(plan.nextTest(from: 2)?.week.number == 8)
    }

    @Test func weeklyLoadsAddOutdoorEstimate() throws {
        let plan = TrainingPlan.winter
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let start = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 16)))
        let day = { (d: Int) in cal.date(byAdding: .day, value: d, to: start)! }
        let loads = [(date: day(1), load: 30.0), (date: day(5), load: 60.0), (date: day(8), load: 50.0)]
        let w = plan.weeklyLoads(start: start, loads: loads, upTo: 2, calendar: cal)
        #expect(w.count == 2)
        #expect(w[0].done == 90)
        #expect(w[1].done == 50)
        let week10 = plan.weeks[9]
        #expect(plan.plannedLoad(of: week10) > Double(week10.plannedTSS)) // la salida en exterior cuenta
    }

    @Test func rampPace() {
        #expect(RampPace(perWeek: -3) == .losing)
        #expect(RampPace(perWeek: 1) == .steady)
        #expect(RampPace(perWeek: 5) == .building)
        #expect(RampPace(perWeek: 10) == .aggressive)
    }

    @Test func rampFromFitnessDays() throws {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let days = (0...7).map { i in
            FitnessDay(date: cal.date(byAdding: .day, value: i - 7, to: today)!, fitness: 20 + Double(i), fatigue: 20)
        }
        #expect(days.rampPerWeek(on: today, calendar: cal) == 7)
    }

    @Test func efficiencyOnlyForAerobicRidesWithHeartRate() {
        let samples = (0..<2_400).map { ActivitySample(t: Double($0), power: 130, distance: Double($0) * 8, heartRate: 125) }
        let z2 = Activity(start: Date(), name: "Z2", kind: "Entreno", ftp: 184, samples: samples)
        #expect(abs((z2.efficiencyFactor ?? 0) - 1.04) < 0.01)
        let noHR = Activity(start: Date(), name: "Z2", kind: "Entreno", ftp: 184,
                            samples: samples.map { var s = $0; s.heartRate = nil; return s })
        #expect(noHR.efficiencyFactor == nil)
        let hard = Activity(start: Date(), name: "SS", kind: "Entreno", ftp: 150, samples: samples)
        #expect(hard.efficiencyFactor == nil)
    }
}

@Suite("Sesiones movidas y FTP automático")
struct PlanMovesTests {
    @Test func moveSaturdayToSunday() throws {
        let plan = TrainingPlan.winter
        let sat = try #require(plan.weeks[0].sessions.first { $0.workoutID == "z2-90" })
        let moved = plan.moving([sat.key(week: 1): "Dom"])
        let s = try #require(moved.weeks[0].sessions.first { $0.workoutID == "z2-90" })
        #expect(s.weekdayOffset == 6)
        #expect(moved.weeks[1] == plan.weeks[1])
        #expect(moved.weeks[0].sessions.map(\.weekdayOffset) == [1, 3, 6])
    }

    @Test func movedSessionCountsOnSunday() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let start = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 16)))
        let sunday = cal.date(byAdding: .day, value: 6, to: start)!.addingTimeInterval(10 * 3600)
        let plan = TrainingPlan.winter.moving(["s1-Sáb-z2-90": "Dom"])
        let week = plan.weeks[0]
        let s = try #require(week.sessions.first { $0.workoutID == "z2-90" })
        let st = plan.status(of: week, start: start, completed: [], now: sunday, calendar: cal)
        #expect(st[s.id] == .today)
        let events = plan.calendarEvents(start: start, calendar: cal)
        let e = try #require(events.first { $0.externalID.contains("z2-90") && $0.externalID.contains("-s1-") })
        #expect(cal.component(.weekday, from: e.date) == 1) // domingo
    }

    @Test func onlyMaximalTestsApplyThemselves() {
        #expect(FTPUpdate.testIsMaximal(maxHeartRate: 184, athleteMaxHeartRate: 185))
        #expect(!FTPUpdate.testIsMaximal(maxHeartRate: 150, athleteMaxHeartRate: 185))
        #expect(!FTPUpdate.testIsMaximal(maxHeartRate: nil, athleteMaxHeartRate: 185))
    }

    @Test func eftpOnlyRaises() {
        #expect(FTPUpdate.raise(current: 185, estimated: 181) == nil)
        #expect(FTPUpdate.raise(current: 185, estimated: 190) == 190)
        #expect(FTPUpdate.raise(current: 185, estimated: nil) == nil)
    }
}
