import Testing
@testable import CicloKit

@Suite("Marchas virtuales")
struct VirtualGearsTests {
    @Test func carretera2x12() {
        let d = Drivetrain.road2x12
        #expect(d.gears.count == 24)
        #expect(abs(d.gears[0].ratio - 1.0) < 1e-9) // 34×34: el molinillo
        #expect(abs(d.gears[23].ratio - 50.0 / 11) < 1e-9) // 50×11
        #expect(d.gears[0].label == "34×34")
        #expect(d.gears[23].label == "50×11")
        // Repartidas por igual: todos los saltos son el mismo %.
        let steps = zip(d.gears, d.gears.dropFirst()).map { $1.ratio / $0.ratio }
        #expect(steps.allSatisfy { abs($0 - steps[0]) < 1e-9 })
        #expect(steps[0] > 1.06 && steps[0] < 1.075)
    }

    @Test func monoplatos() {
        #expect(Drivetrain.grx1x12.gears.count == 12)
        #expect(Drivetrain.grx1x12.gears.first?.label == "40×51")
        #expect(Drivetrain.xplr1x12.gears.last?.label == "40×10")
        for d in Drivetrain.all {
            let r = d.gears.map(\.ratio)
            #expect(r == r.sorted(), "\(d.name)")
        }
    }

    @Test func calibracionDelRodillo() {
        var c = TrainerCalibration()
        #expect(abs(c.trainerRatio - 2.82) < 0.01)
        c.add(speedKmh: 10, cadenceRpm: 20) // cadencia demasiado baja: no cuenta
        #expect(c.samples == 0)
        for _ in 0..<500 { c.add(speedKmh: 30, cadenceRpm: 75) } // 0,4 km/h por rpm
        #expect(abs(c.kmhPerRpm - 0.4) < 0.001)
    }

    @Test func molinilloEnSubida() {
        // Marcha 1 (34×34) con el rodillo a 2,82: el 3 % llega como ~1,06 %.
        let g = VirtualGears(index: 0, trainerRatio: 2.82)
        #expect(abs(g.k - 1 / 2.82) < 1e-9)
        let p = g.simulation(gradePercent: 3)
        #expect(abs(p.gradePercent - 3 / 2.82) < 1e-9)
    }

    @Test func empiezaEnUnaMarchaDeLlano() {
        let g = VirtualGears()
        #expect(abs(g.gear.ratio - VirtualGears.startRatio) < 0.1)
        #expect(g.count == 24)
    }

    @Test func extremosYLimites() {
        var g = VirtualGears(index: 0)
        let couldGoDown = g.shiftDown()
        #expect(!couldGoDown)
        #expect(g.number == 1)
        g = VirtualGears(index: 23)
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

    @Test func cambiarDeDesarrolloMantieneLaMarcha() {
        var g = VirtualGears()
        let before = g.gear.ratio
        g.change(to: .grx1x12)
        #expect(g.count == 12)
        #expect(abs(g.gear.ratio / before - 1) < 0.15)
    }

    @Test func escalaPendienteRodaduraYAire() {
        let g = VirtualGears(index: 23, trainerRatio: 50.0 / 11 / 1.5) // k = 1,5
        let p = g.simulation(gradePercent: 4)
        #expect(abs(p.gradePercent - 6) < 1e-9)
        #expect(abs(p.crr - 0.006) < 1e-9)
        #expect(abs(p.windResistanceKgPerM - 0.51 * 3.375) < 1e-9)
    }

    @Test func respetaLosMaximosDeFTMS() {
        let g = VirtualGears(index: 23, trainerRatio: 50.0 / 11 / 3) // k = 3
        let p = g.simulation(gradePercent: 20)
        #expect(p.gradePercent == 40)
        #expect(p.windResistanceKgPerM == 2.55)
        #expect(p.crr <= 0.0255)
        // Con el rodillo real, la marcha más dura de cada desarrollo cabe sin recortar el aire.
        for d in Drivetrain.all {
            let hardest = VirtualGears(drivetrain: d, index: d.gears.count - 1).simulation(gradePercent: 0)
            #expect(hardest.windResistanceKgPerM < 2.55, "\(d.name)")
        }
    }

    @Test func velocidadVirtual() {
        let g = VirtualGears(index: 23, trainerRatio: 50.0 / 11 / 1.5)
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
        #expect(Route.builtIn.count == 4)
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

@Suite("Subidas y colores")
struct ClimbTests {
    @Test func bandasDePendiente() {
        #expect(GradeBand(gradePercent: -5) == .descent)
        #expect(GradeBand(gradePercent: 0) == .easy)
        #expect(GradeBand(gradePercent: 2.9) == .easy)
        #expect(GradeBand(gradePercent: 3) == .moderate)
        #expect(GradeBand(gradePercent: 6.5) == .hard)
        #expect(GradeBand(gradePercent: 10) == .veryHard)
        #expect(GradeBand(gradePercent: 15) == .extreme)
    }

    @Test func categorias() {
        #expect(ClimbCategory(score: 5_000) == .uncategorized)
        #expect(ClimbCategory(score: 14_000) == .cat4)
        #expect(ClimbCategory(score: 48_000) == .cat2)
        #expect(ClimbCategory(score: 90_000) == .hc)
    }

    @Test func elPuertoEsUnaSubidaDeSegunda() {
        let climbs = Route.climb.climbs
        #expect(climbs.count == 1)
        let c = climbs[0]
        #expect(c.startMeters == 1_000)
        #expect(c.endMeters == 9_000)
        #expect(abs(c.ascentMeters - 480) < 1e-9)
        #expect(abs(c.averageGradePercent - 6) < 1e-9)
        #expect(c.category == .cat2)
    }

    @Test func rompepiernasYOndulado() {
        let climbs = Route.punchy.climbs
        #expect(climbs.count == 2)
        #expect(climbs.map(\.category) == [.uncategorized, .cat4])
        // El ondulado tiene repechos, pero ninguno llega a subida.
        #expect(Route.rolling.climbs.isEmpty)
    }

    @Test func descansilloCortoNoCortaLaSubida() {
        let r = Route(id: "d", name: "d", isLoop: false, segments: [
            RouteSegment(1_000, 6), RouteSegment(200, 0), RouteSegment(1_000, 6),
        ])
        #expect(r.climbs.count == 1)
        #expect(r.climbs.first?.lengthMeters == 2_200)
    }

    @Test func estadoEnLaSubida() throws {
        let r = Route.climb
        // A 1 km del pie.
        let before = try #require(r.climbStatus(atDistance: 0, lookAhead: 2_000))
        #expect(!before.isOnClimb)
        #expect(before.distanceToStart == 1_000)
        // Lejos: nada.
        #expect(r.climbStatus(atDistance: 0, lookAhead: 500) == nil)
        // A mitad: quedan 4 km y 260 m (2 km al 6 % y 2 km al 7 %... y el resto).
        let mid = try #require(r.climbStatus(atDistance: 5_000))
        #expect(mid.isOnClimb)
        #expect(abs(mid.remainingMeters - 4_000) < 1e-9)
        #expect(abs(mid.remainingAscentMeters - 260) < 1e-9)
        #expect(abs(mid.progress - 0.5) < 1e-9)
        #expect(abs(mid.remainingAverageGradePercent - 6.5) < 1e-9)
        // Pasada la cima.
        #expect(r.climbStatus(atDistance: 9_500) == nil)
    }

    @Test func enCircularVeLaSubidaDeLaVueltaSiguiente() throws {
        let r = Route.punchy
        let s = try #require(r.climbStatus(atDistance: r.lengthMeters - 500, lookAhead: 2_000))
        #expect(abs(s.distanceToStart - 1_500) < 1e-9)
        #expect(s.climb.category == .uncategorized)
    }

    @Test func trozosColoreados() {
        let chunks = Route.climb.chunks(from: 0, to: 2_000, size: 500)
        #expect(chunks.count == 4)
        #expect(chunks.map(\.band) == [.easy, .easy, .moderate, .moderate])
        #expect(abs(chunks[3].gradePercent - 5) < 1e-9)
    }
}

@Suite("Pulsómetro")
struct HeartRateTests {
    @Test func pulsacionesEnUnByte() throws {
        let m = try HeartRateMeasurement(parsing: [0x00, 0x48])
        #expect(m.bpm == 72)
        #expect(m.skinContact == nil)
    }

    @Test func pulsacionesEnDosBytesYContacto() throws {
        let m = try HeartRateMeasurement(parsing: [0x07, 0x2C, 0x01]) // 300 (no realista, pero prueba los 16 bits)
        #expect(m.bpm == 300)
        #expect(m.skinContact == true)
        let off = try HeartRateMeasurement(parsing: [0x04, 0x50])
        #expect(off.skinContact == false)
    }

    @Test func mensajeVacioOCortado() {
        #expect(throws: ParseError.empty) { try HeartRateMeasurement(parsing: []) }
        #expect(throws: (any Error).self) { try HeartRateMeasurement(parsing: [0x01, 0x50]) }
    }

    @Test func mediaYMaximoEnLaSesion() {
        var s = RideSession()
        s.update(speedKmh: 30, powerWatts: 150, cadenceRpm: 85, heartRateBpm: 120, at: 0)
        s.update(speedKmh: 30, powerWatts: 150, cadenceRpm: 85, heartRateBpm: 120, at: 1)
        s.update(speedKmh: 30, powerWatts: 150, cadenceRpm: 85, heartRateBpm: 140, at: 2)
        #expect(s.averageHeartRateBpm == 130)
        #expect(s.maxHeartRateBpm == 140)
    }
}
