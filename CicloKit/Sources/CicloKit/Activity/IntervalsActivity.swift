import Foundation

/// Una actividad de intervals.icu (lo justo para el plan y el FTP).
///
/// Sale de `GET /api/v1/athlete/0/activities?oldest=…&newest=…`, que devuelve una lista de
/// objetos JSON. Las actividades que vienen de Strava llegan casi vacías (Strava no deja que
/// otras apps las enseñen), así que todos los campos salvo el id y la fecha son opcionales.
public struct IntervalsActivity: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Hora local de la salida.
    public var start: Date
    /// «Ride», «GravelRide», «VirtualRide», «Run»…
    public var type: String
    public var movingSeconds: Double
    /// En rodillo (lo marca Garmin o la app que la grabó).
    public var trainer: Bool
    /// `taylorzwift-…` si la subimos nosotros.
    public var externalID: String?
    /// Carga (TSS) que calcula intervals.icu.
    public var load: Double?
    /// FTP estimado por intervals.icu (eFTP) en esa fecha.
    public var estimatedFTP: Double?

    public init(id: String, name: String, start: Date, type: String, movingSeconds: Double,
                trainer: Bool = false, externalID: String? = nil, load: Double? = nil, estimatedFTP: Double? = nil) {
        self.id = id
        self.name = name
        self.start = start
        self.type = type
        self.movingSeconds = movingSeconds
        self.trainer = trainer
        self.externalID = externalID
        self.load = load
        self.estimatedFTP = estimatedFTP
    }

    /// Tipos de salida en bici por la calle.
    static let outdoorTypes: Set<String> = ["Ride", "GravelRide", "MountainBikeRide"]

    /// Salida en bici en exterior (no rodillo, ni carrera, ni las que subimos nosotros).
    public var isOutdoorRide: Bool {
        Self.outdoorTypes.contains(type) && !trainer && !isOurs
    }

    public var isOurs: Bool { externalID?.hasPrefix("taylorzwift-") == true }

    /// Lee la lista de actividades. Se salta las que no tienen id o fecha.
    public static func parseList(_ data: Data, timeZone: TimeZone = .current) -> [IntervalsActivity] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return list.compactMap { o in
            guard let id = o["id"].map({ "\($0)" }),
                  let raw = o["start_date_local"] as? String,
                  let start = formatter.date(from: String(raw.prefix(19)))
            else { return nil }
            func number(_ key: String) -> Double? {
                (o[key] as? NSNumber)?.doubleValue
            }
            // eFTP: el FTP que intervals.icu va estimando con tus mejores esfuerzos recientes.
            let eftp = number("icu_rolling_ftp").flatMap { $0 > 0 ? $0 : nil }
            return IntervalsActivity(
                id: id,
                name: o["name"] as? String ?? "Actividad",
                start: start,
                type: o["type"] as? String ?? "",
                movingSeconds: number("moving_time") ?? number("elapsed_time") ?? 0,
                trainer: o["trainer"] as? Bool ?? false,
                externalID: o["external_id"] as? String,
                load: number("icu_training_load"),
                estimatedFTP: eftp
            )
        }
    }

    /// El eFTP más reciente de la lista (redondeado a 5 W), si hay alguno.
    public static func latestEstimatedFTP(in list: [IntervalsActivity]) -> Int? {
        guard let f = list.filter({ $0.estimatedFTP != nil }).max(by: { $0.start < $1.start })?.estimatedFTP
        else { return nil }
        return Int((f / 5).rounded()) * 5
    }

    public var asCompletedWorkout: CompletedWorkout {
        CompletedWorkout(start: start, workoutID: nil, seconds: movingSeconds, isOutdoor: true)
    }
}
