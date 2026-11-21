import Foundation

/// El tipo de paisaje que pega con una ruta (para elegir el escenario del simulador).
public enum Scenery: String, CaseIterable, Sendable {
    /// Llano: prados abiertos.
    case meadow
    /// Ondulado: colinas.
    case rolling
    /// Rompepiernas: bosque.
    case forest
    /// Montaña: mucho desnivel o altitud.
    case mountain
    /// Nieve: alta montaña en invierno (o el norte en invierno).
    case snow

    /// Con la altitud, el desnivel, el sitio y la época del año. Las rutas sin GPX solo tienen el
    /// desnivel.
    public static func forRoute(_ route: Route, on date: Date = Date(), calendar: Calendar = .current) -> Scenery {
        let length = route.lengthMeters
        var top = 0.0
        var d = 0.0
        while d <= length {
            top = max(top, route.elevation(atDistance: d))
            d += 100
        }
        let maxAltitude = (route.startAltitude ?? 0) + top
        let latitude = route.track?.points.first?.latitude ?? 40
        let month = calendar.component(.month, from: date)
        let winter = [12, 1, 2].contains(month)
        let coldSeason = winter || [11, 3, 4].contains(month)

        if maxAltitude >= 2_400 || (coldSeason && maxAltitude >= 1_500) || (winter && maxAltitude >= 1_000)
            || (coldSeason && abs(latitude) >= 58) {
            return .snow
        }
        let perKm = route.climbPerKm
        if maxAltitude >= 1_000 || perKm >= 25 { return .mountain }
        if perKm >= 12 { return .forest }
        if perKm >= 5 { return .rolling }
        return .meadow
    }
}
