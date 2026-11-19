import CicloKit
import Foundation
import Observation

/// Historial de entrenos: cada uno se guarda como JSON (todos los datos) y como .fit
/// (para Strava, Garmin Connect, intervals.icu…) en la carpeta de la app.
@MainActor
@Observable
final class ActivityStore {
    /// De la más reciente a la más antigua.
    private(set) var activities: [Activity] = []
    let folder: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("Actividades", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    func jsonURL(_ a: Activity) -> URL { folder.appendingPathComponent("\(a.id.uuidString).json") }

    /// Nombre de fichero legible: «2026-11-20 Sweet spot 2×20'.fit».
    func fitURL(_ a: Activity) -> URL {
        let day = a.start.formatted(.iso8601.year().month().day())
        let safe = a.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent("\(day) \(safe) \(a.id.uuidString.prefix(4)).fit")
    }

    func save(_ a: Activity) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(a).write(to: jsonURL(a), options: .atomic)
        try FITEncoder.encode(a).write(to: fitURL(a), options: .atomic)
        activities.removeAll { $0.id == a.id }
        activities.append(a)
        activities.sort { $0.start > $1.start }
    }

    func delete(_ a: Activity) {
        try? FileManager.default.removeItem(at: jsonURL(a))
        try? FileManager.default.removeItem(at: fitURL(a))
        activities.removeAll { $0.id == a.id }
    }

    func fitData(_ a: Activity) -> Data {
        FITEncoder.encode(a)
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        activities = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Activity.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start > $1.start }
    }
}
