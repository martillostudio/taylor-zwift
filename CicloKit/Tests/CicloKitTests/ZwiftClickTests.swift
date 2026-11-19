import Testing
@testable import CicloKit

/// Codifica un varint de protobuf (solo para construir mensajes de prueba).
private func varint(_ value: UInt64) -> [UInt8] {
    var v = value
    var out: [UInt8] = []
    repeat {
        var byte = UInt8(v & 0x7F)
        v >>= 7
        if v != 0 { byte |= 0x80 }
        out.append(byte)
    } while v != 0
    return out
}

/// Mensaje de botones: opcode 0x23 + campo 1 (varint) con el mapa.
private func buttonMessage(map: UInt32) -> [UInt8] {
    [0x23, 0x08] + varint(UInt64(map))
}

@Suite("Zwift Click")
struct ZwiftClickTests {
    @Test func reposoNoHayNadaPulsado() throws {
        let m = try ZwiftClickMessage(parsing: buttonMessage(map: 0xFFFF_FFFF))
        #expect(m == .buttons(pressed: [], rawMap: 0xFFFF_FFFF))
    }

    @Test func bitACeroEsPulsado() throws {
        let map: UInt32 = 0xFFFF_FFFF & ~ZwiftButton.a.rawValue
        let m = try ZwiftClickMessage(parsing: buttonMessage(map: map))
        #expect(m == .buttons(pressed: .a, rawMap: map))
    }

    @Test func variosBotonesALaVez() throws {
        let map: UInt32 = ~(ZwiftButton.b.rawValue | ZwiftButton.shiftUpRight.rawValue)
        guard case .buttons(let pressed, _) = try ZwiftClickMessage(parsing: buttonMessage(map: map)) else {
            Issue.record("no es un mensaje de botones"); return
        }
        #expect(pressed == [.b, .shiftUpRight])
        #expect(pressed.names == ["B", "marcha+ dcha"])
    }

    @Test func ignoraCamposDesconocidos() throws {
        // campo 2 (length-delimited, 2 bytes) antes del campo 1
        let bytes: [UInt8] = [0x23, 0x12, 0x02, 0xAA, 0xBB, 0x08] + varint(0xFFFF_FFEF)
        let m = try ZwiftClickMessage(parsing: bytes)
        #expect(m == .buttons(pressed: .a, rawMap: 0xFFFF_FFEF))
    }

    @Test func respuestaAlRideOn() throws {
        let m = try ZwiftClickMessage(parsing: Array("RideOn".utf8) + [0x01, 0x03])
        #expect(m == .rideOnAck(extra: [0x01, 0x03]))
    }

    @Test func otrosMensajesSeConservan() throws {
        #expect(try ZwiftClickMessage(parsing: [0x2A, 0x08, 0x03]) == .other(opcode: 0x2A, payload: [0x08, 0x03]))
    }

    @Test func bateria() throws {
        // Mensaje real del Click V2: opcode 0x19, campo 2 = 100 %.
        #expect(try ZwiftClickMessage(parsing: [0x19, 0x10, 0x64]) == .battery(percent: 100))
        #expect(try ZwiftClickMessage(parsing: [0x19, 0x10, 0x37]) == .battery(percent: 55))
    }

    @Test func mensajeNoProtobufNoFalla() throws {
        // Los 0xFF del Click llevan datos que no son protobuf: deben quedar como «otro».
        let bytes: [UInt8] = [0xFF, 0x03, 0x00, 0x0A, 0x21, 0x03, 0x33, 0xA6]
        #expect(try ZwiftClickMessage(parsing: bytes) == .other(opcode: 0xFF, payload: Array(bytes.dropFirst())))
    }

    @Test func mensajeVacio() {
        #expect(throws: ParseError.empty) { try ZwiftClickMessage(parsing: []) }
    }

    @Test func saludoRideOn() {
        #expect(ZwiftClickProtocol.rideOn == [0x52, 0x69, 0x64, 0x65, 0x4F, 0x6E])
    }
}

@Suite("Botones de varios mandos")
struct ZwiftButtonAggregatorTests {
    /// Pulsa y suelta `button` en `source` en el instante `t`. Devuelve si contó.
    private func tap(_ agg: inout ZwiftButtonAggregator<Int>, _ source: Int, _ button: ZwiftButton,
                     at t: Double) -> Bool {
        let counted = agg.update(source: source, pressed: button, at: t)
        agg.update(source: source, pressed: [], at: t + 0.05)
        return counted == button
    }

    @Test func ecoQueLlegaMientrasSigoPulsando() {
        var agg = ZwiftButtonAggregator<Int>()
        let first = agg.update(source: 1, pressed: .shiftUpRight, at: 0)
        let echo = agg.update(source: 2, pressed: .shiftUpRight, at: 0.03)
        #expect(first == .shiftUpRight)
        #expect(echo.isEmpty)
        #expect(agg.pressed == .shiftUpRight)
    }

    @Test func ecoQueLlegaDespuesDeSoltar() {
        // Caso real del log: A por el derecho, soltado, y el eco del izquierdo 150 ms después.
        var agg = ZwiftButtonAggregator<Int>()
        #expect(tap(&agg, 2, .a, at: 0))
        #expect(!tap(&agg, 1, .a, at: 0.15))
    }

    @Test func elEcoPuedeLlegarPrimeroPorCualquierMando() {
        var agg = ZwiftButtonAggregator<Int>()
        // 1.ª pulsación: llega antes por el 2.
        #expect(tap(&agg, 2, .b, at: 0))
        #expect(!tap(&agg, 1, .b, at: 0.03))
        // 2.ª pulsación (1 s después): esta vez llega antes por el 1.
        #expect(tap(&agg, 1, .b, at: 1.0))
        #expect(!tap(&agg, 2, .b, at: 1.1))
    }

    @Test func pulsacionesRapidasCuentanTodas() {
        // Tres toques en 0,4 s con eco en cada uno: deben contar 3, ni más ni menos.
        var agg = ZwiftButtonAggregator<Int>()
        var count = 0
        for i in 0..<3 {
            let t = Double(i) * 0.2
            if tap(&agg, 2, .shiftUpRight, at: t) { count += 1 }
            if tap(&agg, 1, .shiftUpRight, at: t + 0.03) { count += 1 }
        }
        #expect(count == 3)
    }

    @Test func botonesDistintosEnCadaMando() {
        var agg = ZwiftButtonAggregator<Int>()
        let a = agg.update(source: 1, pressed: .a, at: 0)
        let shift = agg.update(source: 2, pressed: .shiftUpLeft, at: 0.01)
        #expect(a == .a)
        #expect(shift == .shiftUpLeft)
        #expect(agg.pressed == [.a, .shiftUpLeft])
    }

    @Test func dosBotonesEnElMismoMensaje() {
        // El izquierdo manda a veces A + ← juntos (mapa 0xFFFFFFEE).
        var agg = ZwiftButtonAggregator<Int>()
        let both = agg.update(source: 1, pressed: [.a, .left], at: 0)
        #expect(both == [.a, .left])
    }

    @Test func alQuitarUnMandoSeSueltanSusBotones() {
        var agg = ZwiftButtonAggregator<Int>()
        agg.update(source: 1, pressed: .b, at: 0)
        agg.remove(source: 1)
        #expect(agg.pressed.isEmpty)
        let again = agg.update(source: 2, pressed: .b, at: 0.1)
        #expect(again == .b)
    }
}
