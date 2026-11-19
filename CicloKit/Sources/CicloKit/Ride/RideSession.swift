/// Lo que llevas de entrenamiento: distancia, tiempo en movimiento y potencia.
///
/// Se alimenta con muestras periódicas (velocidad, potencia, cadencia) y un reloj
/// monótono en segundos. Solo cuenta el tiempo en el que te mueves.
public struct RideSession: Equatable, Sendable {
    public private(set) var distanceMeters = 0.0
    public private(set) var movingSeconds = 0.0
    public private(set) var energyJoules = 0.0
    public private(set) var maxPowerWatts = 0

    /// Huecos más largos que esto (pausa, desconexión) no se integran.
    public static let maxGapSeconds = 3.0

    private var lastTime: Double?

    public init() {}

    public mutating func update(speedKmh: Double, powerWatts: Int, cadenceRpm: Double, at time: Double) {
        defer { lastTime = time }
        guard let last = lastTime else { return }
        let dt = time - last
        guard dt > 0, dt <= Self.maxGapSeconds else { return }

        let moving = speedKmh > 0.5 || powerWatts > 0 || cadenceRpm > 0
        guard moving else { return }
        movingSeconds += dt
        distanceMeters += max(speedKmh, 0) / 3.6 * dt
        energyJoules += Double(max(powerWatts, 0)) * dt
        maxPowerWatts = max(maxPowerWatts, powerWatts)
    }

    /// Al pausar, la siguiente muestra empieza de cero (no se cuenta el rato parado).
    public mutating func pause() {
        lastTime = nil
    }

    public var averagePowerWatts: Int? {
        movingSeconds > 0 ? Int((energyJoules / movingSeconds).rounded()) : nil
    }

    /// Kilojulios de trabajo (≈ kcal quemadas, con una eficiencia típica del 24 %).
    public var workKilojoules: Int { Int((energyJoules / 1000).rounded()) }
}
