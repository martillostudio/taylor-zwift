import CicloKit
import Foundation
import Observation

/// Conexión con Strava: autorización OAuth y subida de los .fit.
///
/// Necesita una «app» tuya en Strava (https://www.strava.com/settings/api) con
/// «Authorization Callback Domain» = `localhost`. Su Client ID y Client Secret se ponen en la
/// app; los tokens se guardan en la carpeta privada de la app (no salen del Mac).
@MainActor
@Observable
final class StravaService {
    static let callbackScheme = "taylorzwift"
    static let redirectURI = "taylorzwift://localhost/strava"

    var clientID: String { didSet { saveSettings() } }
    var clientSecret: String { didSet { saveSettings() } }
    /// Subir solo cada entreno al terminarlo.
    var autoUpload: Bool { didSet { saveSettings() } }
    private(set) var athleteName: String?
    private(set) var status: String?
    private(set) var isUploading = false

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: TimeInterval
    }

    private struct Settings: Codable {
        var clientID = ""
        var clientSecret = ""
        var autoUpload = true
        var athleteName: String?
        var tokens: Tokens?
    }

    @ObservationIgnored private var tokens: Tokens?
    @ObservationIgnored private let file: URL

    var isConnected: Bool { athleteName != nil && tokens != nil }
    var canConnect: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        file = base.appendingPathComponent("strava.json")
        let s = (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))) ?? Settings()
        clientID = s.clientID
        clientSecret = s.clientSecret
        autoUpload = s.autoUpload
        athleteName = s.athleteName
        tokens = s.tokens
    }

    // MARK: Autorización

    var authorizeURL: URL? {
        guard !clientID.isEmpty else { return nil }
        var c = URLComponents(string: "https://www.strava.com/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: "read,activity:write"),
        ]
        return c.url
    }

    /// Recibe la URL de vuelta de Strava (con `?code=…`) y pide los tokens.
    func handleCallback(_ url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            status = "Strava no ha dado permiso (\(error))."
            return
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            status = "Strava no ha devuelto el código de autorización."
            return
        }
        let granted = items.first(where: { $0.name == "scope" })?.value ?? ""
        guard granted.contains("activity:write") else {
            status = "Falta el permiso para subir actividades: vuelve a conectar y marca esa casilla."
            return
        }
        do {
            try await requestTokens(["code": code, "grant_type": "authorization_code"])
            status = "Conectado con Strava."
        } catch {
            status = "No se pudo conectar: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        tokens = nil
        athleteName = nil
        status = "Desconectado de Strava."
        saveSettings()
    }

    // MARK: Subida

    enum UploadError: LocalizedError {
        case notConnected
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "No estás conectado a Strava."
            case .server(let message): message
            }
        }
    }

    /// Sube la actividad y espera a que Strava la procese. Devuelve el id de la actividad.
    @discardableResult
    func upload(_ activity: Activity, fit: Data) async throws -> Int64 {
        isUploading = true
        defer { isUploading = false }
        status = "Subiendo «\(activity.name)» a Strava…"
        let token = try await validAccessToken()

        let boundary = "taylorzwift-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("data_type", "fit")
        field("name", activity.name)
        field("description", "Entreno en rodillo con Taylor Zwift.")
        field("trainer", "1")
        field("external_id", "taylorzwift-\(activity.id.uuidString).fit")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(activity.id.uuidString).fit\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fit)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        var upload = try decodeUpload(data, response)

        // Strava procesa el fichero en segundo plano: preguntamos hasta que acaba.
        for _ in 0..<20 {
            if let id = upload.activityID {
                status = "Subido a Strava ✅"
                return id
            }
            if let error = upload.error, !error.isEmpty {
                throw UploadError.server(error)
            }
            try await Task.sleep(for: .seconds(2))
            var check = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads/\(upload.id)")!)
            check.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (d, r) = try await URLSession.shared.data(for: check)
            upload = try decodeUpload(d, r)
        }
        throw UploadError.server("Strava sigue procesando la actividad; mírala en un rato en strava.com.")
    }

    // MARK: Interno

    private struct UploadResponse {
        var id: Int64
        var error: String?
        var activityID: Int64?
    }

    private func decodeUpload(_ data: Data, _ response: URLResponse) throws -> UploadResponse {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), let id = (json["id"] as? NSNumber)?.int64Value else {
            let message = json["message"] as? String ?? "error \(code)"
            let detail = (json["errors"] as? [[String: Any]])?.compactMap { $0["code"] as? String }.joined(separator: ", ") ?? ""
            throw UploadError.server("Strava: \(message) \(detail)".trimmingCharacters(in: .whitespaces))
        }
        return UploadResponse(
            id: id,
            error: json["error"] as? String,
            activityID: (json["activity_id"] as? NSNumber)?.int64Value
        )
    }

    private func validAccessToken() async throws -> String {
        guard let t = tokens else { throw UploadError.notConnected }
        if t.expiresAt - 120 > Date().timeIntervalSince1970 { return t.accessToken }
        try await requestTokens(["refresh_token": t.refreshToken, "grant_type": "refresh_token"])
        guard let fresh = tokens else { throw UploadError.notConnected }
        return fresh.accessToken
    }

    private func requestTokens(_ params: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = params
        all["client_id"] = clientID
        all["client_secret"] = clientSecret
        var c = URLComponents()
        c.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expires = (json["expires_at"] as? NSNumber)?.doubleValue else {
            throw UploadError.server("Strava: \(json["message"] as? String ?? "no se pudieron obtener los tokens")")
        }
        tokens = Tokens(accessToken: access, refreshToken: refresh, expiresAt: expires)
        if let athlete = json["athlete"] as? [String: Any] {
            let first = athlete["firstname"] as? String ?? ""
            let last = athlete["lastname"] as? String ?? ""
            athleteName = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
        } else if athleteName == nil {
            athleteName = "tu cuenta"
        }
        saveSettings()
    }

    private func saveSettings() {
        let s = Settings(clientID: clientID, clientSecret: clientSecret, autoUpload: autoUpload,
                         athleteName: athleteName, tokens: tokens)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }
}
