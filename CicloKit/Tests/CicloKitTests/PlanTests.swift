import Foundation
import Testing
@testable import CicloKit

@Suite("Plan de entrenamiento")
struct PlanTests {
    @Test func todasLasSesionesApuntanAEntrenosQueExisten() {
        for week in TrainingPlan.winter.weeks {
            for s in week.sessions where s.workoutID != nil {
                #expect(s.workout != nil, "semana \(week.number): \(s.workoutID ?? "")")
            }
            #expect(week.sessions.count == 3)
        }
        #expect(TrainingPlan.winter.weeks.map(\.number) == Array(1...16))
    }

    @Test func descargasCadaCuatroSemanas() {
        let recovery = TrainingPlan.winter.weeks.filter(\.isRecovery).map(\.number)
        #expect(recovery == [4, 8, 12, 16])
        // Las descargas tienen menos carga que la semana anterior (sin contar los tests de FTP,
        // cuyo TSS previsto no es real: se paran cuando no puedes más).
        let weeks = TrainingPlan.winter.weeks
        func load(_ w: PlanWeek) -> Double {
            w.sessions.compactMap(\.workout).filter { $0.ftpTest == nil }.reduce(0) { $0 + $1.tss }
        }
        for n in [4, 8, 12] {
            #expect(load(weeks[n - 1]) < load(weeks[n - 2]), "semana \(n)")
        }
    }

    @Test func semanaQueToca() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let thursday = cal.date(from: DateComponents(year: 2026, month: 11, day: 19))!
        let monday = TrainingPlan.monday(onOrAfter: thursday, calendar: cal)
        #expect(cal.component(.day, from: monday) == 23)
        #expect(cal.component(.month, from: monday) == 11)
        #expect(TrainingPlan.monday(onOrAfter: monday, calendar: cal) == monday)

        let plan = TrainingPlan.winter
        #expect(plan.weekNumber(on: thursday, start: monday, calendar: cal) == nil) // aún no ha empezado
        #expect(plan.weekNumber(on: monday, start: monday, calendar: cal) == 1)
        let day10 = cal.date(byAdding: .day, value: 10, to: monday)!
        #expect(plan.weekNumber(on: day10, start: monday, calendar: cal) == 2)
        let after = cal.date(byAdding: .day, value: 16 * 7, to: monday)!
        #expect(plan.weekNumber(on: after, start: monday, calendar: cal) == nil) // ya terminó
    }
}

@Suite("Fuerza y pulso")
struct StrengthAndHeartTests {
    @Test func cadenciaEnLosTramosDeFuerza() throws {
        let w = try #require(Workout.library.first { $0.id == "fuerza-5x5" })
        #expect(w.hasCadenceTargets)
        let on = w.segments.filter { $0.cadence == 55 }
        #expect(on.count == 5)
        #expect(on.allSatisfy { $0.startPower == 0.85 })
        #expect(on[0].summary == "5' al 85 % a 55 rpm")
        #expect(w.category == .strength)
    }

    @Test func lemas() {
        #expect(Workout.library.allSatisfy { $0.tagline != nil })
        let w = Workout(id: "x", name: "x", category: .imported, summary: "Primera frase. Segunda.", steps: [.steady(seconds: 60, power: 0.5)])
        #expect(w.shortDescription == "Primera frase")
    }

    @Test func tiempoPorZona() throws {
        let w = try #require(Workout.library.first { $0.id == "ss-2x20" })
        #expect(w.secondsByZone[.z3] == 2_400) // 2×20' al 90 %
    }

    @Test func zonasDePulso() {
        // FC máx 185: Z2 = 111–129, Z3 = 130–147.
        #expect(HeartRateZone.z2.bpmRange(max: 185) == 111...129)
        #expect(HeartRateZone.z3.bpmRange(max: 185) == 130...147)
        #expect(HeartRateZone.z5.bpmRange(max: 185) == 167...185)
        #expect(HeartRateZone(bpm: 140, max: 185) == .z3)
        #expect(HeartRateZone(bpm: 80, max: 185) == .z1)
        #expect(HeartRateZone(bpm: 180, max: 185) == .z5)
    }
}
