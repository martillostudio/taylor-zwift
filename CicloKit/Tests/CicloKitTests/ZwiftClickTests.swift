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
        #expect(try ZwiftClickMessage(parsing: [0x19, 0x10, 0x55]) == .other(opcode: 0x19, payload: [0x10, 0x55]))
    }

    @Test func mensajeVacio() {
        #expect(throws: ParseError.empty) { try ZwiftClickMessage(parsing: []) }
    }

    @Test func saludoRideOn() {
        #expect(ZwiftClickProtocol.rideOn == [0x52, 0x69, 0x64, 0x65, 0x4F, 0x6E])
    }
}
