/// Protocolo abierto OpenBikeControl para mandos de ciclismo indoor.
/// Especificación: https://github.com/OpenBikeControl/openbikecontrol-protocol
///
/// Lo implementan MyWhoosh, TrainingPeaks Virtual, Rouvy, Auuki… Aquí nos hacemos pasar
/// por un «mando» que se anuncia en la red (Bonjour) y la app de entrenamiento se conecta
/// a nosotros por TCP. El formato binario es el mismo por red y por Bluetooth.
public enum OpenBikeControl {
    /// Tipo de servicio Bonjour que anuncia el mando.
    public static let bonjourType = "_openbikecontrol._tcp"
    /// UUID del servicio Bluetooth (se anuncia también en el TXT de Bonjour).
    public static let serviceUUID = "d273f680-d548-419d-b9d1-fa0472345229"
    public static let protocolVersion = "1"

    public enum MessageType {
        /// Mando → app: estado de botones `[0x01, id, valor, id, valor…]`.
        public static let buttonState: UInt8 = 0x01
        /// Mando → app (solo red): `[0x02, batería, conectado]`.
        public static let deviceStatus: UInt8 = 0x02
        /// App → mando: vibración `[0x03, patrón, duración, intensidad]`.
        public static let haptic: UInt8 = 0x03
        /// App → mando: qué botones entiende la app.
        public static let appInfo: UInt8 = 0x04
    }

    /// Acciones estándar (identificadores de botón del protocolo).
    public enum Action: UInt8, CaseIterable, Sendable {
        case shiftUp = 0x01
        case shiftDown = 0x02
        case navUp = 0x10
        case navDown = 0x11
        case navLeft = 0x12
        case navRight = 0x13
        case select = 0x14
        case back = 0x15
        case menu = 0x16
        case home = 0x17
        case steerLeft = 0x18
        case steerRight = 0x19
        case increaseDifficulty = 0x30
        case decreaseDifficulty = 0x31
        case pause = 0x33
        case resume = 0x34
        case cameraView = 0x40
        case hudToggle = 0x44
    }

    /// Mensaje de estado de botones. `true` = pulsado, `false` = suelto.
    public static func buttonState(_ changes: [(action: Action, pressed: Bool)]) -> [UInt8] {
        var bytes: [UInt8] = [MessageType.buttonState]
        for change in changes {
            bytes.append(change.action.rawValue)
            bytes.append(change.pressed ? 0x01 : 0x00)
        }
        return bytes
    }

    /// Mensaje de estado del mando. Batería en %, o `nil` si no se sabe.
    public static func deviceStatus(batteryPercent: Int?, connected: Bool) -> [UInt8] {
        let battery: UInt8 = batteryPercent.map { UInt8(clamping: max(0, min(100, $0))) } ?? 0xFF
        return [MessageType.deviceStatus, battery, connected ? 0x01 : 0x00]
    }

    /// Registro TXT de Bonjour (equivale a los datos del anuncio Bluetooth).
    public static func txtRecord(id: String, name: String, manufacturer: String, model: String) -> [String: String] {
        [
            "version": protocolVersion,
            "id": id,
            "name": name,
            "service-uuids": serviceUUID,
            "manufacturer": manufacturer,
            "model": model,
        ]
    }
}

/// Mensaje 0x04: la app nos dice quién es y qué botones entiende.
public struct OBCAppInfo: Equatable, Sendable {
    public var formatVersion: UInt8
    public var appID: String
    public var appVersion: String
    /// Identificadores de botón que la app entiende. Vacío = todos.
    public var supportedButtons: [UInt8]

    public var supportsAllButtons: Bool { supportedButtons.isEmpty }

    public init(formatVersion: UInt8, appID: String, appVersion: String, supportedButtons: [UInt8]) {
        self.formatVersion = formatVersion
        self.appID = appID
        self.appVersion = appVersion
        self.supportedButtons = supportedButtons
    }
}

/// Mensajes que nos puede mandar la app de entrenamiento.
public enum OBCInboundMessage: Equatable, Sendable {
    case appInfo(OBCAppInfo)
    case haptic(pattern: UInt8, duration: UInt8, intensity: UInt8)
    /// Tipo que no conocemos: se descarta ese byte.
    case unknown(UInt8)
}

/// Trocea lo que llega por TCP en mensajes.
///
/// El protocolo no tiene longitud ni separador: el primer byte dice el tipo y la longitud
/// sale del propio mensaje. TCP puede partir un mensaje en varios trozos (o juntar varios),
/// así que guardamos lo que sobra hasta que llegue el resto.
public struct OBCInboundParser: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Bytes pendientes de completar un mensaje.
    public var pendingByteCount: Int { buffer.count }

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [OBCInboundMessage] {
        buffer.append(contentsOf: bytes)
        var messages: [OBCInboundMessage] = []
        while let (message, length) = Self.nextMessage(in: buffer) {
            messages.append(message)
            buffer.removeFirst(length)
        }
        return messages
    }

    /// Primer mensaje completo del buffer y cuántos bytes ocupa; `nil` si falta por llegar.
    private static func nextMessage(in b: [UInt8]) -> (OBCInboundMessage, Int)? {
        guard let type = b.first else { return nil }
        switch type {
        case OpenBikeControl.MessageType.haptic:
            guard b.count >= 4 else { return nil }
            return (.haptic(pattern: b[1], duration: b[2], intensity: b[3]), 4)

        case OpenBikeControl.MessageType.appInfo:
            // [0x04][versión][lenID][ID…][lenVer][Ver…][nBotones][botones…]
            guard b.count >= 3 else { return nil }
            let idLength = Int(b[2])
            let versionLengthIndex = 3 + idLength
            guard b.count > versionLengthIndex else { return nil }
            let versionLength = Int(b[versionLengthIndex])
            let countIndex = versionLengthIndex + 1 + versionLength
            guard b.count > countIndex else { return nil }
            let buttonCount = Int(b[countIndex])
            let total = countIndex + 1 + buttonCount
            guard b.count >= total else { return nil }

            let info = OBCAppInfo(
                formatVersion: b[1],
                appID: String(decoding: b[3..<versionLengthIndex], as: UTF8.self),
                appVersion: String(decoding: b[(versionLengthIndex + 1)..<countIndex], as: UTF8.self),
                supportedButtons: Array(b[(countIndex + 1)..<total])
            )
            return (.appInfo(info), total)

        default:
            return (.unknown(type), 1)
        }
    }
}
