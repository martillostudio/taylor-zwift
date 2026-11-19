import Testing
@testable import CicloKit

@Suite("Marchas virtuales")
struct VirtualGearsTests {
    @Test func empiezaEnLaMarchaNeutra() {
        let g = VirtualGears()
        #expect(g.count == 24)
        #expect(abs(g.ratio - 1) < 0.05)
    }

    @Test func extremosYLimites() {
        var g = VirtualGears(index: 0)
        #expect(abs(g.ratio - 0.5) < 1e-9)
        let couldGoDown = g.shiftDown()
        #expect(!couldGoDown)
        #expect(g.number == 1)
        g = VirtualGears(index: 23)
        #expect(abs(g.ratio - 1.7) < 1e-9)
        let couldGoUp = g.shiftUp()
        #expect(!couldGoUp)
        #expect(g.number == 24)
    }

    @Test func subirYBajar() {
        var g = VirtualGears()
        let start = g.index
        let up = g.shiftUp()
        #expect(up)
        #expect(g.index == start + 1)
        let down = g.shiftDown()
        #expect(down)
        #expect(g.index == start)
    }

    @Test func escalaPendienteRodaduraYAire() {
        let g = VirtualGears(ratios: [0.5, 1, 1.5], index: 2)
        let p = g.simulation(gradePercent: 4)
        #expect(abs(p.gradePercent - 6) < 1e-9)
        #expect(abs(p.crr - 0.006) < 1e-9)
        #expect(abs(p.windResistanceKgPerM - 0.51 * 3.375) < 1e-9)
    }

    @Test func respetaLosMaximosDeFTMS() {
        let g = VirtualGears(ratios: [3], index: 0)
        let p = g.simulation(gradePercent: 20)
        #expect(p.gradePercent == 40)
        #expect(p.windResistanceKgPerM == 2.55)
        #expect(p.crr <= 0.0255)
        // La marcha más dura de serie cabe sin recortar el aire.
        let hardest = VirtualGears(index: 23).simulation(gradePercent: 0)
        #expect(hardest.windResistanceKgPerM < 2.55)
    }

    @Test func velocidadVirtual() {
        let g = VirtualGears(ratios: [1.5], index: 0)
        #expect(abs(g.virtualSpeed(fromTrainerKmh: 20) - 30) < 1e-9)
    }
}

@Suite("Rutas")
struct RouteTests {
    let route = Route(id: "t", name: "t", isLoop: false, segments: [
        RouteSegment(1_000, 0), RouteSegment(1_000, 10), RouteSegment(1_000, -5),
    ])

    @Test func alturaPorTramos() {
        #expect(route.lengthMeters == 3_000)
        #expect(abs(route.elevation(atDistance: 1_000)) < 1e-9)
        #expect(abs(route.elevation(atDistance: 1_500) - 50) < 1e-9)
        #expect(abs(route.elevation(atDistance: 2_000) - 100) < 1e-9)
        #expect(abs(route.elevation(atDistance: 3_000) - 50) < 1e-9)
        #expect(abs(route.climbMeters - 100) < 1e-9)
    }

    @Test func pendienteEnMitadDeTramo() {
        #expect(route.grade(atDistance: 500) == 0)
        #expect(route.grade(atDistance: 1_500) == 10)
        #expect(route.grade(atDistance: 2_500) == -5)
    }

    @Test func pendienteSuavizadaEnElCambio() {
        // Justo en el cambio de 0 % a 10 %: la mitad.
        #expect(route.grade(atDistance: 1_000) == 5)
        // Fuera de la zona de suavizado ya es la del tramo.
        #expect(route.grade(atDistance: 1_030) == 10)
    }

    @Test func despuesDelFinalEsLlano() {
        #expect(route.grade(atDistance: 5_000) == 0)
        #expect(route.isFinished(atDistance: 3_000))
        #expect(!route.isFinished(atDistance: 2_999))
    }

    @Test func circularSeRepite() {
        let loop = Route(id: "l", name: "l", isLoop: true, segments: [RouteSegment(1_000, 4), RouteSegment(1_000, -4)])
        #expect(loop.grade(atDistance: 2_500) == 4)
        #expect(loop.grade(atDistance: 3_500) == -4)
        #expect(abs(loop.positionInLap(2_500) - 500) < 1e-9)
        #expect(abs(loop.elevation(atDistance: 2_000)) < 1e-9)
    }

    @Test func rutasIncluidas() {
        #expect(Route.builtIn.count == 3)
        // Las circulares acaban a la altura de la salida (si no, la vuelta tendría un escalón).
        for r in Route.builtIn where r.isLoop {
            #expect(abs(r.elevation(atDistance: r.lengthMeters)) < 1e-6, "\(r.name)")
        }
        #expect(abs(Route.climb.climbMeters - 480) < 1e-6)
    }

    @Test func perfil() {
        let p = route.profile(points: 4)
        #expect(p.count == 4)
        #expect(p.first?.distanceMeters == 0)
        #expect(p.last?.distanceMeters == 3_000)
        #expect(abs((p.last?.elevationMeters ?? 0) - 50) < 1e-9)
    }
}

@Suite("Sesión de entrenamiento")
struct RideSessionTests {
    @Test func integraDistanciaTiempoYPotencia() {
        var s = RideSession()
        s.update(speedKmh: 36, powerWatts: 200, cadenceRpm: 90, at: 0) // primera muestra: solo arranca
        s.update(speedKmh: 36, powerWatts: 200, cadenceRpm: 90, at: 1)
        s.update(speedKmh: 36, powerWatts: 300, cadenceRpm: 90, at: 2)
        #expect(abs(s.distanceMeters - 20) < 1e-9) // 10 m/s × 2 s
        #expect(s.movingSeconds == 2)
        #expect(s.averagePowerWatts == 250)
        #expect(s.maxPowerWatts == 300)
    }

    @Test func paradoNoCuenta() {
        var s = RideSession()
        s.update(speedKmh: 0, powerWatts: 0, cadenceRpm: 0, at: 0)
        s.update(speedKmh: 0, powerWatts: 0, cadenceRpm: 0, at: 1)
        #expect(s.movingSeconds == 0)
        #expect(s.averagePowerWatts == nil)
    }

    @Test func huecosLargosYPausaNoSeIntegran() {
        var s = RideSession()
        s.update(speedKmh: 36, powerWatts: 200, cadenceRpm: 90, at: 0)
        s.update(speedKmh: 36, powerWatts: 200, cadenceRpm: 90, at: 10) // hueco de 10 s
        #expect(s.movingSeconds == 0)
        s.update(speedKmh: 36, powerWatts: 200, cadenceRpm: 90, at: 11)
        #expect(s.movingSeconds == 1)
        s.pause()
        s.update(speedKmh: 36, powerWatts: 200, cadenceRpm: 90, at: 12)
        #expect(s.movingSeconds == 1)
    }
}

@Suite("Objetivo del rodillo")
struct TrainerTargetTests {
    @Test func igualesSiLosBytesSonIguales() {
        let a = TrainerTarget.simulation(SimulationParameters(gradePercent: 3.001))
        let b = TrainerTarget.simulation(SimulationParameters(gradePercent: 3.004))
        let c = TrainerTarget.simulation(SimulationParameters(gradePercent: 3.1))
        #expect(a.isSameOnTheWire(as: b))
        #expect(!a.isSameOnTheWire(as: c))
        #expect(!a.isSameOnTheWire(as: nil))
        #expect(!a.isSameOnTheWire(as: .targetPower(watts: 150)))
    }

    @Test func comandos() {
        #expect(TrainerTarget.targetPower(watts: 150).command.bytes == [0x05, 0x96, 0x00])
        #expect(TrainerTarget.flat.command.bytes == [0x11, 0x00, 0x00, 0x00, 0x00, 0x28, 0x33])
    }
}
