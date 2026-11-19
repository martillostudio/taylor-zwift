/// Identificadores Bluetooth de los mandos Zwift Click V2 (y Zwift Ride).
public enum ZwiftClickUUID {
    public static let service = "FC82"
    /// Notificaciones asíncronas: aquí llegan los botones.
    public static let async = "00000002-19CA-4651-86E5-FA29DCDD09D1"
    /// Escritura: aquí mandamos el saludo «RideOn».
    public static let syncRX = "00000003-19CA-4651-86E5-FA29DCDD09D1"
    /// Respuestas del mando al saludo.
    public static let syncTX = "00000004-19CA-4651-86E5-FA29DCDD09D1"
}

public enum ZwiftClickProtocol {
    /// Saludo inicial: el texto «RideOn» en ASCII.
    public static let rideOn: [UInt8] = Array("RideOn".utf8)
    /// Opcode de los mensajes con el estado de los botones.
    public static let buttonStatusOpcode: UInt8 = 0x23
    /// Opcode del nivel de batería (protobuf, campo 2 = porcentaje). Llega cada ~5 s.
    public static let batteryOpcode: UInt8 = 0x19
}

/// Botones de los mandos Zwift (mapa de bits del protocolo de Zwift Ride).
/// En el mensaje, un bit a **0** significa pulsado.
public struct ZwiftButton: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let left = ZwiftButton(rawValue: 1 << 0)
    public static let up = ZwiftButton(rawValue: 1 << 1)
    public static let right = ZwiftButton(rawValue: 1 << 2)
    public static let down = ZwiftButton(rawValue: 1 << 3)
    public static let a = ZwiftButton(rawValue: 1 << 4)
    public static let b = ZwiftButton(rawValue: 1 << 5)
    public static let y = ZwiftButton(rawValue: 1 << 6)
    public static let z = ZwiftButton(rawValue: 1 << 7)
    public static let shiftUpLeft = ZwiftButton(rawValue: 1 << 8)
    public static let shiftDownLeft = ZwiftButton(rawValue: 1 << 9)
    public static let powerUpLeft = ZwiftButton(rawValue: 1 << 10)
    public static let onOffLeft = ZwiftButton(rawValue: 1 << 11)
    public static let shiftUpRight = ZwiftButton(rawValue: 1 << 12)
    public static let shiftDownRight = ZwiftButton(rawValue: 1 << 13)
    public static let powerUpRight = ZwiftButton(rawValue: 1 << 14)
    public static let onOffRight = ZwiftButton(rawValue: 1 << 15)

    public static let all: ZwiftButton = [
        .left, .up, .right, .down, .a, .b, .y, .z,
        .shiftUpLeft, .shiftDownLeft, .powerUpLeft, .onOffLeft,
        .shiftUpRight, .shiftDownRight, .powerUpRight, .onOffRight,
    ]

    private static let names: [(ZwiftButton, String)] = [
        (.left, "←"), (.up, "↑"), (.right, "→"), (.down, "↓"),
        (.a, "A"), (.b, "B"), (.y, "Y"), (.z, "Z"),
        (.shiftUpLeft, "marcha+ izq"), (.shiftDownLeft, "marcha− izq"),
        (.powerUpLeft, "power-up izq"), (.onOffLeft, "on/off izq"),
        (.shiftUpRight, "marcha+ dcha"), (.shiftDownRight, "marcha− dcha"),
        (.powerUpRight, "power-up dcha"), (.onOffRight, "on/off dcha"),
    ]

    /// Nombres legibles de los botones incluidos, en orden fijo.
    public var names: [String] {
        Self.names.filter { contains($0.0) }.map(\.1)
    }
}

/// Mensaje recibido de un mando Zwift.
public enum ZwiftClickMessage: Equatable, Sendable {
    /// Estado de los botones. `pressed` ya viene invertido (lo pulsado = incluido).
    case buttons(pressed: ZwiftButton, rawMap: UInt32)
    /// El mando responde a nuestro «RideOn».
    case rideOnAck(extra: [UInt8])
    /// Nivel de batería en porcentaje (0–100).
    case battery(percent: Int)
    /// Cualquier otra cosa: se muestra en el log.
    case other(opcode: UInt8, payload: [UInt8])

    public init(parsing data: some Sequence<UInt8>) throws {
        let bytes = Array(data)
        guard let opcode = bytes.first else { throw ParseError.empty }

        if bytes.starts(with: ZwiftClickProtocol.rideOn) {
            self = .rideOnAck(extra: Array(bytes.dropFirst(ZwiftClickProtocol.rideOn.count)))
            return
        }

        let fields = try Self.varintFields(inProtobuf: bytes.dropFirst())

        if opcode == ZwiftClickProtocol.buttonStatusOpcode, let value = fields[1] {
            let map = UInt32(truncatingIfNeeded: value)
            let pressed = ZwiftButton(rawValue: ~map & ZwiftButton.all.rawValue)
            self = .buttons(pressed: pressed, rawMap: map)
        } else if opcode == ZwiftClickProtocol.batteryOpcode, let value = fields[2], value <= 100 {
            self = .battery(percent: Int(value))
        } else {
            self = .other(opcode: opcode, payload: Array(bytes.dropFirst()))
        }
    }

    /// Lee los campos varint de primer nivel de un mensaje protobuf (número de campo → valor).
    /// Si encuentra algo que no entiende, devuelve lo leído hasta ahí.
    private static func varintFields(inProtobuf bytes: some Sequence<UInt8>) throws -> [UInt64: UInt64] {
        var r = ByteReader(bytes)
        var fields: [UInt64: UInt64] = [:]
        do {
            while r.remaining > 0 {
                let tag = try r.varint()
                let field = tag >> 3
                switch tag & 0x7 {
                case 0: fields[field] = try r.varint()
                case 1: try r.skip(8)
                case 2: try r.skip(Int(try r.varint()))
                case 5: try r.skip(4)
                default: return fields // tipo desconocido: paramos con lo que tengamos
                }
            }
        } catch {
            // Mensajes que no son protobuf (p. ej. opcode 0xFF): nos quedamos con lo leído.
        }
        return fields
    }
}
