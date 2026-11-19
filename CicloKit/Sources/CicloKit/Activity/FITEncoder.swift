import Foundation

/// Escribe una actividad en formato FIT (el de Garmin), que entienden Strava, Garmin Connect,
/// intervals.icu, TrainingPeaks…
///
/// Escribe lo mínimo que piden esos servicios: file_id, event (inicio y fin), un record por
/// segundo (potencia, cadencia, pulso, velocidad, distancia, altura), lap, session y activity.
/// Marca la actividad como ciclismo en interior (sport = cycling, sub_sport = indoor_cycling).
public enum FITEncoder {
    /// 31-dic-1989 00:00 UTC: el «año cero» de las fechas FIT.
    static let fitEpoch: TimeInterval = 631_065_600
    static let profileVersion: UInt16 = 2140

    public static func timestamp(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(max(0, date.timeIntervalSince1970 - fitEpoch)))
    }

    enum BaseType: UInt8 {
        case enumeration = 0x00
        case uint8 = 0x02
        case uint16 = 0x84
        case uint32 = 0x86
        case uint32z = 0x8C

        var size: Int {
            switch self {
            case .enumeration, .uint8: 1
            case .uint16: 2
            case .uint32, .uint32z: 4
            }
        }

        /// Valor que significa «sin dato».
        var invalid: UInt64 {
            switch self {
            case .enumeration, .uint8: 0xFF
            case .uint16: 0xFFFF
            case .uint32: 0xFFFF_FFFF
            case .uint32z: 0
            }
        }

        var max: UInt64 { invalid == 0 ? 0xFFFF_FFFE : invalid - 1 }
    }

    struct Field {
        let number: UInt8
        let type: BaseType
        let value: UInt64?

        init(_ number: UInt8, _ type: BaseType, _ value: UInt64?) {
            self.number = number
            self.type = type
            self.value = value
        }
    }

    struct Writer {
        var bytes: [UInt8] = []
        private var definitions: [UInt8: [UInt16]] = [:]

        mutating func write(local: UInt8, global: UInt16, _ fields: [Field]) {
            let signature = [global] + fields.map { UInt16($0.number) << 8 | UInt16($0.type.rawValue) }
            if definitions[local] != signature {
                definitions[local] = signature
                bytes.append(0x40 | local) // mensaje de definición
                bytes.append(0) // reservado
                bytes.append(0) // little endian
                append(UInt64(global), size: 2)
                bytes.append(UInt8(fields.count))
                for f in fields {
                    bytes.append(f.number)
                    bytes.append(UInt8(f.type.size))
                    bytes.append(f.type.rawValue)
                }
            }
            bytes.append(local) // mensaje de datos
            for f in fields {
                let v = f.value.map { Swift.min($0, f.type.max) } ?? f.type.invalid
                append(v, size: f.type.size)
            }
        }

        private mutating func append(_ value: UInt64, size: Int) {
            for i in 0..<size { bytes.append(UInt8((value >> (8 * UInt64(i))) & 0xFF)) }
        }
    }

    /// CRC de FIT (CRC-16 con la tabla del SDK de Garmin).
    public static func crc(_ data: some Sequence<UInt8>, start: UInt16 = 0) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        var crc = start
        for byte in data {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }

    public static func encode(_ a: Activity, timeZone: TimeZone = .current) -> Data {
        var w = Writer()
        let start = timestamp(a.start)
        let end = start &+ UInt32(a.elapsedSeconds.rounded())
        func ui(_ v: Int?) -> UInt64? { v.flatMap { $0 >= 0 ? UInt64($0) : nil } }
        func ud(_ v: Double?) -> UInt64? { v.flatMap { $0 >= 0 && $0.isFinite ? UInt64($0.rounded()) : nil } }

        // file_id: actividad, fabricante «development» (255).
        w.write(local: 0, global: 0, [
            Field(0, .enumeration, 4), Field(1, .uint16, 255), Field(2, .uint16, 1),
            Field(3, .uint32z, UInt64(UInt32(truncatingIfNeeded: a.id.hashValue) | 1)), Field(4, .uint32, UInt64(start)),
        ])
        // event: arranca el cronómetro.
        w.write(local: 1, global: 21, [Field(253, .uint32, UInt64(start)), Field(0, .enumeration, 0), Field(1, .enumeration, 0)])

        // record: una por segundo.
        for s in a.samples {
            w.write(local: 2, global: 20, [
                Field(253, .uint32, UInt64(start &+ UInt32(max(0, s.t.rounded())))),
                Field(7, .uint16, ui(s.power)),
                Field(4, .uint8, ui(s.cadence)),
                Field(3, .uint8, ui(s.heartRate).flatMap { $0 > 0 ? $0 : nil }),
                Field(5, .uint32, ud(s.distance * 100)),
                Field(6, .uint16, ud(s.speedKmh.map { $0 / 3.6 * 1000 })),
                Field(2, .uint16, ud(s.elevation.map { ($0 + 500) * 5 })),
            ])
        }

        // event: para el cronómetro.
        w.write(local: 1, global: 21, [Field(253, .uint32, UInt64(end)), Field(0, .enumeration, 0), Field(1, .enumeration, 4)])

        let elapsed = ud(a.elapsedSeconds * 1000)
        let timer = ud(a.timerSeconds * 1000)
        let distance = ud(a.distanceMeters * 100)
        let avgSpeed = ud(a.averageSpeedKmh.map { $0 / 3.6 * 1000 })
        let maxSpeed = ud(a.samples.compactMap(\.speedKmh).max().map { $0 / 3.6 * 1000 })

        // lap: una vuelta con todo.
        w.write(local: 3, global: 19, [
            Field(253, .uint32, UInt64(end)), Field(0, .enumeration, 9), Field(1, .enumeration, 1),
            Field(2, .uint32, UInt64(start)), Field(7, .uint32, elapsed), Field(8, .uint32, timer),
            Field(9, .uint32, distance), Field(13, .uint16, avgSpeed), Field(14, .uint16, maxSpeed),
            Field(15, .uint8, ui(a.averageHeartRate)), Field(16, .uint8, ui(a.maxHeartRate)),
            Field(17, .uint8, ui(a.averageCadence)), Field(19, .uint16, ui(a.averagePower)),
            Field(20, .uint16, ui(a.maxPower)), Field(21, .uint16, ud(a.ascentMeters)),
            Field(25, .enumeration, 2), Field(39, .enumeration, 6),
        ])
        // session: ciclismo en interior.
        w.write(local: 4, global: 18, [
            Field(253, .uint32, UInt64(end)), Field(0, .enumeration, 8), Field(1, .enumeration, 1),
            Field(2, .uint32, UInt64(start)), Field(5, .enumeration, 2), Field(6, .enumeration, 6),
            Field(7, .uint32, elapsed), Field(8, .uint32, timer), Field(9, .uint32, distance),
            Field(11, .uint16, ui(a.workKilojoules)), Field(14, .uint16, avgSpeed), Field(15, .uint16, maxSpeed),
            Field(16, .uint8, ui(a.averageHeartRate)), Field(17, .uint8, ui(a.maxHeartRate)),
            Field(18, .uint8, ui(a.averageCadence)), Field(20, .uint16, ui(a.averagePower)),
            Field(21, .uint16, ui(a.maxPower)), Field(22, .uint16, ud(a.ascentMeters)),
            Field(25, .uint16, 0), Field(26, .uint16, 1),
            Field(34, .uint16, ui(a.normalizedPower)), Field(35, .uint16, ui(a.tss.map { $0 * 10 })),
            Field(36, .uint16, ud(a.intensityFactor.map { $0 * 1000 })), Field(45, .uint16, ui(a.ftp)),
        ])
        // activity.
        let offset = Int64(timeZone.secondsFromGMT(for: a.start))
        w.write(local: 5, global: 34, [
            Field(253, .uint32, UInt64(end)), Field(0, .uint32, timer), Field(1, .uint16, 1),
            Field(2, .enumeration, 0), Field(3, .enumeration, 26), Field(4, .enumeration, 1),
            Field(5, .uint32, UInt64(max(0, Int64(end) + offset))),
        ])

        var header: [UInt8] = [14, 0x20]
        header += [UInt8(profileVersion & 0xFF), UInt8(profileVersion >> 8)]
        let size = UInt32(w.bytes.count)
        header += [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)]
        header += Array(".FIT".utf8)
        let headerCRC = crc(header)
        header += [UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8)]

        let file = header + w.bytes
        let fileCRC = crc(file)
        return Data(file + [UInt8(fileCRC & 0xFF), UInt8(fileCRC >> 8)])
    }
}
