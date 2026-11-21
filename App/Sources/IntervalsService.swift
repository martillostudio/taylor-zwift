import CicloKit
import Foundation
import Observation
import Security

/// Conexión con intervals.icu: subida automática de cada entreno (.fit).
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
