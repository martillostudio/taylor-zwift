import Foundation
import Testing
@testable import CicloKit

@Suite struct PlanAdvisorTests {
    let plan = TrainingPlan.winter
    let now = Date()

    private func statuses(_ week: PlanWeek, _ values: [PlanSessionStatus]) -> [String: PlanSessionStatus] {
        Dictionary(uniqueKeysWithValues: zip(week.sessions.map(\.id), values))
    }

    @Test func skippedSweetSpotMovesToFreeDay() throws {
        let week = plan.weeks[4] // Mar ss-2x20 · Jue z2-fuerza-75 · Sáb z2-120
        let st = statuses(week, [.skipped, .upcoming, .upcoming])
        let p = PlanAdvisor.proposals(week: week, statuses: st, todayOffset: 2, freshness: 0,
                                      outcomes: [], categoryIntensity: [:], now: now)
        let move = try #require(p.first)
        guard case .move(let key, let day) = move.change else { Issue.record("no es un cambio de día"); return }
        #expect(key == "s5-Mar-ss-2x20")
        #expect(["Mié", "Vie", "Dom"].contains(day))
        // Aplicado, la sesión queda ese día y deja de estar saltada.
        let moved = plan.moving([key: day])
        let s = try #require(moved.weeks[4].sessions.first { $0.workoutID == "ss-2x20" })
        #expect(s.day == day)
        #expect(s.originalKey == key)
    }

    @Test func skippedEasySessionIsNotMoved() {
        let week = plan.weeks[0] // Mar test · Jue z2-60 · Sáb z2-90
        let st = statuses(week, [.done(on: nil), .skipped, .upcoming])
        let p = PlanAdvisor.proposals(week: week, statuses: st, todayOffset: 4, freshness: 0,
                                      outcomes: [], categoryIntensity: [:], now: now)
        #expect(p.isEmpty)
    }

    @Test func tiredSwapsHardSessionForZ2() throws {
        let week = plan.weeks[5] // Mar ss-3x15 · Jue vo2-30-30 · Sáb z2-120
        let st = statuses(week, [.done(on: nil), .upcoming, .upcoming])
        let p = PlanAdvisor.proposals(week: week, statuses: st, todayOffset: 2, freshness: -24,
                                      outcomes: [], categoryIntensity: [:], now: now)
        let swap = try #require(p.first)
        #expect(swap.change == .swap(key: "s6-Jue-vo2-30-30", workoutID: "z2-60"))
        #expect(swap.title.contains("mañana"))
        // Aplicado: el plan cambia y el calendario también.
        let swapped = plan.replacing(["s6-Jue-vo2-30-30": "z2-60"])
        #expect(swapped.weeks[5].sessions[1].workoutID == "z2-60")
        // Y se puede mover después sin perder la clave original.
        let both = plan.replacing(["s6-Jue-vo2-30-30": "z2-60"]).moving(["s6-Jue-vo2-30-30": "Vie"])
        #expect(both.weeks[5].sessions[1].day == "Vie")
        #expect(both.weeks[5].sessions[1].workoutID == "z2-60")
    }

    @Test func veryTiredGoesToRecovery() {
        let week = plan.weeks[1] // Mar fuerza-5x5 · Jue z2-60 · Sáb z2-90
        let st = statuses(week, [.today, .upcoming, .upcoming])
        let p = PlanAdvisor.proposals(week: week, statuses: st, todayOffset: 1, freshness: -35,
                                      outcomes: [], categoryIntensity: [:], now: now)
        #expect(p.contains { $0.change == .swap(key: "s2-Mar-fuerza-5x5", workoutID: "recuperacion-30") })
        #expect(!p.contains { if case .swap(let k, _) = $0.change { k.contains("Sáb") } else { false } })
    }

    @Test func notTiredNoSwap() {
        let week = plan.weeks[5]
        let st = statuses(week, [.done(on: nil), .upcoming, .upcoming])
        let p = PlanAdvisor.proposals(week: week, statuses: st, todayOffset: 2, freshness: -10,
                                      outcomes: [], categoryIntensity: [:], now: now)
        #expect(p.isEmpty)
    }

    @Test func twoShortSessionsLowerCategory() throws {
        let outcomes = [
            WorkoutOutcome(date: now.addingTimeInterval(-7 * 86_400), category: .vo2max, compliance: 0.86, baseIntensity: 1, finalIntensity: 1),
            WorkoutOutcome(date: now.addingTimeInterval(-2 * 86_400), category: .vo2max, compliance: 0.88, baseIntensity: 1, finalIntensity: 1),
        ]
        let week = plan.weeks[0]
        let p = PlanAdvisor.proposals(week: week, statuses: [:], todayOffset: 0, freshness: nil,
                                      outcomes: outcomes, categoryIntensity: [:], now: now)
        let change = try #require(p.first?.change)
        #expect(change == .intensity(category: .vo2max, to: 0.95))
    }

    @Test func personalIntensityFromAdjustments() throws {
        let outcomes = [
            WorkoutOutcome(date: now.addingTimeInterval(-9 * 86_400), category: .sweetSpot, compliance: 0.99, baseIntensity: 1, finalIntensity: 0.96),
            WorkoutOutcome(date: now.addingTimeInterval(-2 * 86_400), category: .sweetSpot, compliance: 0.98, baseIntensity: 1, finalIntensity: 0.98),
        ]
        let p = PlanAdvisor.proposals(week: plan.weeks[0], statuses: [:], todayOffset: 0, freshness: nil,
                                      outcomes: outcomes, categoryIntensity: [:], now: now)
        #expect(p.first?.change == .intensity(category: .sweetSpot, to: 0.97))
        // Ya aplicada, no se vuelve a proponer.
        let again = PlanAdvisor.proposals(week: plan.weeks[0], statuses: [:], todayOffset: 0, freshness: nil,
                                          outcomes: outcomes, categoryIntensity: [.sweetSpot: 0.97], now: now)
        #expect(again.isEmpty)
    }

    @Test func mixedAdjustmentsDoNothing() {
        let outcomes = [
            WorkoutOutcome(date: now.addingTimeInterval(-9 * 86_400), category: .threshold, compliance: 1, baseIntensity: 1, finalIntensity: 0.96),
            WorkoutOutcome(date: now.addingTimeInterval(-2 * 86_400), category: .threshold, compliance: 1, baseIntensity: 1, finalIntensity: 1.04),
        ]
        let p = PlanAdvisor.proposals(week: plan.weeks[0], statuses: [:], todayOffset: 0, freshness: nil,
                                      outcomes: outcomes, categoryIntensity: [:], now: now)
        #expect(p.isEmpty)
    }

    @Test func baseIntensityScalesReviewTargets() {
        let w = Workout.library.first { $0.id == "ss-2x20" }!
        let samples = (0..<w.durationSeconds).map { t -> ReviewSample in
            let p = (w.segments.first { t >= $0.startSeconds && t < $0.endSeconds }!.power(at: Double(t)) ?? 0.6) * 185 * 0.95
            return ReviewSample(t: Double(t), power: Int(p.rounded()))
        }
        let r = WorkoutReview(workout: w, ftp: 185, samples: samples, baseIntensity: 0.95)
        #expect((r.compliance ?? 0) > 0.99)
    }
}
