import Foundation

/// Un ciclista y un rodillo de mentira, para probar la app sin el Kickr ni el pulsómetro.
///
/// - **ERG**: los vatios van al objetivo en un par de segundos y la cadencia ronda las 88 rpm.
/// - **SIM**: el ciclista empuja un esfuerzo fijo (`effort` × FTP, un poco más en las subidas) y la
///   cadencia sale de la física del rodillo con los parámetros recibidos (pendiente·k, Crr·k, CdA·k³):
///   una marcha más dura baja la cadencia, como en la realidad.
/// - **Se cansa**: lleva la cuenta de W′ (Skiba). Si se vacía, deja de pedalear 20 s (así el test de
///   rampa acaba solo, más o menos en el 135 % del FTP, y estima un FTP parecido al tuyo).
/// - **Pulso**: sigue a la potencia con retraso (≈ 30 s al subir, 45 s al bajar) y deriva un poco con el tiempo.
public struct DemoRider: Sendable {
    /// FTP del ciclista simulado (el de tu perfil).
    public var ftp: Double
    /// Esfuerzo en modo SIM, en fracción del FTP.
    public var effort: Double
    public var restingHeartRate = 55.0
    public var maxHeartRate = 185.0
    /// Lo que avanza el volante por pedalada, medido en el Kickr Core 2.
    public var trainerKmhPerRpm = 0.356
    /// Masa que supone el rodillo para la pendiente (ciclista + bici).
    public var systemMassKg = 80.0
    /// Reserva anaeróbica (J).
    public var wPrime = 7_000.0

    public private(set) var powerWatts = 0.0
    public private(set) var cadenceRpm = 0.0
    public private(set) var heartRate: Double
    public private(set) var wPrimeBalance: Double
    /// Segundos que le quedan parado tras vaciarse.
    public private(set) var exhaustedSeconds = 0.0
    public private(set) var elapsedSeconds = 0.0

    private var noiseState: UInt64

    public init(ftp: Double, effort: Double = 0.65, seed: UInt64 = 0x5EED) {
        self.ftp = ftp
        self.effort = effort
        heartRate = restingHeartRate
        wPrimeBalance = wPrime
        noiseState = seed == 0 ? 1 : seed
    }

    /// Avanza `dt` segundos con lo último que le hemos mandado al rodillo.
    @discardableResult
    public mutating func step(target: TrainerTarget?, dt: Double) -> IndoorBikeData {
        guard dt > 0 else { return bikeData }
        elapsedSeconds += dt

        if exhaustedSeconds > 0 {
            exhaustedSeconds = max(exhaustedSeconds - dt, 0)
            powerWatts = 0
            cadenceRpm = 0
        } else {
            switch target {
            case .targetPower(let watts):
                let w = Double(watts)
                powerWatts = approach(powerWatts, w, tau: 2, dt: dt) + noise(3)
                cadenceRpm = 88 + noise(2)
            case .simulation(let p):
                let wanted = simPower(gradePercent: p.gradePercent)
                let smooth = approach(powerWatts, wanted, tau: 1.5, dt: dt)
                (powerWatts, cadenceRpm) = solveCadence(power: smooth, params: p)
                powerWatts += noise(3)
                cadenceRpm += noise(1)
            case nil:
                // Sin órdenes, el rodillo está en «libre»: pedalea suave.
                powerWatts = approach(powerWatts, 0.5 * ftp, tau: 2, dt: dt) + noise(3)
                cadenceRpm = 85 + noise(2)
            }
            powerWatts = max(powerWatts, 0)
            cadenceRpm = max(cadenceRpm, 0)
        }

        updateWPrime(dt: dt)
        updateHeartRate(dt: dt)
        return bikeData
    }

    public var bikeData: IndoorBikeData {
        var d = IndoorBikeData()
        d.powerWatts = Int(powerWatts.rounded())
        d.cadenceRpm = (cadenceRpm * 2).rounded() / 2 // FTMS: medias rpm
        d.speedKmh = ((cadenceRpm * trainerKmhPerRpm) * 100).rounded() / 100
        return d
    }

    public var heartRateBpm: Int { Int(heartRate.rounded()) }

    // MARK: Interno

    /// Lo que quiere empujar en SIM: su esfuerzo, algo más en las subidas y menos en las bajadas.
    func simPower(gradePercent: Double) -> Double {
        let g = min(max(gradePercent, -6), 10)
        return max(ftp * effort * (1 + 0.04 * g), 0.25 * ftp)
    }

    /// Cadencia a la que esa potencia mueve el volante con esos parámetros (entre 45 y 115 rpm;
    /// fuera de ahí la potencia es la que toque: atrancado o «molinillo»).
    func solveCadence(power: Double, params p: SimulationParameters) -> (power: Double, cadence: Double) {
        func powerAt(rpm: Double) -> Double {
            let v = rpm * trainerKmhPerRpm / 3.6
            let force = systemMassKg * 9.81 * (p.gradePercent / 100 + p.crr) + p.windResistanceKgPerM * v * v
            return force * v
        }
        let lo = 45.0, hi = 115.0
        if powerAt(rpm: lo) >= power { return (powerAt(rpm: lo), lo) }
        if powerAt(rpm: hi) <= power { return (max(powerAt(rpm: hi), 0), hi) }
        var a = lo, b = hi
        for _ in 0..<40 {
            let m = (a + b) / 2
            if powerAt(rpm: m) < power { a = m } else { b = m }
        }
        return (power, (a + b) / 2)
    }

    private mutating func updateWPrime(dt: Double) {
        if powerWatts > ftp {
            wPrimeBalance -= (powerWatts - ftp) * dt
        } else {
            // Recuperación (Skiba): más rápida cuanto más por debajo del FTP.
            let under = ftp - powerWatts
            let tau = 546 * exp(-0.01 * under) + 316
            wPrimeBalance += (wPrime - wPrimeBalance) * (1 - exp(-dt / tau))
        }
        if wPrimeBalance <= 0 {
            wPrimeBalance = 0.15 * wPrime
            exhaustedSeconds = 20
            powerWatts = 0
            cadenceRpm = 0
        }
    }

    private mutating func updateHeartRate(dt: Double) {
        let threshold = 0.91 * maxHeartRate // pulso en el umbral
        let drift = min(elapsedSeconds / 3_600 * 6, 10) // ~6 ppm por hora
        let fatigue = (1 - wPrimeBalance / wPrime) * 0.06 * maxHeartRate
        var steady = restingHeartRate + (threshold - restingHeartRate) * (powerWatts / ftp) + drift + fatigue
        if powerWatts == 0 { steady = restingHeartRate + 15 }
        steady = min(steady, maxHeartRate)
        heartRate = approach(heartRate, steady, tau: steady > heartRate ? 30 : 45, dt: dt)
    }

    private func approach(_ value: Double, _ target: Double, tau: Double, dt: Double) -> Double {
        value + (target - value) * (1 - exp(-dt / tau))
    }

    /// Ruido uniforme en ±amplitude (xorshift: repetible en los tests).
    private mutating func noise(_ amplitude: Double) -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 7
        noiseState ^= noiseState << 17
        return (Double(noiseState % 10_000) / 10_000 * 2 - 1) * amplitude
    }
}
