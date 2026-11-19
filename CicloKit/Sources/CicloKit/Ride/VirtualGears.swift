import Foundation

/// Marchas virtuales en modo SIM.
///
/// El rodillo tiene un desarrollo real fijo (`trainerRatio`), así que la velocidad de su
/// volante depende solo de tu cadencia. Con una marcha de relación `r`, la bici iría
/// k = r / trainerRatio veces más rápido que el volante. Para que se sienta como en la
/// carretera hay que pedir al rodillo k veces la fuerza de la pendiente y la rodadura
/// y k³ veces la del aire:
///
///     F' = k · m·g·(pendiente + Crr) + k³ · ½ρCdA · v²
///
/// Eso se consigue mandando en el comando SIM pendiente·k, Crr·k y CdA·k³: el rodillo
/// hace el resto con su propia física, sin bucles de control que oscilen.
public struct VirtualGears: Equatable, Sendable {
    public private(set) var drivetrain: Drivetrain
    public private(set) var index: Int
    /// Relación plato/piñón equivalente del rodillo (ver `TrainerCalibration`).
    public var trainerRatio: Double

    /// Marcha de salida: la más parecida a un 50×23 / 34×15 (llano tranquilo).
    public static let startRatio = 2.2

    public init(drivetrain: Drivetrain = .road2x12, index: Int? = nil,
                trainerRatio: Double = TrainerCalibration().trainerRatio) {
        precondition(!drivetrain.gears.isEmpty)
        self.drivetrain = drivetrain
        self.trainerRatio = trainerRatio
        let gears = drivetrain.gears
        let start = gears.indices.min(by: {
            abs(gears[$0].ratio - Self.startRatio) < abs(gears[$1].ratio - Self.startRatio)
        }) ?? 0
        self.index = min(max(index ?? start, 0), gears.count - 1)
    }

    public var count: Int { drivetrain.gears.count }
    /// Número de marcha para mostrar (1 = la más blanda).
    public var number: Int { index + 1 }
    public var gear: Gear { drivetrain.gears[index] }
    /// Cuántas veces más dura es la marcha actual que el rodillo «a pelo».
    public var k: Double { gear.ratio / trainerRatio }

    /// Marcha más dura. Devuelve `false` si ya estás en la última.
    @discardableResult
    public mutating func shiftUp() -> Bool {
        guard index < count - 1 else { return false }
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

    /// Cambia de desarrollo quedándose en la marcha más parecida a la actual.
    public mutating func change(to newDrivetrain: Drivetrain) {
        let current = gear.ratio
        let gears = newDrivetrain.gears
        drivetrain = newDrivetrain
        index = gears.indices.min(by: { abs(gears[$0].ratio - current) < abs(gears[$1].ratio - current) }) ?? 0
    }

    /// Lo que hay que mandar al rodillo para la pendiente real `gradePercent` con esta marcha.
    public func simulation(gradePercent: Double, base: SimulationParameters = SimulationParameters(gradePercent: 0)) -> SimulationParameters {
        let k = self.k
        return SimulationParameters(
            windSpeedMps: base.windSpeedMps,
            gradePercent: min(max(gradePercent * k, -40), 40),
            crr: min(base.crr * k, 0.0255),
            windResistanceKgPerM: min(base.windResistanceKgPerM * k * k * k, 2.55)
        )
    }

    /// Velocidad «de carretera» con esta marcha a partir de la velocidad del volante.
    public func virtualSpeed(fromTrainerKmh kmh: Double) -> Double {
        kmh * k
    }
}
