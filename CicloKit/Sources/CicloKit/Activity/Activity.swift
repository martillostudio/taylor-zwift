import Foundation

/// Una muestra por segundo de una actividad.
public struct ActivitySample: Codable, Equatable, Sendable {
    /// Segundos desde el inicio (reloj real: las pausas dejan huecos).
    public var t: Double
    public var power: Int?
    public var cadence: Int?
    /// km/h (en ruta y libre, la velocidad virtual con la marcha).
    public var speedKmh: Double?
    /// Metros acumulados.
    public var distance: Double
    public var heartRate: Int?
    /// Altura virtual (m), en ruta y en libre.
    public var elevation: Double?

    public init(t: Double, power: Int? = nil, cadence: Int? = nil, speedKmh: Double? = nil,
                distance: Double, heartRate: Int? = nil, elevation: Double? = nil) {
        self.t = t
        self.power = power
        self.cadence = cadence
        self.speedKmh = speedKmh
        self.distance = distance
        self.heartRate = heartRate
        self.elevation = elevation
    }
}

/// Un entreno guardado: lo que se graba, se ve en el historial y se sube a Strava.
public struct Activity: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Date
    public var name: String
    /// «Libre», «Ruta», «ERG» o «Entreno».
    public var kind: String
    public var workoutID: String?
    /// FTP que tenías al hacerla (para IF y TSS).
    public var ftp: Int
    public var samples: [ActivitySample]
    /// Id de la actividad en Strava, cuando se ha subido.
    public var stravaActivityID: Int64?
    /// Id de la actividad en intervals.icu («i12345678»), cuando se ha subido.
    public var intervalsActivityID: String?

    public init(id: UUID = UUID(), start: Date, name: String, kind: String, workoutID: String? = nil,
                ftp: Int, samples: [ActivitySample] = [], stravaActivityID: Int64? = nil) {
        self.id = id
        self.start = start
        self.name = name
        self.kind = kind
        self.workoutID = workoutID
        self.ftp = ftp
        self.samples = samples
        self.stravaActivityID = stravaActivityID
    }

    // MARK: Métricas

    /// Tiempo de reloj desde el inicio hasta la última muestra.
    public var elapsedSeconds: Double { (samples.last?.t ?? 0) + (samples.isEmpty ? 0 : 1) }
    /// Tiempo grabado (una muestra = 1 s).
    public var timerSeconds: Double { Double(samples.count) }
    public var distanceMeters: Double { samples.last?.distance ?? 0 }

    public var averagePower: Int? { Self.average(samples.compactMap(\.power)) }
    public var maxPower: Int? { samples.compactMap(\.power).max() }
    public var averageHeartRate: Int? { Self.average(samples.compactMap(\.heartRate).filter { $0 > 0 }) }
    public var maxHeartRate: Int? { samples.compactMap(\.heartRate).max() }
    /// Cadencia media pedaleando (sin contar los ceros).
    public var averageCadence: Int? { Self.average(samples.compactMap(\.cadence).filter { $0 > 0 }) }
    public var averageSpeedKmh: Double? {
        timerSeconds > 0 ? distanceMeters / timerSeconds * 3.6 : nil
    }

    /// Potencia normalizada (NP): media de 30 s, a la cuarta, media y raíz cuarta.
    public var normalizedPower: Int? {
        let p = samples.map { Double($0.power ?? 0) }
        guard p.count >= 30 else { return averagePower }
        return Int(Workout.normalized(p).rounded())
    }

    public var intensityFactor: Double? {
        guard let np = normalizedPower, ftp > 0 else { return nil }
        return Double(np) / Double(ftp)
    }

    /// TSS = horas × IF² × 100.
    public var tss: Int? {
        guard let ifactor = intensityFactor else { return nil }
        return Int((timerSeconds / 3600 * ifactor * ifactor * 100).rounded())
    }

    /// Kilojulios de trabajo.
    public var workKilojoules: Int { Int((Double(samples.compactMap(\.power).reduce(0, +)) / 1000).rounded()) }

    /// Desnivel positivo virtual (m).
    public var ascentMeters: Double {
        var total = 0.0
        var last: Double?
        for e in samples.compactMap(\.elevation) {
            if let l = last, e > l { total += e - l }
            last = e
        }
        return total
    }

    public var powerHistory: PowerHistory { PowerHistory(samples: samples.map { $0.power ?? 0 }) }

    private static func average(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }
}
