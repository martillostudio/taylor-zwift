import CicloKit
import Foundation
import Observation
import Security

/// Conexión con intervals.icu: subida automática de cada entreno (.fit) y descarga de tus
/// salidas en exterior (las que trae de Garmin Connect) para el plan, más su FTP estimado (eFTP).
///
/// intervals.icu es gratis, analiza la carga (CTL/ATL, curvas de potencia, zonas) y además puede
/// traer tus salidas de Garmin Connect, así que junta en un sitio el rodillo y la calle.
/// Para uso personal basta con la clave de API (intervals.icu → Settings → «Developer Settings»),
/// con autenticación básica: usuario `API_KEY` y la clave como contraseña.
/// La clave se guarda en el llavero del sistema, no en un fichero.
@MainActor
@Observable
final class IntervalsService {
    static let base = URL(string: "https://intervals.icu/api/v1")!

    var autoUpload: Bool {
        didSet { UserDefaults.standard.set(autoUpload, forKey: "intervalsSubidaAuto") }
    }
    private(set) var athleteName: String?
    private(set) var status: String?
    private(set) var isBusy = false

    @ObservationIgnored private var apiKey: String?

    /// Actividades recientes de intervals.icu (se guardan para tenerlas sin conexión).
    private(set) var recent: [IntervalsActivity] = []
    private(set) var lastSync: Date?

    /// Salidas en bici por la calle (no rodillo, ni las que subimos nosotros).
    var outdoorRides: [IntervalsActivity] { recent.filter(\.isOutdoorRide) }
    /// FTP estimado por intervals.icu con tus últimas salidas (eFTP), redondeado a 5 W.
    var estimatedFTP: Int? { IntervalsActivity.latestEstimatedFTP(in: recent) }

    var isConnected: Bool { apiKey != nil && athleteName != nil }

    enum Failure: LocalizedError {
        case notConnected
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "No hay cuenta de intervals.icu conectada."
            case .http(401, _), .http(403, _): "intervals.icu no acepta la clave de API. Cópiala de nuevo de tus ajustes."
            case .http(let code, let body): "intervals.icu respondió \(code): \(body.prefix(160))"
            }
        }
    }

    init() {
        autoUpload = UserDefaults.standard.object(forKey: "intervalsSubidaAuto") as? Bool ?? true
        athleteName = UserDefaults.standard.string(forKey: "intervalsAtleta")
        apiKey = Keychain.read(account: "intervals.icu")
        if let data = UserDefaults.standard.data(forKey: "intervalsRecientes"),
           let cached = try? JSONDecoder().decode([IntervalsActivity].self, from: data) {
            recent = cached
        }
        lastSync = UserDefaults.standard.object(forKey: "intervalsSincronizado") as? Date
    }

    // MARK: Cuenta

    /// Comprueba la clave pidiendo tu perfil y, si vale, la guarda en el llavero.
    func connect(apiKey raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        status = "Comprobando la clave…"
        do {
            var request = URLRequest(url: Self.base.appendingPathComponent("athlete/0"))
            request.setValue(Self.authorization(key), forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(data, response)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let name = (json?["name"] as? String) ?? (json?["firstname"] as? String) ?? "tu cuenta"
            Keychain.save(key, account: "intervals.icu")
            apiKey = key
            athleteName = name
            UserDefaults.standard.set(name, forKey: "intervalsAtleta")
            status = "Conectado ✅"
        } catch {
            status = error.localizedDescription
        }
    }

    func disconnect() {
        Keychain.delete(account: "intervals.icu")
        apiKey = nil
        athleteName = nil
        UserDefaults.standard.removeObject(forKey: "intervalsAtleta")
        status = nil
        recent = []
        lastSync = nil
        UserDefaults.standard.removeObject(forKey: "intervalsRecientes")
        UserDefaults.standard.removeObject(forKey: "intervalsSincronizado")
    }

    // MARK: Descarga

    /// Trae las actividades desde `oldest` hasta mañana. Sin `force`, no repite si la última
    /// sincronización fue hace menos de 10 minutos.
    func sync(since oldest: Date, force: Bool = false) async {
        guard let apiKey, !isBusy else { return }
        if !force, let lastSync, Date().timeIntervalSince(lastSync) < 600 { return }
        isBusy = true
        defer { isBusy = false }
        let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        var components = URLComponents(url: Self.base.appendingPathComponent("athlete/0/activities"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "oldest", value: oldest.formatted(day)),
            URLQueryItem(name: "newest", value: Date().addingTimeInterval(86_400).formatted(day)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.authorization(apiKey), forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(data, response)
            recent = IntervalsActivity.parseList(data).sorted { $0.start > $1.start }
            lastSync = Date()
            UserDefaults.standard.set(try? JSONEncoder().encode(recent), forKey: "intervalsRecientes")
            UserDefaults.standard.set(lastSync, forKey: "intervalsSincronizado")
            let n = outdoorRides.count
            status = n == 0 ? "Sincronizado: sin salidas en exterior en estas fechas."
                : "Sincronizado: \(n) salida\(n == 1 ? "" : "s") en exterior."
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Subida

    /// Sube el .fit y devuelve el id de la actividad («i…»). intervals.icu no duplica:
    /// si el fichero ya estaba, devuelve la que había.
    func upload(_ activity: Activity, fit: Data) async throws -> String {
        guard let apiKey else { throw Failure.notConnected }
        isBusy = true
        defer { isBusy = false }
        status = "Subiendo «\(activity.name)» a intervals.icu…"

        var components = URLComponents(url: Self.base.appendingPathComponent("athlete/0/activities"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: activity.name),
            URLQueryItem(name: "description", value: "Rodillo con Taylor Zwift."),
            URLQueryItem(name: "external_id", value: "taylorzwift-\(activity.id.uuidString)"),
        ]
        let boundary = "taylorzwift-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(activity.id.uuidString).fit\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fit)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(Self.authorization(apiKey), forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            try Self.check(data, response)
            let id = Self.activityID(in: data) ?? "?"
            status = "Subido a intervals.icu ✅"
            return id
        } catch {
            status = error.localizedDescription
            throw error
        }
    }

    // MARK: Plan y FTP

    /// Pone el plan en tu calendario de intervals.icu (y de ahí, si lo tienes activado, en
    /// Garmin Connect y el reloj). Antes borra lo que mandamos la última vez, así que se puede
    /// repetir al cambiar la fecha de inicio sin duplicar nada. Devuelve cuántas sesiones puso.
    @discardableResult
    func pushPlan(_ events: [PlannedEvent], planID: String) async throws -> Int {
        guard let apiKey, let first = events.map(\.date).min(), let last = events.map(\.date).max()
        else { throw Failure.notConnected }
        isBusy = true
        defer { isBusy = false }
        status = "Mandando el plan a intervals.icu…"
        do {
            // 1. Borrar las sesiones del plan que ya estaban (de este envío o de uno anterior).
            let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            var components = URLComponents(url: Self.base.appendingPathComponent("athlete/0/events"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "oldest", value: min(first, Date()).addingTimeInterval(-200 * 86_400).formatted(day)),
                URLQueryItem(name: "newest", value: max(last, Date()).addingTimeInterval(200 * 86_400).formatted(day)),
                URLQueryItem(name: "category", value: "WORKOUT"),
            ]
            let (listData, listResponse) = try await URLSession.shared.data(for: request(components.url!, key: apiKey))
            try Self.check(listData, listResponse)
            let existing = ((try? JSONSerialization.jsonObject(with: listData)) as? [[String: Any]] ?? [])
                .filter { ($0["external_id"] as? String)?.hasPrefix("taylorzwift-\(planID)-") == true }
                .compactMap { $0["id"] }
            if !existing.isEmpty {
                var delete = request(Self.base.appendingPathComponent("athlete/0/events/bulk-delete"), key: apiKey)
                delete.httpMethod = "PUT"
                delete.httpBody = try JSONSerialization.data(withJSONObject: existing.map { ["id": $0] })
                let (data, response) = try await URLSession.shared.data(for: delete)
                try Self.check(data, response)
            }

            // 2. Crear las sesiones nuevas.
            let stamp = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            let body: [[String: Any]] = events.map { e in
                var o: [String: Any] = [
                    "category": "WORKOUT",
                    "start_date_local": e.date.formatted(stamp) + "T00:00:00",
                    "type": e.workout == nil ? "Ride" : "VirtualRide",
                    "indoor": e.workout != nil,
                    "name": e.name,
                    "description": e.description,
                    "external_id": e.externalID,
                    "moving_time": e.seconds,
                ]
                if let load = e.load { o["icu_training_load"] = load }
                if let w = e.workout {
                    o["file_contents"] = String(decoding: ZwoEncoder.encode(w, description: e.description), as: UTF8.self)
                    o["filename"] = "\(w.id).zwo"
                }
                return o
            }
            var create = request(Self.base.appendingPathComponent("athlete/0/events/bulk"), key: apiKey)
            create.httpMethod = "POST"
            create.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: create)
            try Self.check(data, response)
            let n = ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.count ?? events.count
            status = "Plan en intervals.icu: \(n) sesiones ✅"
            return n
        } catch {
            status = error.localizedDescription
            throw error
        }
    }

    /// Pone tu FTP de ciclismo en intervals.icu (para que calcule bien la carga y las zonas).
    func pushFTP(_ ftp: Int) async {
        guard let apiKey else { return }
        do {
            let (data, response) = try await URLSession.shared.data(
                for: request(Self.base.appendingPathComponent("athlete/0/sport-settings"), key: apiKey))
            try Self.check(data, response)
            let settings = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            guard let ride = settings.first(where: { ($0["types"] as? [String])?.contains("Ride") == true }),
                  let id = ride["id"] else { return }
            if (ride["ftp"] as? Int) == ftp { return }
            var put = request(Self.base.appendingPathComponent("athlete/0/sport-settings/\(id)"), key: apiKey)
            put.httpMethod = "PUT"
            put.httpBody = try JSONSerialization.data(withJSONObject: ["ftp": ftp])
            let (d2, r2) = try await URLSession.shared.data(for: put)
            try Self.check(d2, r2)
            status = "FTP de intervals.icu: \(ftp) W ✅"
        } catch {
            status = "No pude cambiar el FTP en intervals.icu: \(error.localizedDescription)"
        }
    }

    private func request(_ url: URL, key: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(Self.authorization(key), forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    /// La respuesta es `{ "id": "i…", … }` o una lista de ellas, según la versión de la API.
    static func activityID(in data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data)
        if let object = json as? [String: Any] {
            if let id = object["id"] as? String { return id }
            if let list = object["activities"] as? [[String: Any]] { return list.first?["id"] as? String }
        }
        if let list = json as? [[String: Any]] { return list.first?["id"] as? String }
        return nil
    }

    static func activityURL(_ id: String) -> URL? {
        URL(string: "https://intervals.icu/activities/\(id)")
    }

    // MARK: Interno

    private static func authorization(_ key: String) -> String {
        "Basic " + Data("API_KEY:\(key)".utf8).base64EncodedString()
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw Failure.http(code, String(decoding: data, as: UTF8.self))
        }
    }
}

/// Guardar secretos (claves de API) en el llavero del sistema.
enum Keychain {
    private static let service = "studio.martillo.taylorzwift"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) {
        delete(account: account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
