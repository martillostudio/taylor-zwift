import Testing
@testable import CicloKit

@Suite("Indoor Bike Data")
struct IndoorBikeDataTests {
    @Test func velocidadCadenciaYPotencia() throws {
        // flags 0x0044: bit0=0 (viene velocidad), bit2 cadencia, bit6 potencia
        let d = try IndoorBikeData(parsing: [0x44, 0x00, 0x10, 0x0E, 0xB4, 0x00, 0xFA, 0x00])
        #expect(d.speedKmh == 36.0)
        #expect(d.cadenceRpm == 90.0)
        #expect(d.powerWatts == 250)
        #expect(d.totalDistanceMeters == nil)
    }

    @Test func bitMoreDataQuitaLaVelocidad() throws {
        let d = try IndoorBikeData(parsing: [0x01, 0x00])
        #expect(d == IndoorBikeData())
    }

    @Test func distanciaDe24Bits() throws {
        let d = try IndoorBikeData(parsing: [0x11, 0x00, 0x39, 0x30, 0x00])
        #expect(d.totalDistanceMeters == 12345)
    }

    @Test func potenciaNegativa() throws {
        let d = try IndoorBikeData(parsing: [0x41, 0x00, 0xFF, 0xFF])
        #expect(d.powerWatts == -1)
    }

    @Test func saltaEnergiaYLeeFCyTiempo() throws {
        // flags 0x0B01: energía (5 bytes), pulso, tiempo transcurrido
        let d = try IndoorBikeData(parsing: [0x01, 0x0B, 0x64, 0x00, 0xFF, 0xFF, 0xFF, 0x8C, 0x2C, 0x01])
        #expect(d.totalEnergyKcal == 100)
        #expect(d.heartRateBpm == 140)
        #expect(d.elapsedTimeSeconds == 300)
    }

    @Test func mensajeCortadoLanzaError() {
        #expect(throws: ParseError.truncated(needed: 2, offset: 2)) {
            try IndoorBikeData(parsing: [0x44, 0x00, 0x10])
        }
    }

    @Test func combinaMensajesParciales() throws {
        let a = try IndoorBikeData(parsing: [0x44, 0x00, 0x10, 0x0E, 0xB4, 0x00, 0xFA, 0x00])
        let b = try IndoorBikeData(parsing: [0x11, 0x00, 0x39, 0x30, 0x00])
        let m = a.merging(b)
        #expect(m.powerWatts == 250)
        #expect(m.totalDistanceMeters == 12345)
    }
}

@Suite("Comandos FTMS")
struct FTMSCommandTests {
    @Test func pedirControl() {
        #expect(FTMSCommand.requestControl.bytes == [0x00])
    }

    @Test func erg150W() {
        #expect(FTMSCommand.setTargetPower(watts: 150).bytes == [0x05, 0x96, 0x00])
    }

    @Test func simulacionPendientePositiva() {
        let cmd = FTMSCommand.setSimulation(.init(gradePercent: 5.5))
        // viento 0 · pendiente 550 (0x0226) · Crr 40 · Cw 51
        #expect(cmd.bytes == [0x11, 0x00, 0x00, 0x26, 0x02, 0x28, 0x33])
    }

    @Test func simulacionPendienteNegativa() {
        let cmd = FTMSCommand.setSimulation(.init(gradePercent: -3))
        #expect(Array(cmd.bytes[3...4]) == [0xD4, 0xFE]) // -300
    }

    @Test func valoresFueraDeRangoSeRecortan() {
        #expect(FTMSCommand.setTargetPower(watts: 100_000).bytes == [0x05, 0xFF, 0x7F])
        let cmd = FTMSCommand.setSimulation(.init(gradePercent: 1, crr: 1))
        #expect(cmd.bytes[5] == 255)
    }
}

@Suite("Respuestas y estado")
struct FTMSResponseTests {
    @Test func controlConcedido() throws {
        let r = try ControlPointResponse(parsing: [0x80, 0x00, 0x01])
        #expect(r.requestOpcode == 0x00)
        #expect(r.result == .success)
    }

    @Test func controlNoPermitido() throws {
        let r = try ControlPointResponse(parsing: [0x80, 0x11, 0x05])
        #expect(r.result == .controlNotPermitted)
    }

    @Test func respuestaConOpcodeIncorrecto() {
        #expect(throws: ParseError.unexpectedOpcode(0x01)) {
            try ControlPointResponse(parsing: [0x01, 0x00, 0x01])
        }
    }

    @Test func estadoPotenciaObjetivo() throws {
        #expect(try MachineStatus(parsing: [0x08, 0x96, 0x00]) == .targetPowerChanged(watts: 150))
    }

    @Test func estadoSimulacion() throws {
        let s = try MachineStatus(parsing: [0x12, 0x00, 0x00, 0x26, 0x02, 0x28, 0x33])
        #expect(s == .simulationParametersChanged(.init(gradePercent: 5.5)))
    }

    @Test func estadoControlPerdido() throws {
        #expect(try MachineStatus(parsing: [0xFF]) == .controlPermissionLost)
    }
}
