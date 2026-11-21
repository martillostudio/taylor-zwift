import Foundation

/// Escribe un entreno en formato Zwift (.zwo, XML), que leen intervals.icu, TrainingPeaks,
/// MyWhoosh y casi cualquier app de rodillo. Potencias en fracción de FTP, como en `Workout`.
public enum ZwoEncoder {
    /// `description` sustituye al texto del entreno (intervals.icu enseña el del fichero).
    public static func encode(_ workout: Workout, description: String? = nil) -> Data {
        var xml = """
        <workout_file>
            <author>Taylor Zwift</author>
            <name>\(escape(workout.name))</name>
            <description>\(escape(description ?? workout.summary))</description>
            <sportType>bike</sportType>
            <workout>

        """
        for step in workout.steps {
            xml += "        " + element(step) + "\n"
        }
        xml += "    </workout>\n</workout_file>\n"
        return Data(xml.utf8)
    }

    static func element(_ step: WorkoutStep) -> String {
        switch step {
        case .steady(let s, let p):
            return #"<SteadyState Duration="\#(s)" Power="\#(f(p))"/>"#
        case .ramp(let s, let a, let b):
            return #"<Ramp Duration="\#(s)" PowerLow="\#(f(a))" PowerHigh="\#(f(b))"/>"#
        case .intervals(let n, let on, let pOn, let off, let pOff):
            return #"<IntervalsT Repeat="\#(n)" OnDuration="\#(on)" OffDuration="\#(off)" OnPower="\#(f(pOn))" OffPower="\#(f(pOff))"/>"#
        case .freeRide(let s):
            return #"<FreeRide Duration="\#(s)" FlatRoad="1"/>"#
        case .lowCadence(let n, let on, let pOn, let rpm, let off, let pOff):
            return #"<IntervalsT Repeat="\#(n)" OnDuration="\#(on)" OffDuration="\#(off)" OnPower="\#(f(pOn))" OffPower="\#(f(pOff))" Cadence="\#(rpm)"/>"#
        }
    }

    private static func f(_ x: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), x)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
