/// Datos en vivo del rodillo (característica Indoor Bike Data, 0x2AD2).
///
/// El mensaje empieza por 16 bits de «flags» que dicen qué campos vienen detrás.
/// Ojo: el bit 0 va al revés: a 0 significa que **sí** viene la velocidad.
/// Un rodillo puede repartir los datos en varios mensajes; usa `merging(_:)`
/// para acumularlos.
public struct IndoorBikeData: Equatable, Sendable {
    public var speedKmh: Double?
    public var averageSpeedKmh: Double?
    public var cadenceRpm: Double?
    public var averageCadenceRpm: Double?
    public var totalDistanceMeters: Int?
    public var resistanceLevel: Int?
    public var powerWatts: Int?
    public var averagePowerWatts: Int?
    public var totalEnergyKcal: Int?
    public var heartRateBpm: Int?
    public var elapsedTimeSeconds: Int?
    public var remainingTimeSeconds: Int?

    public init() {}

    public init(parsing data: some Sequence<UInt8>) throws {
        var r = ByteReader(data)
        let flags = try r.uint16()
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }

        if !has(0) { speedKmh = Double(try r.uint16()) / 100 }
        if has(1) { averageSpeedKmh = Double(try r.uint16()) / 100 }
        if has(2) { cadenceRpm = Double(try r.uint16()) / 2 }
        if has(3) { averageCadenceRpm = Double(try r.uint16()) / 2 }
        if has(4) { totalDistanceMeters = Int(try r.uint24()) }
        if has(5) { resistanceLevel = Int(try r.int16()) }
        if has(6) { powerWatts = Int(try r.int16()) }
        if has(7) { averagePowerWatts = Int(try r.int16()) }
        if has(8) {
            let total = try r.uint16()
            try r.skip(3) // energía por hora (2) y por minuto (1)
            if total != 0xFFFF { totalEnergyKcal = Int(total) }
        }
        if has(9) { heartRateBpm = Int(try r.uint8()) }
        if has(10) { try r.skip(1) } // equivalente metabólico
        if has(11) { elapsedTimeSeconds = Int(try r.uint16()) }
        if has(12) { remainingTimeSeconds = Int(try r.uint16()) }
    }

    /// Combina con un mensaje más nuevo: los campos que traiga `newer` sustituyen a los actuales.
    public func merging(_ newer: IndoorBikeData) -> IndoorBikeData {
        var m = self
        m.speedKmh = newer.speedKmh ?? speedKmh
        m.averageSpeedKmh = newer.averageSpeedKmh ?? averageSpeedKmh
        m.cadenceRpm = newer.cadenceRpm ?? cadenceRpm
        m.averageCadenceRpm = newer.averageCadenceRpm ?? averageCadenceRpm
        m.totalDistanceMeters = newer.totalDistanceMeters ?? totalDistanceMeters
        m.resistanceLevel = newer.resistanceLevel ?? resistanceLevel
        m.powerWatts = newer.powerWatts ?? powerWatts
        m.averagePowerWatts = newer.averagePowerWatts ?? averagePowerWatts
        m.totalEnergyKcal = newer.totalEnergyKcal ?? totalEnergyKcal
        m.heartRateBpm = newer.heartRateBpm ?? heartRateBpm
        m.elapsedTimeSeconds = newer.elapsedTimeSeconds ?? elapsedTimeSeconds
        m.remainingTimeSeconds = newer.remainingTimeSeconds ?? remainingTimeSeconds
        return m
    }
}
