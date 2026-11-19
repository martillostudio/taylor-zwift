import Foundation
import Testing
@testable import CicloKit

/// Lector mínimo de FIT para comprobar lo que escribimos.
private struct FITReader {
    struct Message { let global: UInt16; let fields: [UInt8: UInt64] }
    var messages: [Message] = []
    var headerCRCok = false
    var fileCRCok = false
    var dataSize = 0

    init(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 16, b[0] == 14, Array(b[8..<12]) == Array(".FIT".utf8) else { return }
        headerCRCok = FITEncoder.crc(b[0..<12]) == UInt16(b[12]) | UInt16(b[13]) << 8
        fileCRCok = FITEncoder.crc(b) == 0 // el CRC sobre todo el fichero (CRC incluido) da 0
        dataSize = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        var defs: [UInt8: (UInt16, [(UInt8, Int)])] = [:]
        var i = 14
        let end = 14 + dataSize
        while i < end {
            let header = b[i]; i += 1
            let local = header & 0x0F
            if header & 0x40 != 0 {
                i += 2 // reservado + arquitectura
                let global = UInt16(b[i]) | UInt16(b[i + 1]) << 8; i += 2
                let n = Int(b[i]); i += 1
                var fields: [(UInt8, Int)] = []
                for _ in 0..<n { fields.append((b[i], Int(b[i + 1]))); i += 3 }
                defs[local] = (global, fields)
            } else {
                guard let def = defs[local] else { return }
                let (global, fields) = def
                var values: [UInt8: UInt64] = [:]
                for (num, size) in fields {
                    var v: UInt64 = 0
                    for k in 0..<size { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                    values[num] = v
                    i += size
                }
                messages.append(Message(global: global, fields: values))
            }
        }
    }

    func all(_ global: UInt16) -> [Message] { messages.filter { $0.global == global } }
}

@Suite("Actividades y FIT")
struct ActivityTests {
    /// 10 minutos a 200 W, 90 rpm, 30 km/h y 140 ppm, subiendo 1 m cada 10 s.
    let activity: Activity = {
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let samples = (0..<600).map { i in
            ActivitySample(t: Double(i), power: 200, cadence: 90, speedKmh: 30,
                           distance: Double(i + 1) * 30 / 3.6, heartRate: 140, elevation: Double(i) / 10)
        }
        return Activity(start: start, name: "Prueba", kind: "Libre", ftp: 250, samples: samples)
    }()

    @Test func metricas() {
        let a = activity
        #expect(a.timerSeconds == 600)
        #expect(a.elapsedSeconds == 600)
        #expect(abs(a.distanceMeters - 5_000) < 1e-6)
        #expect(a.averagePower == 200)
        #expect(a.normalizedPower == 200)
        #expect(abs((a.intensityFactor ?? 0) - 0.8) < 1e-9)
        #expect(a.tss == 11) // 1/6 h × 0,64 × 100 = 10,7
        #expect(a.averageHeartRate == 140)
        #expect(a.averageCadence == 90)
        #expect(abs(a.ascentMeters - 59.9) < 1e-6)
        #expect(a.workKilojoules == 120)
        #expect(abs((a.averageSpeedKmh ?? 0) - 30) < 1e-6)
    }

    @Test func seGuardaYSeLeeEnJSON() throws {
        let data = try JSONEncoder().encode(activity)
        let back = try JSONDecoder().decode(Activity.self, from: data)
        #expect(back == activity)
    }

    @Test func crcDeFIT() {
        // Comprobación cruzada: el CRC de un bloque con su propio CRC al final da 0.
        let bytes: [UInt8] = Array("hola, rodillo".utf8)
        let c = FITEncoder.crc(bytes)
        #expect(FITEncoder.crc(bytes + [UInt8(c & 0xFF), UInt8(c >> 8)]) == 0)
    }

    @Test func ficheroFIT() throws {
        let data = FITEncoder.encode(activity, timeZone: TimeZone(identifier: "Europe/Madrid")!)
        let fit = FITReader(data)
        #expect(fit.headerCRCok)
        #expect(fit.fileCRCok)
        #expect(fit.dataSize == data.count - 16)

        #expect(fit.all(0).count == 1) // file_id
        #expect(fit.all(0).first?.fields[0] == 4) // tipo: actividad
        #expect(fit.all(21).count == 2) // inicio y fin
        #expect(fit.all(20).count == 600) // un record por segundo
        #expect(fit.all(19).count == 1) // lap
        #expect(fit.all(18).count == 1) // session
        #expect(fit.all(34).count == 1) // activity

        let first = try #require(fit.all(20).first)
        let start = FITEncoder.timestamp(activity.start)
        #expect(first.fields[253] == UInt64(start))
        #expect(first.fields[7] == 200) // potencia
        #expect(first.fields[4] == 90) // cadencia
        #expect(first.fields[3] == 140) // pulso
        #expect(first.fields[6] == 8_333) // 30 km/h = 8,333 m/s × 1000
        #expect(first.fields[2] == 2_500) // altura 0 m → (0 + 500) × 5

        let session = try #require(fit.all(18).first)
        #expect(session.fields[5] == 2) // ciclismo
        #expect(session.fields[6] == 6) // en interior
        #expect(session.fields[8] == 600_000) // 600 s × 1000
        #expect(session.fields[9] == 500_000) // 5 km × 100
        #expect(session.fields[20] == 200)
        #expect(session.fields[34] == 200) // NP
        #expect(session.fields[45] == 250) // FTP
    }

    @Test func sinDatosSeEscribeComoInvalido() throws {
        let a = Activity(start: Date(), name: "x", kind: "ERG", ftp: 200,
                         samples: [ActivitySample(t: 0, distance: 0)])
        let fit = FITReader(FITEncoder.encode(a))
        #expect(fit.fileCRCok)
        let r = try #require(fit.all(20).first)
        #expect(r.fields[7] == 0xFFFF)
        #expect(r.fields[3] == 0xFF)
    }
}
