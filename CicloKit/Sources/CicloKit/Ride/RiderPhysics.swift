import Foundation

/// Física de una bici por carretera: relaciona potencia, velocidad y pendiente.
///
/// Sirve para dar velocidad y una «pendiente equivalente» en los tramos ERG de un entreno,
/// donde el rodillo marca los vatios: si a esa velocidad empujas esos vatios, es como
/// subir (o bajar) a ese porcentaje.
public struct RiderPhysics: Equatable, Sendable {
    /// Ciclista + bici.
    public var massKg: Double
    public var cdA = 0.32
    public var crr = 0.005
    public var airDensity = 1.225
    public var drivetrainEfficiency = 0.975

    static let gravity = 9.81

    public init(riderKg: Double, bikeKg: Double = 9.5) {
        massKg = riderKg + bikeKg
    }

    /// Vatios que hacen falta para ir a `speedKmh` con esa pendiente (sin viento).
    public func power(speedKmh: Double, gradePercent: Double) -> Double {
        let v = max(speedKmh, 0) / 3.6
        let theta = atan(gradePercent / 100)
        let rolling = massKg * Self.gravity * (sin(theta) + crr * cos(theta)) * v
        let air = 0.5 * airDensity * cdA * v * v * v
        return (rolling + air) / drivetrainEfficiency
    }

    /// Pendiente (%) a la que esos vatios te llevan a esa velocidad. `nil` si vas casi parado.
    public func grade(powerWatts: Double, speedKmh: Double, range: ClosedRange<Double> = -15...25) -> Double? {
        guard speedKmh >= 5 else { return nil }
        var lo = range.lowerBound, hi = range.upperBound
        if power(speedKmh: speedKmh, gradePercent: lo) >= powerWatts { return lo }
        if power(speedKmh: speedKmh, gradePercent: hi) <= powerWatts { return hi }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if power(speedKmh: speedKmh, gradePercent: mid) < powerWatts { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Velocidad (km/h) a la que te llevan esos vatios con esa pendiente.
    public func speed(powerWatts: Double, gradePercent: Double) -> Double {
        guard powerWatts > 0 else { return 0 }
        var lo = 0.0, hi = 120.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if power(speedKmh: mid, gradePercent: gradePercent) < powerWatts { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
