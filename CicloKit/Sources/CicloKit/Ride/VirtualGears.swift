import Foundation

/// Marchas virtuales en modo SIM.
///
/// El rodillo tiene un desarrollo real fijo, así que la velocidad de su volante depende
/// solo de tu cadencia. Para que una marcha «k veces más dura» se sienta como en la
/// carretera hay que pedir al rodillo k veces la fuerza de la pendiente y la rodadura
/// y k³ veces la del aire (la velocidad virtual es k veces la del volante):
///
///     F' = k · m·g·(pendiente + Crr) + k³ · ½ρCdA · v²
///
/// Eso se consigue mandando en el comando SIM pendiente·k, Crr·k y CdA·k³: el rodillo
/// hace el resto con su propia física, sin bucles de control que oscilen.
public struct VirtualGears: Equatable, Sendable {
    /// 24 marchas de 0,5× a 1,7× (progresión geométrica: cada salto se nota igual).
    /// El tope de 1,7× viene del máximo de CdA que admite FTMS (2,55 kg/m con 0,51 de base).
    public static let defaultRatios: [Double] = (0..<24).map { i in
        0.5 * pow(1.7 / 0.5, Double(i) / 23)
    }

    public let ratios: [Double]
    public private(set) var index: Int

    /// Empieza en la marcha más cercana a 1× (como el rodillo sin marchas).
    public init(ratios: [Double] = VirtualGears.defaultRatios, index: Int? = nil) {
        precondition(!ratios.isEmpty)
        self.ratios = ratios
        let neutral = ratios.indices.min(by: { abs(ratios[$0] - 1) < abs(ratios[$1] - 1) }) ?? 0
        self.index = min(max(index ?? neutral, 0), ratios.count - 1)
    }

    public var count: Int { ratios.count }
    /// Número de marcha para mostrar (1 = la más blanda).
    public var number: Int { index + 1 }
    /// Cuánto más dura es la marcha actual que el rodillo sin marchas.
    public var ratio: Double { ratios[index] }

    /// Marcha más dura. Devuelve `false` si ya estás en la última.
    @discardableResult
    public mutating func shiftUp() -> Bool {
        guard index < ratios.count - 1 else { return false }
        index += 1
        return true
    }

    /// Marcha más blanda. Devuelve `false` si ya estás en la primera.
    @discardableResult
    public mutating func shiftDown() -> Bool {
        guard index > 0 else { return false }
        index -= 1
        return true
    }

    /// Lo que hay que mandar al rodillo para la pendiente real `gradePercent` con esta marcha.
    public func simulation(gradePercent: Double, base: SimulationParameters = SimulationParameters(gradePercent: 0)) -> SimulationParameters {
        let k = ratio
        return SimulationParameters(
            windSpeedMps: base.windSpeedMps,
            gradePercent: min(max(gradePercent * k, -40), 40),
            crr: min(base.crr * k, 0.0255),
            windResistanceKgPerM: min(base.windResistanceKgPerM * k * k * k, 2.55)
        )
    }

    /// Velocidad «de carretera» con esta marcha a partir de la velocidad del volante.
    public func virtualSpeed(fromTrainerKmh kmh: Double) -> Double {
        kmh * ratio
    }
}
