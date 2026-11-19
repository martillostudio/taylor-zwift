import Foundation

/// Lo que queremos que haga el rodillo: modo SIM con unos parámetros o ERG a una potencia.
public enum TrainerTarget: Equatable, Sendable {
    case simulation(SimulationParameters)
    case targetPower(watts: Int)

    public static let flat = TrainerTarget.simulation(SimulationParameters(gradePercent: 0))

    public var command: FTMSCommand {
        switch self {
        case .simulation(let p): .setSimulation(p)
        case .targetPower(let w): .setTargetPower(watts: w)
        }
    }

    /// Dos objetivos que el rodillo recibiría con los mismos bytes cuentan como iguales:
    /// así no mandamos cambios que se pierden al redondear.
    public func isSameOnTheWire(as other: TrainerTarget?) -> Bool {
        guard let other else { return false }
        return command.bytes == other.command.bytes
    }

    public var description: String {
        switch self {
        case .simulation(let p):
            "SIM \(p.gradePercent.formatted(.number.precision(.fractionLength(1)))) %"
        case .targetPower(let w):
            "ERG \(w) W"
        }
    }
}
