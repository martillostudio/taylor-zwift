import Foundation

/// Error al interpretar un mensaje Bluetooth.
public enum ParseError: Error, Equatable, Sendable {
    /// Faltan bytes: se necesitaban `needed` a partir de `offset`.
    case truncated(needed: Int, offset: Int)
    /// El mensaje no empieza por el código esperado.
    case unexpectedOpcode(UInt8)
    /// Mensaje vacío.
    case empty
}

/// Lector secuencial de bytes little-endian (el orden que usa Bluetooth LE).
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: some Sequence<UInt8>) {
        bytes = Array(data)
    }

    var remaining: Int { bytes.count - offset }
    var rest: [UInt8] { Array(bytes[offset...]) }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= count else {
            throw ParseError.truncated(needed: count, offset: offset)
        }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func skip(_ count: Int) throws {
        _ = try take(count)
    }

    mutating func uint8() throws -> UInt8 {
        try take(1).first!
    }

    mutating func uint16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func int16() throws -> Int16 {
        Int16(bitPattern: try uint16())
    }

    mutating func uint24() throws -> UInt32 {
        let b = try take(3)
        return UInt32(b[b.startIndex])
            | UInt32(b[b.startIndex + 1]) << 8
            | UInt32(b[b.startIndex + 2]) << 16
    }

    /// Entero «varint» de protobuf (7 bits por byte, el bit alto indica que sigue).
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try uint8()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { throw ParseError.truncated(needed: 1, offset: offset) }
        }
    }
}

extension Int16 {
    /// Redondea y recorta al rango de Int16 (para codificar comandos).
    init(clamping value: Double) {
        let rounded = value.rounded()
        if rounded >= Double(Int16.max) { self = .max }
        else if rounded <= Double(Int16.min) { self = .min }
        else { self = Int16(rounded) }
    }
}

extension UInt8 {
    init(clamping value: Double) {
        let rounded = value.rounded()
        if rounded >= 255 { self = 255 }
        else if rounded <= 0 { self = 0 }
        else { self = UInt8(rounded) }
    }
}

extension Int16 {
    var littleEndianBytes: [UInt8] {
        let u = UInt16(bitPattern: self)
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    }
}

extension Sequence<UInt8> {
    /// «0A 1B FF» — útil para los logs.
    public var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
