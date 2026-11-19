import Foundation

/// Zonas de potencia de Coggan, en fracción de FTP.
public enum PowerZone: Int, CaseIterable, Comparable, Sendable {
    case z1 = 1, z2, z3, z4, z5, z6, z7

    /// Fracción de FTP (1.0 = 100 %).
    public init(fractionOfFTP f: Double) {
        switch f {
        case ..<0.56: self = .z1
        case ..<0.76: self = .z2
        case ..<0.91: self = .z3
        case ..<1.06: self = .z4
        case ..<1.21: self = .z5
        case ..<1.51: self = .z6
        default: self = .z7
        }
    }

    public var name: String {
        switch self {
        case .z1: "Recuperación"
        case .z2: "Resistencia"
        case .z3: "Tempo"
        case .z4: "Umbral"
        case .z5: "VO2max"
        case .z6: "Anaeróbico"
        case .z7: "Neuromuscular"
        }
    }

    /// Límites en fracción de FTP (el superior de Z7 es abierto).
    public var range: (low: Double, high: Double?) {
        switch self {
        case .z1: (0, 0.55)
        case .z2: (0.56, 0.75)
        case .z3: (0.76, 0.90)
        case .z4: (0.91, 1.05)
        case .z5: (1.06, 1.20)
        case .z6: (1.21, 1.50)
        case .z7: (1.51, nil)
        }
    }

    public static func < (a: PowerZone, b: PowerZone) -> Bool { a.rawValue < b.rawValue }
}

/// Paso de un entrenamiento tal como se escribe (potencias en fracción de FTP).
public enum WorkoutStep: Equatable, Sendable {
    case steady(seconds: Int, power: Double)
    case ramp(seconds: Int, from: Double, to: Double)
    case intervals(repeats: Int, onSeconds: Int, onPower: Double, offSeconds: Int, offPower: Double)
    /// Sin objetivo de potencia: el rodillo va en llano y tú decides (tests, sprints…).
    case freeRide(seconds: Int)
}

/// Un tramo del entrenamiento ya desplegado en el tiempo.
public struct WorkoutSegment: Identifiable, Equatable, Sendable {
    public var id: Int
    public var startSeconds: Int
    public var durationSeconds: Int
    /// Fracción de FTP al principio y al final (iguales salvo en rampas). `nil` = libre.
    public var startPower: Double?
    public var endPower: Double?

    public var endSeconds: Int { startSeconds + durationSeconds }
    public var isFree: Bool { startPower == nil }
    public var isRamp: Bool { startPower != endPower }

    /// Objetivo (fracción de FTP) a `t` segundos del inicio del entrenamiento.
    public func power(at t: Double) -> Double? {
        guard let a = startPower, let b = endPower else { return nil }
        let x = min(max((t - Double(startSeconds)) / Double(max(durationSeconds, 1)), 0), 1)
        return a + (b - a) * x
    }

    /// Para mostrar: «5' al 90 %», «10' de 45 % a 70 %», «20' libre».
    public var summary: String {
        let d = durationSeconds >= 60 && durationSeconds % 60 == 0 ? "\(durationSeconds / 60)'" : Self.formatSeconds(durationSeconds)
        guard let a = startPower, let b = endPower else { return "\(d) libre" }
        return a == b ? "\(d) al \(Int((a * 100).rounded())) %" : "\(d) de \(Int((a * 100).rounded())) % a \(Int((b * 100).rounded())) %"
    }

    static func formatSeconds(_ s: Int) -> String {
        s >= 60 ? "\(s / 60)'\(String(format: "%02d", s % 60))''" : "\(s)''"
    }
}

/// Test con el que sale una estimación de FTP.
public enum FTPTest: String, Sendable {
    /// Rampa hasta no poder más: FTP ≈ 75 % de la mejor potencia de 1 minuto.
    case ramp
    /// 20 minutos a tope: FTP ≈ 95 % de la potencia media de esos 20 minutos.
    case twentyMinutes

    public func estimate(from history: PowerHistory) -> Int? {
        switch self {
        case .ramp: history.bestAverage(seconds: 60).map { Int(($0 * 0.75).rounded()) }
        case .twentyMinutes: history.bestAverage(seconds: 1_200).map { Int(($0 * 0.95).rounded()) }
        }
    }
}

public enum WorkoutCategory: String, CaseIterable, Sendable {
    case test = "Tests de FTP"
    case recovery = "Recuperación"
    case endurance = "Resistencia (Z2)"
    case tempo = "Tempo"
    case sweetSpot = "Sweet spot"
    case threshold = "Umbral"
    case vo2max = "VO2max"
    case anaerobic = "Anaeróbico"
    case imported = "Importados"
}

/// Entrenamiento estructurado. Las potencias van en fracción de tu FTP.
public struct Workout: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var category: WorkoutCategory
    /// Para qué sirve y cómo hacerlo.
    public var summary: String
    public var steps: [WorkoutStep]
    public var ftpTest: FTPTest?
    public let segments: [WorkoutSegment]
    /// Intensidad (IF) prevista si se hace tal cual. Los tramos libres cuentan como 60 %.
    public let intensityFactor: Double

    public init(id: String, name: String, category: WorkoutCategory, summary: String,
                ftpTest: FTPTest? = nil, steps: [WorkoutStep]) {
        self.id = id
        self.name = name
        self.category = category
        self.summary = summary
        self.ftpTest = ftpTest
        self.steps = steps
        let segments = Self.expand(steps)
        self.segments = segments
        let duration = segments.last?.endSeconds ?? 0
        var perSecond: [Double] = []
        perSecond.reserveCapacity(duration)
        for s in segments {
            for i in 0..<s.durationSeconds {
                perSecond.append(s.power(at: Double(s.startSeconds + i) + 0.5) ?? 0.6)
            }
        }
        self.intensityFactor = Self.normalized(perSecond)
    }

    public var durationSeconds: Int { segments.last?.endSeconds ?? 0 }

    public func segmentIndex(at t: Double) -> Int? {
        guard t >= 0, t < Double(durationSeconds) else { return nil }
        return segments.firstIndex { t < Double($0.endSeconds) }
    }

    /// Objetivo en fracción de FTP a `t` segundos (`nil` si es libre o ya ha terminado).
    public func target(at t: Double) -> Double? {
        segmentIndex(at: t).flatMap { segments[$0].power(at: t) }
    }

    /// Carga prevista (TSS): horas × IF² × 100.
    public var tss: Double {
        let ifactor = intensityFactor
        return Double(durationSeconds) / 3600 * ifactor * ifactor * 100
    }

    /// Zona con más tiempo por encima de Z2 (la que define el entreno); si no, Z1/Z2.
    public var mainZone: PowerZone {
        var seconds: [PowerZone: Int] = [:]
        for s in segments {
            guard let a = s.startPower, let b = s.endPower else { continue }
            seconds[PowerZone(fractionOfFTP: max(a, b)), default: 0] += s.durationSeconds
        }
        let hard = seconds.filter { $0.key > .z2 }
        let pool = hard.isEmpty ? seconds : hard
        return pool.max { $0.value < $1.value }?.key ?? .z1
    }

    /// Potencia normalizada (en las mismas unidades que `values`, muestras de 1 s):
    /// media móvil de 30 s, a la cuarta, media y raíz cuarta.
    static func normalized(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let window = min(30, values.count)
        var sum = values.prefix(window).reduce(0, +)
        var fourth = pow(sum / Double(window), 4)
        var n = 1
        for i in window..<values.count {
            sum += values[i] - values[i - window]
            fourth += pow(sum / Double(window), 4)
            n += 1
        }
        return pow(fourth / Double(n), 0.25)
    }

    static func expand(_ steps: [WorkoutStep]) -> [WorkoutSegment] {
        var result: [WorkoutSegment] = []
        var t = 0
        func add(_ seconds: Int, _ a: Double?, _ b: Double?) {
            guard seconds > 0 else { return }
            result.append(WorkoutSegment(id: result.count, startSeconds: t, durationSeconds: seconds, startPower: a, endPower: b))
            t += seconds
        }
        for step in steps {
            switch step {
            case .steady(let s, let p): add(s, p, p)
            case .ramp(let s, let a, let b): add(s, a, b)
            case .freeRide(let s): add(s, nil, nil)
            case .intervals(let n, let onS, let onP, let offS, let offP):
                for _ in 0..<max(n, 0) {
                    add(onS, onP, onP)
                    add(offS, offP, offP)
                }
            }
        }
        return result
    }
}

/// Dónde vas dentro de un entrenamiento.
public struct WorkoutProgress: Equatable, Sendable {
    public var segment: WorkoutSegment
    public var next: WorkoutSegment?
    public var secondsLeftInSegment: Double
    public var secondsLeftInWorkout: Double
    /// Objetivo en fracción de FTP (`nil` en tramos libres).
    public var target: Double?
}

extension Workout {
    public func progress(at t: Double) -> WorkoutProgress? {
        guard let i = segmentIndex(at: t) else { return nil }
        let s = segments[i]
        return WorkoutProgress(
            segment: s,
            next: i + 1 < segments.count ? segments[i + 1] : nil,
            secondsLeftInSegment: Double(s.endSeconds) - t,
            secondsLeftInWorkout: Double(durationSeconds) - t,
            target: s.power(at: t)
        )
    }
}

/// Potencia segundo a segundo de una salida, para sacar las mejores medias.
public struct PowerHistory: Equatable, Sendable {
    public private(set) var samples: [Int] = []

    public init(samples: [Int] = []) { self.samples = samples }

    public mutating func append(_ watts: Int) {
        samples.append(max(watts, 0))
    }

    /// Mejor potencia media en `seconds` segundos seguidos (`nil` si aún no hay tantos).
    public func bestAverage(seconds: Int) -> Double? {
        guard seconds > 0, samples.count >= seconds else { return nil }
        var sum = samples.prefix(seconds).reduce(0, +)
        var best = sum
        for i in seconds..<samples.count {
            sum += samples[i] - samples[i - seconds]
            best = max(best, sum)
        }
        return Double(best) / Double(seconds)
    }
}

public enum Physiology {
    /// VO2max estimado (ml/kg/min) con la ecuación del ACSM para cicloergómetro a partir
    /// de la mejor potencia de 5 minutos: VO2 ≈ 10,8 · W/kg + 7. Es una aproximación.
    public static func vo2maxEstimate(best5MinWatts: Double, weightKg: Double) -> Double? {
        guard weightKg > 0, best5MinWatts > 0 else { return nil }
        return 10.8 * best5MinWatts / weightKg + 7
    }
}
