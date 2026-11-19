import Testing
@testable import CicloKit

@Suite("OpenBikeControl")
struct OpenBikeControlTests {
    @Test func pulsarYSoltarSubirMarcha() {
        #expect(OpenBikeControl.buttonState([(.shiftUp, true)]) == [0x01, 0x01, 0x01])
        #expect(OpenBikeControl.buttonState([(.shiftUp, false)]) == [0x01, 0x01, 0x00])
    }

    @Test func variasAccionesEnUnMensaje() {
        let bytes = OpenBikeControl.buttonState([(.shiftDown, true), (.select, true)])
        #expect(bytes == [0x01, 0x02, 0x01, 0x14, 0x01])
    }

    @Test func estadoDelMando() {
        #expect(OpenBikeControl.deviceStatus(batteryPercent: 85, connected: true) == [0x02, 0x55, 0x01])
        #expect(OpenBikeControl.deviceStatus(batteryPercent: nil, connected: true) == [0x02, 0xFF, 0x01])
        #expect(OpenBikeControl.deviceStatus(batteryPercent: 140, connected: false) == [0x02, 100, 0x00])
    }

    /// Ejemplo de la especificación (MDNS.md).
    private let appInfoExample: [UInt8] =
        [0x04, 0x01, 0x05] + Array("zwift".utf8) + [0x06] + Array("1.52.0".utf8) + [0x04, 0x01, 0x02, 0x10, 0x14]

    @Test func appInfoCompleto() {
        var parser = OBCInboundParser()
        let messages = parser.feed(appInfoExample)
        #expect(messages == [.appInfo(OBCAppInfo(
            formatVersion: 1, appID: "zwift", appVersion: "1.52.0", supportedButtons: [0x01, 0x02, 0x10, 0x14]))])
        #expect(parser.pendingByteCount == 0)
    }

    @Test func appInfoTroceadoPorTCP() {
        var parser = OBCInboundParser()
        for i in 0..<(appInfoExample.count - 1) {
            #expect(parser.feed([appInfoExample[i]]).isEmpty, "byte \(i)")
        }
        let messages = parser.feed([appInfoExample.last!])
        #expect(messages.count == 1)
    }

    @Test func appInfoSinBotonesEsTodos() {
        var parser = OBCInboundParser()
        let messages = parser.feed([0x04, 0x01, 0x00, 0x00, 0x00])
        guard case .appInfo(let info) = messages.first else { Issue.record("no es app info"); return }
        #expect(info.supportsAllButtons)
    }

    @Test func variosMensajesJuntosYDesconocidos() {
        var parser = OBCInboundParser()
        let messages = parser.feed([0x03, 0x01, 0x0A, 0x00, 0x99] + appInfoExample)
        #expect(messages.count == 3)
        #expect(messages[0] == .haptic(pattern: 1, duration: 10, intensity: 0))
        #expect(messages[1] == .unknown(0x99))
    }

    @Test func txtRecord() {
        let txt = OpenBikeControl.txtRecord(id: "abc", name: "Taylor Mandos", manufacturer: "Taylor", model: "Click V2")
        #expect(txt["version"] == "1")
        #expect(txt["service-uuids"] == OpenBikeControl.serviceUUID)
        #expect(txt["name"] == "Taylor Mandos")
    }
}

@Suite("Mapeo de botones")
struct BridgeMappingTests {
    @Test func masDerechoSubeMenosIzquierdoBaja() {
        #expect(BridgeMapping.actions(for: .shiftUpRight) == [.shiftUp])
        #expect(BridgeMapping.actions(for: .shiftUpLeft) == [.shiftDown])
    }

    @Test func yZRepitenLasMarchas() {
        #expect(BridgeMapping.actions(for: .z) == [.shiftUp])
        #expect(BridgeMapping.actions(for: .y) == [.shiftDown])
    }

    @Test func noRepiteAcciones() {
        #expect(BridgeMapping.actions(for: [.shiftUpRight, .z]) == [.shiftUp])
    }

    @Test func botonSinAccion() {
        #expect(BridgeMapping.actions(for: .onOffLeft).isEmpty)
    }

    @Test func teclasDeMyWhoosh() {
        #expect(BridgeAction.shiftUp.macKeyCode == 40) // K
        #expect(BridgeAction.shiftDown.macKeyCode == 34) // I
        #expect(BridgeAction.shiftUp.openBikeControl.rawValue == 0x01)
        #expect(BridgeAction.shiftDown.openBikeControl.rawValue == 0x02)
    }
}
