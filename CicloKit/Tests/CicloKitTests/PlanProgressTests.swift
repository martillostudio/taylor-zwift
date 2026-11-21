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
