import Testing
@testable import CicloKit

@Suite struct WorkoutReviewTests {
    let ftp = 185

    private func workout(_ id: String) -> Workout {
        Workout.library.first { $0.id == id }!
    }

    /// Una muestra por segundo siguiendo el objetivo × `scale`, con pulso y cadencia dados.
    private func samples(_ w: Workout, upTo seconds: Int? = nil, scale: (Int) -> Double = { _ in 1 },
                         heartRate: (Int) -> Int = { _ in 130 }, cadence: (WorkoutSegment) -> Int = { $0.cadence ?? 88 }) -> [ReviewSample] {
        (0..<(seconds ?? w.durationSeconds)).map { t in
            let seg = w.segments.first { t >= $0.startSeconds && t < $0.endSeconds }!
            let p = (seg.power(at: Double(t)) ?? 0.6) * Double(ftp) * scale(t)
            return ReviewSample(t: Double(t), power: Int(p.rounded()), heartRate: heartRate(t), cadence: cadence(seg))
        }
    }

    @Test func sweetSpotDoneAsPlanned() {
        let w = workout("ss-2x20")
        let r = WorkoutReview(workout: w, ftp: ftp, samples: samples(w))
        #expect(r.intervals.count == 2)
        #expect(r.intervals.allSatisfy { abs($0.averageWatts - 167) <= 1 })
        #expect((r.compliance ?? 0) > 0.99)
        #expect(r.notes.first?.tone == .good)
        #expect(r.nextTime.contains("2–3 %"))
    }

    @Test func fadingSecondIntervalIsFlagged() {
        let w = workout("ss-2x20")
        let secondStart = w.segments.filter { ($0.startPower ?? 0) >= 0.85 }[1].startSeconds
        let r = WorkoutReview(workout: w, ftp: ftp, samples: samples(w, scale: { $0 >= secondStart ? 0.8 : 1 }))
        #expect((r.compliance ?? 1) < 0.92)
        #expect(r.notes.contains { $0.text.contains("nº 2") && $0.tone == .warning })
        #expect(r.nextTime.contains("5 %"))
    }

    @Test func oneShortIntervalKeepsIntensity() {
        let w = workout("vo2-4x4")
        let work = w.segments.filter { ($0.startPower ?? 0) >= 0.85 }
        let third = work[2]
        let r = WorkoutReview(workout: w, ftp: ftp, samples: samples(w, scale: {
            $0 >= third.startSeconds && $0 < third.endSeconds ? 0.91 : 1
        }))
        #expect((r.compliance ?? 0) >= 0.97)
        #expect(r.notes.contains { $0.text.contains("nº 3") })
        #expect(r.nextTime.contains("Misma intensidad"))
    }

    @Test func unfinishedWorkout() {
        let w = workout("ss-2x20")
        let r = WorkoutReview(workout: w, ftp: ftp, samples: samples(w, upTo: 1_500))
        #expect(r.intervals.isEmpty) // el primero aún no llegaba al 80 %
        #expect(r.nextTime.contains("No lo terminaste"))
    }

    @Test func strengthCadenceTooHigh() {
        let w = workout("fuerza-5x5")
        let r = WorkoutReview(workout: w, ftp: ftp, samples: samples(w, cadence: { $0.cadence.map { $0 + 15 } ?? 90 }))
        #expect(r.intervals.count == 5)
        #expect(r.notes.contains { $0.text.contains("marcha más dura") })
    }

    @Test func enduranceDecoupling() {
        let w = workout("z2-60")
        let stable = WorkoutReview(workout: w, ftp: ftp, samples: samples(w, heartRate: { _ in 125 }), heartRateCap: 130)
        #expect(abs(stable.decouplingPercent ?? 99) < 1)
        #expect(stable.notes.contains { $0.tone == .good && $0.text.contains("Desacople") })

        // El pulso sube de 120 a 140 a vatios constantes: ~8 % de desacople y zona gris al final.
        let drifting = WorkoutReview(workout: w, ftp: ftp,
                                     samples: samples(w, heartRate: { 120 + $0 * 20 / 3_600 }), heartRateCap: 130)
        #expect((drifting.decouplingPercent ?? 0) > 5)
        #expect((drifting.secondsAboveCap ?? 0) > 600)
        #expect(drifting.nextTime.contains("más suave"))
    }

    @Test func testsHaveNoIntervals() {
        let w = workout("test-rampa")
        let r = WorkoutReview(workout: w, ftp: ftp, samples: samples(w, upTo: 1_200))
        #expect(r.intervals.isEmpty)
        #expect(r.nextTime.contains("Tras un test"))
    }
}
