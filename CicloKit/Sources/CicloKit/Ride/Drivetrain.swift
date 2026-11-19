import Foundation

/// Una marcha de bici real: relación plato/piñón y cómo se llama («34×21»).
public struct Gear: Hashable, Sendable {
    public var ratio: Double
    public var label: String

    /// Metros por pedalada con rueda de carretera (lo que los ciclistas llaman «desarrollo»).
    public var developmentMeters: Double { ratio * Drivetrain.wheelCircumference }
}

/// Desarrollo de una bici real (platos y piñones) del que salen las marchas virtuales.
public struct Drivetrain: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var chainrings: [Int]
    public var cogs: [Int]
    /// Marchas de la más blanda a la más dura.
    public var gears: [Gear]

    /// Circunferencia de rueda de carretera 700×28c, en metros.
    public static let wheelCircumference = 2.105

    /// Todas las combinaciones plato × piñón, ordenadas de blanda a dura.
    public init(id: String, name: String, chainrings: [Int], cogs: [Int]) {
        self.id = id
        self.name = name
        self.chainrings = chainrings
        self.cogs = cogs
        self.gears = chainrings.flatMap { ring in
            cogs.map { cog in Gear(ratio: Double(ring) / Double(cog), label: "\(ring)×\(cog)") }
        }
        .sorted { $0.ratio < $1.ratio }
    }

    /// `count` marchas repartidas por igual (cada salto, el mismo %) entre la más blanda y la
    /// más dura del desarrollo. Así un doble plato no tiene marchas repetidas ni saltos raros:
    /// es lo que hacen los cambios virtuales (Zwift, etc.). Cada una lleva el nombre de la
    /// combinación real más parecida.
    public init(id: String, name: String, chainrings: [Int], cogs: [Int], evenlySpaced count: Int) {
        let real = Drivetrain(id: id, name: name, chainrings: chainrings, cogs: cogs).gears
        let lo = real.first!.ratio, hi = real.last!.ratio
        self.id = id
        self.name = name
        self.chainrings = chainrings
        self.cogs = cogs
        self.gears = (0..<count).map { i in
            let ratio = lo * pow(hi / lo, Double(i) / Double(max(count - 1, 1)))
            let nearest = real.min(by: { abs(log($0.ratio / ratio)) < abs(log($1.ratio / ratio)) })!
            // Si no coincide con una combinación real (±0,5 %), se marca como aproximada.
            let exact = abs(log(nearest.ratio / ratio)) < 0.005
            return Gear(ratio: ratio, label: exact ? nearest.label : "≈\(nearest.label)")
        }
    }

    /// Metros que avanza la bici por cada pedalada con la marcha `gear` («desarrollo»).
    public func metersPerPedalStroke(_ gear: Gear) -> Double {
        gear.ratio * Self.wheelCircumference
    }

}

extension Drivetrain {
    /// Carretera Shimano 2×12: 50/34 con cassette 11-34, en 24 marchas repartidas por igual
    /// (de 34×34, el «molinillo», a 50×11).
    public static let road2x12 = Drivetrain(
        id: "carretera-2x12", name: "Carretera 2×12 (50/34 · 11-34)",
        chainrings: [50, 34], cogs: [11, 12, 13, 14, 15, 17, 19, 21, 24, 27, 30, 34],
        evenlySpaced: 24
    )

    /// Gravel Shimano GRX 1×12: plato 40 con cassette 10-51.
    public static let grx1x12 = Drivetrain(
        id: "grx-1x12", name: "Gravel GRX 1×12 (40 · 10-51)",
        chainrings: [40], cogs: [10, 12, 14, 16, 18, 21, 24, 28, 33, 39, 45, 51]
    )

    /// Gravel SRAM XPLR 1×12: plato 40 con cassette 10-44.
    public static let xplr1x12 = Drivetrain(
        id: "xplr-1x12", name: "Gravel SRAM XPLR 1×12 (40 · 10-44)",
        chainrings: [40], cogs: [10, 11, 13, 15, 17, 19, 21, 24, 28, 32, 38, 44]
    )

    public static let all: [Drivetrain] = [.road2x12, .grx1x12, .xplr1x12]
}

/// Cuánto avanza el rodillo por pedalada: lo que hay que saber para que una marcha
/// virtual se sienta como la de la bici.
///
/// El Kickr informa de una velocidad proporcional a la cadencia (su desarrollo real es fijo).
/// Medido el 19-nov en el Kickr Core 2: 0,356 km/h por rpm (= relación ≈ 2,82 con rueda de
/// 2,105 m, como un 50×18). Se va afinando solo con los datos que llegan.
public struct TrainerCalibration: Equatable, Sendable {
    public static let defaultKmhPerRpm = 0.356

    public private(set) var kmhPerRpm = TrainerCalibration.defaultKmhPerRpm
    public private(set) var samples = 0

    public init() {}

    /// Añade una muestra (solo si estás pedaleando de forma normal).
    public mutating func add(speedKmh: Double, cadenceRpm: Double) {
        guard cadenceRpm >= 40, speedKmh >= 5 else { return }
        let sample = speedKmh / cadenceRpm
        guard (0.15...0.6).contains(sample) else { return }
        samples += 1
        kmhPerRpm += (sample - kmhPerRpm) * 0.02
    }

    /// Relación plato/piñón equivalente del rodillo.
    public var trainerRatio: Double {
        kmhPerRpm / 3.6 * 60 / Drivetrain.wheelCircumference
    }
}
