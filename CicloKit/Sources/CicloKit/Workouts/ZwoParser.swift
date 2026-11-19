import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Lee entrenamientos en formato Zwift (.zwo, XML).
///
/// Soporta SteadyState, Warmup, Cooldown, Ramp, IntervalsT, FreeRide y MaxEffort;
/// lo demás (textos, cadencia objetivo…) se ignora.
public enum ZwoParser {
    public enum Error: Swift.Error, Equatable {
        case invalidXML(String)
        case noSteps
    }

    public static func parse(_ data: Data, id: String, fallbackName: String = "Entreno importado") throws -> Workout {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw Error.invalidXML(parser.parserError?.localizedDescription ?? "XML no válido")
        }
        guard !delegate.steps.isEmpty else { throw Error.noSteps }
        let name = delegate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = delegate.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return Workout(
            id: id,
            name: name.isEmpty ? fallbackName : name,
            category: .imported,
            summary: summary.isEmpty ? "Importado de un fichero .zwo." : summary,
            steps: delegate.steps
        )
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var name = ""
        var summary = ""
        var steps: [WorkoutStep] = []
        private var inWorkout = false
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            let tag = element.lowercased()
            if tag == "workout" { inWorkout = true; return }
            guard inWorkout else { return }

            var attrs: [String: String] = [:]
            for (k, v) in attributes { attrs[k.lowercased()] = v }
            func num(_ key: String) -> Double? { attrs[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
            func seconds(_ key: String) -> Int { Int((num(key) ?? 0).rounded()) }

            switch tag {
            case "steadystate":
                steps.append(.steady(seconds: seconds("duration"), power: num("power") ?? num("powerlow") ?? 0.5))
            case "warmup", "ramp", "cooldown":
                var from = num("powerlow") ?? 0.5
                var to = num("powerhigh") ?? from
                // Algunos ficheros escriben la vuelta a la calma «de menos a más»: siempre baja.
                if tag == "cooldown", from < to { swap(&from, &to) }
                steps.append(.ramp(seconds: seconds("duration"), from: from, to: to))
            case "intervalst":
                steps.append(.intervals(
                    repeats: Int(num("repeat") ?? 1),
                    onSeconds: seconds("onduration"), onPower: num("onpower") ?? num("poweronhigh") ?? 1,
                    offSeconds: seconds("offduration"), offPower: num("offpower") ?? num("poweroffhigh") ?? 0.5
                ))
            case "freeride", "maxeffort":
                steps.append(.freeRide(seconds: seconds("duration")))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            switch element.lowercased() {
            case "workout": inWorkout = false
            case "name" where !inWorkout: name = text
            case "description" where !inWorkout: summary = text
            default: break
            }
        }
    }
}
