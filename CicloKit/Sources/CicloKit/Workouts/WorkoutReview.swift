import Foundation

/// Una muestra del entreno (una por segundo), en tiempo del entreno (sin las pausas).
public struct ReviewSample: Equatable, Sendable {
    public var t: Double
    public var power: Int
    public var heartRate: Int?
    public var cadence: Int?

    public init(t: Double, power: Int, heartRate: Int? = nil, cadence: Int? = nil) {
        self.t = t
        self.power = power
        self.heartRate = heartRate
        self.cadence = cadence
    }
}

/// Análisis al terminar un entreno estructurado: ¿cumpliste los intervalos?, ¿derivó el pulso en Z2?,
/// ¿te pasaste del tope de pulso? y qué cambiar la próxima vez.
public struct WorkoutReview: Equatable, Sendable {
    /// Un intervalo de trabajo (tramo a ≥ 85 % del FTP o con cadencia objetivo).
    public struct Interval: Equatable, Sendable, Identifiable {
        public var id: Int { number }
        public var number: Int
        public var targetWatts: Int
        public var averageWatts: Int
        public var targetCadence: Int?
        public var averageCadence: Int?
        public var averageHeartRate: Int?
        /// Media / objetivo (1 = clavado).
        public var compliance: Double { Double(averageWatts) / Double(max(targetWatts, 1)) }
    }

    public enum Tone: String, Sendable { case good, warning, info }

    public struct Note: Equatable, Sendable, Identifiable {
        public var id: String { text }
        public var tone: Tone
        public var text: String
    }

    public var intervals: [Interval]
    /// Media ponderada (por tiempo) de lo hecho frente al objetivo en los intervalos; `nil` si no hay.
    public var compliance: Double?
    /// Desacople aeróbico (Pw:HR, %) en entrenos de base largos: cuánto empeora la relación
    /// potencia/pulso de la primera a la segunda mitad. < 5 % = base aeróbica sólida.
    public var decouplingPercent: Double?
    /// Segundos por encima del tope de pulso (entrenos de base).
    public var secondsAboveCap: Int?
    public var notes: [Note]
    /// Una frase: qué hacer la próxima vez.
    public var nextTime: String

    /// Umbral para considerar un tramo «de trabajo».
    static let workThreshold = 0.85

    /// - Parameter baseIntensity: intensidad con la que empezó (la de su tipo); los objetivos se
    ///   comparan con ella, no con tus ± durante el entreno.
    public init(workout: Workout, ftp: Int, samples: [ReviewSample], heartRateCap: Int? = nil,
                baseIntensity: Double = 1) {
        let done = samples.last.map { $0.t } ?? 0
        let isTest = workout.ftpTest != nil

        // Intervalos de trabajo terminados (al menos el 80 % hecho). Se ignoran los primeros
        // segundos de cada uno (lo que tarda el rodillo en llegar al objetivo).
        var intervals: [Interval] = []
        if !isTest {
            for seg in workout.segments {
                guard let a = seg.startPower, let b = seg.endPower else { continue }
                let isWork = (a + b) / 2 >= Self.workThreshold || seg.cadence != nil
                guard isWork, Double(seg.startSeconds) + Double(seg.durationSeconds) * 0.8 <= done else { continue }
                let skip = seg.durationSeconds >= 20 ? 3.0 : 0
                let inSeg = samples.filter {
                    $0.t >= Double(seg.startSeconds) + skip && $0.t < Double(seg.endSeconds)
                }
                guard !inSeg.isEmpty else { continue }
                let target = (a + b) / 2 * Double(ftp) * baseIntensity
                let avg = Double(inSeg.map(\.power).reduce(0, +)) / Double(inSeg.count)
                let cads = inSeg.compactMap(\.cadence).filter { $0 > 0 }
                let hrs = inSeg.compactMap(\.heartRate).filter { $0 > 0 }
                intervals.append(Interval(
                    number: intervals.count + 1,
                    targetWatts: Int(target.rounded()),
                    averageWatts: Int(avg.rounded()),
                    targetCadence: seg.cadence,
                    averageCadence: cads.isEmpty ? nil : Int((Double(cads.reduce(0, +)) / Double(cads.count)).rounded()),
                    averageHeartRate: hrs.isEmpty ? nil : Int((Double(hrs.reduce(0, +)) / Double(hrs.count)).rounded())
                ))
            }
        }
        self.intervals = intervals
        let totalTarget = intervals.map(\.targetWatts).reduce(0, +)
        compliance = intervals.isEmpty ? nil
            : Double(intervals.map { min($0.averageWatts, Int(Double($0.targetWatts) * 1.1)) }.reduce(0, +)) / Double(totalTarget)

        // Desacople en entrenos de base de 40' o más: solo los tramos a potencia constante
        // (sin calentamiento ni vuelta a la calma) y sin los 10' primeros.
        decouplingPercent = nil
        if !isTest, workout.mainZone <= .z2, done >= 40 * 60 {
            let steadySegments = workout.segments.filter { !$0.isFree && !$0.isRamp }
            let steady = samples.filter { s in
                s.t >= 600 && s.power > 0 && (s.heartRate ?? 0) > 0
                    && steadySegments.contains { s.t >= Double($0.startSeconds) && s.t < Double($0.endSeconds) }
            }
            if steady.count >= 20 * 60 {
                let half = steady.count / 2
                func ef(_ s: ArraySlice<ReviewSample>) -> Double {
                    Double(s.map(\.power).reduce(0, +)) / Double(s.compactMap(\.heartRate).reduce(0, +))
                }
                let first = ef(steady[..<half]), second = ef(steady[half...])
                decouplingPercent = (first - second) / first * 100
            }
        }

        secondsAboveCap = heartRateCap.map { cap in samples.filter { ($0.heartRate ?? 0) > cap }.count }

        // Notas.
        var notes: [Note] = []
        if let c = compliance {
            let pct = Int((c * 100).rounded())
            let worst = intervals.min { $0.compliance < $1.compliance }
            if c >= 0.97 {
                notes.append(Note(tone: .good, text: "Intervalos clavados: \(pct) % de lo previsto."))
            } else if c >= 0.90 {
                notes.append(Note(tone: .info, text: "Intervalos casi completos: \(pct) % de lo previsto."))
            } else {
                notes.append(Note(tone: .warning, text: "Intervalos por debajo: \(pct) % de lo previsto."))
            }
            if let worst, worst.compliance < 0.95, intervals.count > 1 {
                notes.append(Note(tone: worst.compliance < 0.9 ? .warning : .info,
                                  text: "El que más costó, el nº \(worst.number): \(worst.averageWatts) W de \(worst.targetWatts) W."))
            }
            if intervals.count >= 3, let last = intervals.last, let firstHR = intervals.first?.averageHeartRate,
               let lastHR = last.averageHeartRate, lastHR - firstHR >= 12 {
                notes.append(Note(tone: .info,
                                  text: "El pulso subió \(lastHR - firstHR) ppm del primer al último intervalo: buena carga."))
            }
        }
        let cadenceIntervals = intervals.filter { $0.targetCadence != nil && $0.averageCadence != nil }
        if !cadenceIntervals.isEmpty {
            let off = cadenceIntervals.filter { abs($0.averageCadence! - $0.targetCadence!) > 5 }
            if off.isEmpty {
                notes.append(Note(tone: .good, text: "Cadencia de fuerza en su sitio en todos los bloques."))
            } else {
                let fast = off.filter { $0.averageCadence! > $0.targetCadence! }.count
                notes.append(Note(tone: .warning, text: fast >= off.count - fast
                    ? "Cadencia alta en \(off.count) bloque(s) de fuerza: pon una marcha más dura para bajarla."
                    : "Cadencia baja en \(off.count) bloque(s) de fuerza: no hace falta atrancarse tanto."))
            }
        }
        if let d = decouplingPercent {
            let txt = d.formatted(.number.precision(.fractionLength(1)))
            notes.append(d < 5
                ? Note(tone: .good, text: "Desacople aeróbico \(txt) %: el pulso aguantó estable (base aeróbica sólida).")
                : Note(tone: .warning, text: "Desacople aeróbico \(txt) %: el pulso derivó. Hidrátate, ventila y no subas aún la duración."))
        }
        if let s = secondsAboveCap, let cap = heartRateCap, done > 0 {
            let share = Double(s) / max(done, 1)
            if share > 0.1 {
                notes.append(Note(tone: .warning,
                                  text: "\(s / 60)' por encima de \(cap) ppm (\(Int((share * 100).rounded())) %): zona gris."))
            } else if heartRateCap != nil {
                notes.append(Note(tone: .good, text: "Pulso bajo el tope de \(cap) ppm casi todo el rato."))
            }
        }
        self.notes = notes

        // Próxima vez: lo más importante primero.
        let finished = done >= Double(workout.durationSeconds) * 0.95
        if isTest {
            nextTime = "Tras un test, un día suave o de descanso."
        } else if !finished {
            nextTime = "No lo terminaste: si fue por cansancio, repítelo cuando estés fresco o baja un 5 %."
        } else if let c = compliance, c < 0.9 {
            nextTime = "Baja la intensidad un 5 % (dos pulsaciones de −) o revisa tu FTP con un test."
        } else if let s = secondsAboveCap, Double(s) / max(done, 1) > 0.1 {
            nextTime = "Ve más suave: que el pulso no pase de \(heartRateCap ?? 0) ppm aunque bajen los vatios."
        } else if let d = decouplingPercent, d >= 5 {
            nextTime = "Repite la misma duración hasta que el desacople baje del 5 %."
        } else if compliance != nil, intervals.allSatisfy({ $0.compliance >= 0.97 }) {
            nextTime = "Si te sobró, súbelo un 2–3 % la próxima vez (una pulsación de +)."
        } else if compliance != nil {
            nextTime = "Misma intensidad la próxima vez, hasta que salgan todos los intervalos completos."
        } else if decouplingPercent != nil {
            nextTime = "Base aeróbica estable: ya puedes alargar estos rodajes 10–15'."
        } else {
            nextTime = "Bien hecho. Repite así."
        }
    }
}
