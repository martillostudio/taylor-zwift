import Foundation
import Testing
@testable import CicloKit

@Suite("Entrenamientos")
struct WorkoutTests {
    let simple = Workout(id: "s", name: "s", category: .tempo, summary: "", steps: [
        .ramp(seconds: 100, from: 0.5, to: 0.7),
        .intervals(repeats: 2, onSeconds: 60, onPower: 1.1, offSeconds: 30, offPower: 0.5),
        .freeRide(seconds: 50),
    ])

    @Test func despliegaLosPasos() {
        #expect(simple.segments.count == 6) // rampa + 2×(on+off) + libre
        #expect(simple.durationSeconds == 100 + 2 * 90 + 50)
        #expect(simple.segments[1].startSeconds == 100)
        #expect(simple.segments[1].startPower == 1.1)
        #expect(simple.segments[5].isFree)
    }

    @Test func objetivoEnCadaMomento() {
        #expect(abs((simple.target(at: 50) ?? 0) - 0.6) < 1e-9) // mitad de la rampa
        #expect(simple.target(at: 130) == 1.1)
        #expect(simple.target(at: 165) == 0.5)
        #expect(simple.target(at: 300) == nil) // tramo libre
        #expect(simple.target(at: 330) == nil) // terminado
        #expect(simple.segmentIndex(at: -1) == nil)
    }

    @Test func progreso() throws {
        let p = try #require(simple.progress(at: 120))
        #expect(p.segment.id == 1)
        #expect(p.next?.id == 2)
        #expect(abs(p.secondsLeftInSegment - 40) < 1e-9)
        #expect(abs(p.secondsLeftInWorkout - 210) < 1e-9)
        #expect(simple.progress(at: 1_000) == nil)
    }

    @Test func intensidadYCarga() {
        // Una hora clavada al 100 % = IF 1 y 100 TSS.
        let ftpHour = Workout(id: "h", name: "h", category: .threshold, summary: "", steps: [.steady(seconds: 3_600, power: 1.0)])
        #expect(abs(ftpHour.intensityFactor - 1) < 1e-9)
        #expect(abs(ftpHour.tss - 100) < 1e-6)
        // Media hora al 50 %: IF 0,5 y 12,5 TSS.
        let easy = Workout(id: "e", name: "e", category: .recovery, summary: "", steps: [.steady(seconds: 1_800, power: 0.5)])
        #expect(abs(easy.tss - 12.5) < 1e-6)
    }

    @Test func zonas() {
        #expect(PowerZone(fractionOfFTP: 0.5) == .z1)
        #expect(PowerZone(fractionOfFTP: 0.7) == .z2)
        #expect(PowerZone(fractionOfFTP: 0.9) == .z3)
        #expect(PowerZone(fractionOfFTP: 1.0) == .z4)
        #expect(PowerZone(fractionOfFTP: 1.12) == .z5)
        #expect(PowerZone(fractionOfFTP: 1.3) == .z6)
        #expect(PowerZone(fractionOfFTP: 2.0) == .z7)
    }

    @Test func biblioteca() {
        let lib = Workout.library
        #expect(Set(lib.map(\.id)).count == lib.count) // ids únicos
        #expect(lib.allSatisfy { $0.durationSeconds > 0 && !$0.summary.isEmpty })
        #expect(lib.filter { $0.ftpTest != nil }.count == 2)
        let ss = lib.first { $0.id == "ss-2x20" }
        #expect(ss?.mainZone == .z3) // 90 % cae en Z3 (tempo alto / sweet spot)
        #expect(lib.first { $0.id == "vo2-4x4" }?.mainZone == .z5)
        #expect(lib.first { $0.id == "z2-60" }?.mainZone == .z2)
        // El 30/15 son 3 series de 13 repeticiones.
        let r = lib.first { $0.id == "vo2-30-15" }
        #expect(r?.segments.filter { $0.startPower == 1.20 }.count == 39)
    }
}

@Suite("Potencia y estimaciones")
struct PowerTests {
    @Test func mejoresMedias() {
        var h = PowerHistory()
        for w in [100, 100, 300, 300, 100] { h.append(w) }
        #expect(h.bestAverage(seconds: 2) == 300)
        #expect(h.bestAverage(seconds: 3) == (100 + 300 + 300) / 3.0)
        #expect(h.bestAverage(seconds: 6) == nil)
    }

    @Test func ftpDeLosTests() {
        let ramp = PowerHistory(samples: Array(repeating: 150, count: 300) + Array(repeating: 320, count: 60))
        #expect(FTPTest.ramp.estimate(from: ramp) == 240) // 75 % de 320
        let twenty = PowerHistory(samples: Array(repeating: 250, count: 1_200))
        #expect(FTPTest.twentyMinutes.estimate(from: twenty) == 238) // 95 % de 250 = 237,5
        #expect(FTPTest.twentyMinutes.estimate(from: PowerHistory(samples: [300])) == nil)
    }

    @Test func vo2max() {
        // 300 W en 5' con 75 kg: 10,8 × 4 + 7 = 50,2 ml/kg/min.
        let v = Physiology.vo2maxEstimate(best5MinWatts: 300, weightKg: 75)
        #expect(abs((v ?? 0) - 50.2) < 1e-9)
        #expect(Physiology.vo2maxEstimate(best5MinWatts: 300, weightKg: 0) == nil)
    }
}

@Suite("Ficheros .zwo")
struct ZwoTests {
    @Test func leeUnEntrenoDeZwift() throws {
        let xml = """
        <workout_file>
            <author>yo</author>
            <name>Prueba 2x5</name>
            <description>Dos bloques de cinco.</description>
            <sportType>bike</sportType>
            <workout>
                <Warmup Duration="300" PowerLow="0.40" PowerHigh="0.70"/>
                <SteadyState Duration="120" Power="0.6"><textevent timeoffset="10" message="¡Vamos!"/></SteadyState>
                <IntervalsT Repeat="2" OnDuration="300" OffDuration="120" OnPower="1.0" OffPower="0.5"/>
                <FreeRide Duration="60"/>
                <Cooldown Duration="300" PowerLow="0.40" PowerHigh="0.65"/>
            </workout>
        </workout_file>
        """
        let w = try ZwoParser.parse(Data(xml.utf8), id: "x")
        #expect(w.name == "Prueba 2x5")
        #expect(w.summary == "Dos bloques de cinco.")
        #expect(w.category == .imported)
        #expect(w.steps.count == 5)
        #expect(w.segments.count == 1 + 1 + 4 + 1 + 1)
        #expect(w.durationSeconds == 300 + 120 + 2 * 420 + 60 + 300)
        // La vuelta a la calma siempre baja, aunque el fichero la escriba al revés.
        #expect(w.steps.last == .ramp(seconds: 300, from: 0.65, to: 0.40))
    }

    @Test func ficherosMalos() {
        #expect(throws: ZwoParser.Error.noSteps) {
            try ZwoParser.parse(Data("<workout_file><workout></workout></workout_file>".utf8), id: "v")
        }
        #expect(throws: (any Error).self) {
            try ZwoParser.parse(Data("esto no es xml <".utf8), id: "m")
        }
    }
}
