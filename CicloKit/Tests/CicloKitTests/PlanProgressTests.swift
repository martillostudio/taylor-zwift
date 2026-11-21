import Foundation
import Testing
@testable import CicloKit

@Suite struct PlanProgressTests {
    let plan = TrainingPlan.winter
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }
    var monday: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 23))! }
    func day(_ d: Int, hour: Int = 19) -> Date {
        cal.date(byAdding: .hour, value: (d - 23) * 24 + hour, to: monday)!
    }

    @Test func weekdayOffsets() {
        #expect(PlanSession("Mar", nil).weekdayOffset == 1)
        #expect(PlanSession("Jue", nil).weekdayOffset == 3)
        #expect(PlanSession("Sáb", nil).weekdayOffset == 5)
        #expect(PlanSession("Dom", nil).weekdayOffset == 6)
    }

    @Test func workoutDoneOnAnotherDayCounts() {
        let week = plan.weeks[0] // Mar test-rampa · Jue z2-60 · Sáb z2-90
        let done = [CompletedWorkout(start: day(25), workoutID: "test-rampa", seconds: 1_100)]
        let s = plan.status(of: week, start: monday, completed: done, now: day(25), calendar: cal)
        #expect(s[week.sessions[0].id]?.isDone == true)
        #expect(s[week.sessions[1].id] == .upcoming)
    }

    @Test func shortWorkoutIsPartial() {
        let week = plan.weeks[0]
        let done = [CompletedWorkout(start: day(26), workoutID: "z2-60", seconds: 1_800)]
        let s = plan.status(of: week, start: monday, completed: done, now: day(26), calendar: cal)
        if case .partial(let f, _) = s[week.sessions[1].id] {
            #expect(abs(f - 0.5) < 0.01)
        } else {
            Issue.record("esperaba parcial")
        }
    }

    @Test func pastSessionIsSkippedAndTodayIsToday() {
        let week = plan.weeks[0]
        let s = plan.status(of: week, start: monday, completed: [], now: day(26), calendar: cal)
        #expect(s[week.sessions[0].id] == .skipped)
        #expect(s[week.sessions[1].id] == .today)
        #expect(plan.nextSession(in: week, statuses: s)?.workoutID == "z2-60")
    }

    @Test func otherWeeksDoNotCount() {
        let week = plan.weeks[0]
        let done = [CompletedWorkout(start: day(19), workoutID: "test-rampa", seconds: 1_100)]
        let s = plan.status(of: week, start: monday, completed: done, now: day(24), calendar: cal)
        #expect(s[week.sessions[0].id] == .today)
    }

    @Test func manualMark() {
        let week = plan.weeks[1]
        let key = week.sessions[2].key(week: 2)
        let s = plan.status(of: week, start: monday, completed: [], manuallyDone: [key], now: day(30), calendar: cal)
        #expect(s[week.sessions[2].id] == .done(on: nil))
    }

    @Test func oneWorkoutCountsOnce() {
        let week = plan.weeks[3] // Descarga: z2-60, recuperacion-30, z2-90
        let done = [CompletedWorkout(start: day(15 + 23), workoutID: "z2-60", seconds: 3_600)]
        let s = plan.status(of: week, start: monday, completed: done, now: day(14 + 23), calendar: cal)
        #expect(s.values.filter(\.isDone).count <= 1)
    }
}

@Suite struct OutdoorPlanTests {
    let plan = TrainingPlan.winter
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }
    var monday: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 23))! }
    /// Semana 10: Mar over-unders · Jue fuerza-4x8 · Sáb salida en exterior.
    var week: PlanWeek { plan.weeks[9] }
    func inWeek(day: Int, hour: Int = 10) -> Date {
        cal.date(byAdding: .hour, value: (63 + day) * 24 + hour, to: monday)!
    }

    @Test func longOutdoorRideCounts() {
        let ride = CompletedWorkout(start: inWeek(day: 6), workoutID: nil, seconds: 3 * 3600, isOutdoor: true)
        let s = plan.status(of: week, start: monday, completed: [ride], now: inWeek(day: 6, hour: 20), calendar: cal)
        #expect(s[week.sessions[2].id]?.isDone == true)
        #expect(s[week.sessions[0].id] == .skipped)
    }

    @Test func shortOutdoorRideIsPartial() {
        let ride = CompletedWorkout(start: inWeek(day: 5), workoutID: nil, seconds: 45 * 60, isOutdoor: true)
        let s = plan.status(of: week, start: monday, completed: [ride], now: inWeek(day: 5, hour: 20), calendar: cal)
        if case .partial(let f, _) = s[week.sessions[2].id] {
            #expect(abs(f - 0.5) < 0.01)
        } else {
            Issue.record("esperaba parcial")
        }
    }

    @Test func outdoorRideDoesNotCountForIndoorWorkouts() {
        let ride = CompletedWorkout(start: inWeek(day: 1), workoutID: nil, seconds: 3 * 3600, isOutdoor: true)
        let s = plan.status(of: week, start: monday, completed: [ride], now: inWeek(day: 1, hour: 20), calendar: cal)
        #expect(s[week.sessions[0].id]?.isDone == false)
        #expect(s[week.sessions[2].id]?.isDone == true) // cuenta para la salida del sábado
    }

    @Test func indoorAlternativeCounts() {
        let ride = CompletedWorkout(start: inWeek(day: 5), workoutID: "z2-120", seconds: 7200)
        let s = plan.status(of: week, start: monday, completed: [ride], now: inWeek(day: 5, hour: 20), calendar: cal)
        #expect(s[week.sessions[2].id]?.isDone == true)
    }
}

@Suite struct IntervalsActivityTests {
    let json = """
    [
      {"id": "i1001", "name": "Vuelta por la sierra", "start_date_local": "2026-12-05T09:30:00",
       "type": "Ride", "moving_time": 10800, "trainer": false, "icu_training_load": 160, "icu_rolling_ftp": 178.4},
      {"id": "i1002", "name": "Sweet spot", "start_date_local": "2026-12-03T19:00:00",
       "type": "VirtualRide", "moving_time": 3600, "trainer": true, "external_id": "taylorzwift-ABC"},
      {"id": "i1003", "start_date_local": "2026-12-04T08:00:00", "type": "Run", "moving_time": 2400},
      {"id": "i1004", "type": "Ride"},
      {"id": 1005, "start_date_local": "2026-11-28T10:00:00", "type": "GravelRide", "moving_time": 7200,
       "icu_rolling_ftp": 171}
    ]
    """

    var madrid: TimeZone { TimeZone(identifier: "Europe/Madrid")! }

    @Test func parsesAndFilters() {
        let list = IntervalsActivity.parseList(Data(json.utf8), timeZone: madrid)
        #expect(list.count == 4) // la que no tiene fecha se descarta
        #expect(list.filter(\.isOutdoorRide).map(\.id) == ["i1001", "1005"])
        #expect(list[1].isOurs)
        #expect(list[0].movingSeconds == 10_800)
        #expect(list[0].load == 160)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = madrid
        #expect(cal.component(.hour, from: list[0].start) == 9)
    }

    @Test func latestEFTP() {
        let list = IntervalsActivity.parseList(Data(json.utf8), timeZone: madrid)
        #expect(IntervalsActivity.latestEstimatedFTP(in: list) == 180)
        #expect(IntervalsActivity.latestEstimatedFTP(in: []) == nil)
    }

    @Test func garbageIsEmpty() {
        #expect(IntervalsActivity.parseList(Data(#"{"error": 1}"#.utf8)).isEmpty)
    }
}
