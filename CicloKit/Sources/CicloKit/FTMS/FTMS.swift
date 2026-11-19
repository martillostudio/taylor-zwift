import Foundation

/// Identificadores Bluetooth del servicio Fitness Machine (FTMS).
/// Se guardan como texto para no depender de CoreBluetooth aquí.
public enum FTMSUUID {
    public static let service = "1826"
    public static let feature = "2ACC"
    public static let indoorBikeData = "2AD2"
    public static let controlPoint = "2AD9"
    public static let machineStatus = "2ADA"
}

/// Parámetros del modo simulación (SIM): el rodillo calcula la resistencia
/// a partir de la pendiente, el viento y el rozamiento.
public struct SimulationParameters: Equatable, Sendable {
    /// Viento en m/s (positivo = de cara).
    public var windSpeedMps: Double
    /// Pendiente en %.
    public var gradePercent: Double
    /// Coeficiente de rodadura.
    public var crr: Double
    /// Coeficiente de resistencia del viento (CdA·ρ/2) en kg/m.
    public var windResistanceKgPerM: Double

    public init(
        windSpeedMps: Double = 0,
        gradePercent: Double,
        crr: Double = 0.004,
        windResistanceKgPerM: Double = 0.51
    ) {
        self.windSpeedMps = windSpeedMps
        self.gradePercent = gradePercent
        self.crr = crr
        self.windResistanceKgPerM = windResistanceKgPerM
    }

    /// Bytes tal como van en el comando 0x11 y en el estado 0x12.
    var encoded: [UInt8] {
        Int16(clamping: windSpeedMps * 1000).littleEndianBytes
            + Int16(clamping: gradePercent * 100).littleEndianBytes
            + [UInt8(clamping: crr * 10_000), UInt8(clamping: windResistanceKgPerM * 100)]
    }

    init(reading r: inout ByteReader) throws {
        windSpeedMps = Double(try r.int16()) / 1000
        gradePercent = Double(try r.int16()) / 100
        crr = Double(try r.uint8()) / 10_000
        windResistanceKgPerM = Double(try r.uint8()) / 100
    }
}

/// Comandos que escribimos en el Control Point (0x2AD9).
public enum FTMSCommand: Equatable, Sendable {
    /// Pedir control del rodillo. Obligatorio antes de cualquier otro comando.
    case requestControl
    case reset
    case startOrResume
    /// Modo ERG: el rodillo mantiene esta potencia.
    case setTargetPower(watts: Int)
    /// Modo SIM.
    case setSimulation(SimulationParameters)

    public var opcode: UInt8 {
        switch self {
        case .requestControl: 0x00
        case .reset: 0x01
        case .startOrResume: 0x07
        case .setTargetPower: 0x05
        case .setSimulation: 0x11
        }
    }

    public var bytes: [UInt8] {
        switch self {
        case .requestControl, .reset, .startOrResume:
            [opcode]
        case .setTargetPower(let watts):
            [opcode] + Int16(clamping: Double(watts)).littleEndianBytes
        case .setSimulation(let params):
            [opcode] + params.encoded
        }
    }

    /// Nombre legible de un opcode, para los logs.
    public static func name(ofOpcode opcode: UInt8) -> String {
        switch opcode {
        case 0x00: "pedir control"
        case 0x01: "reset"
        case 0x05: "potencia objetivo (ERG)"
        case 0x07: "iniciar"
        case 0x11: "simulación (SIM)"
        default: String(format: "opcode 0x%02X", opcode)
        }
    }
}

/// Respuesta del rodillo a un comando (indicación del Control Point).
public struct ControlPointResponse: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        case success
        case notSupported
        case invalidParameter
        case operationFailed
        case controlNotPermitted
        case unknown(UInt8)

        init(code: UInt8) {
            switch code {
            case 0x01: self = .success
            case 0x02: self = .notSupported
            case 0x03: self = .invalidParameter
            case 0x04: self = .operationFailed
            case 0x05: self = .controlNotPermitted
            default: self = .unknown(code)
            }
        }

        public var description: String {
            switch self {
            case .success: "OK"
            case .notSupported: "no soportado"
            case .invalidParameter: "parámetro no válido"
            case .operationFailed: "la operación falló"
            case .controlNotPermitted: "control no permitido (¿hay otra app conectada al rodillo?)"
            case .unknown(let code): String(format: "código desconocido 0x%02X", code)
            }
        }
    }

    public static let responseOpcode: UInt8 = 0x80

    public let requestOpcode: UInt8
    public let result: Result

    public init(parsing data: some Sequence<UInt8>) throws {
        var r = ByteReader(data)
        guard r.remaining > 0 else { throw ParseError.empty }
        let op = try r.uint8()
        guard op == Self.responseOpcode else { throw ParseError.unexpectedOpcode(op) }
        requestOpcode = try r.uint8()
        result = Result(code: try r.uint8())
    }
}

/// Avisos del rodillo (Machine Status, 0x2ADA).
public enum MachineStatus: Equatable, Sendable {
    case reset
    case stoppedOrPaused
    case started
    case targetPowerChanged(watts: Int)
    case simulationParametersChanged(SimulationParameters)
    case controlPermissionLost
    case other(opcode: UInt8, payload: [UInt8])

    public init(parsing data: some Sequence<UInt8>) throws {
        var r = ByteReader(data)
        guard r.remaining > 0 else { throw ParseError.empty }
        let op = try r.uint8()
        switch op {
        case 0x01: self = .reset
        case 0x02: self = .stoppedOrPaused
        case 0x04: self = .started
        case 0x08: self = .targetPowerChanged(watts: Int(try r.int16()))
        case 0x12: self = .simulationParametersChanged(try SimulationParameters(reading: &r))
        case 0xFF: self = .controlPermissionLost
        default: self = .other(opcode: op, payload: r.rest)
        }
    }

    public var description: String {
        switch self {
        case .reset: "reset"
        case .stoppedOrPaused: "parado / en pausa"
        case .started: "iniciado"
        case .targetPowerChanged(let w): "potencia objetivo → \(w) W"
        case .simulationParametersChanged(let p):
            "simulación → pendiente \(p.gradePercent.formatted(.number.precision(.fractionLength(1)))) %"
        case .controlPermissionLost: "hemos perdido el control del rodillo"
        case .other(let op, let payload):
            String(format: "estado 0x%02X ", op) + payload.hexString
        }
    }
}
