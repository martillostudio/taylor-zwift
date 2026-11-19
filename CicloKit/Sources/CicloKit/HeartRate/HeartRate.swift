/// Pulsómetros Bluetooth estándar (servicio Heart Rate, 0x180D).
public enum HeartRateUUID {
    public static let service = "180D"
    /// Heart Rate Measurement (notify).
    public static let measurement = "2A37"
}

/// Una medida del pulsómetro (característica 0x2A37).
///
/// El primer byte son «flags»: el bit 0 dice si las pulsaciones vienen en 1 byte (0)
/// o en 2 (1). Lo demás (energía, intervalos RR, contacto con la piel) no lo usamos aún.
public struct HeartRateMeasurement: Equatable, Sendable {
    public var bpm: Int
    /// `false` si el pulsómetro dice que no está en contacto con la piel.
    public var skinContact: Bool?

    public init(parsing data: some Sequence<UInt8>) throws {
        var r = ByteReader(data)
        guard r.remaining > 0 else { throw ParseError.empty }
        let flags = try r.uint8()
        if flags & 0x01 == 0 {
            bpm = Int(try r.uint8())
        } else {
            bpm = Int(try r.uint16())
        }
        // Bits 1-2: 0b11 = hay sensor de contacto y hay contacto; 0b10 = hay sensor, sin contacto.
        switch (flags >> 1) & 0b11 {
        case 0b11: skinContact = true
        case 0b10: skinContact = false
        default: skinContact = nil
        }
    }
}
