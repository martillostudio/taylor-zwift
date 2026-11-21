import Foundation

/// Posición del sol (aproximación de la NOAA, error < 1°): suficiente para pintar el cielo del
/// simulador según la hora y el sitio.
public enum Sun {
    public struct Position: Equatable, Sendable {
        /// Altura sobre el horizonte, en grados (negativa = de noche).
        public var elevation: Double
        /// `true` antes del mediodía solar (el sol sube).
        public var isMorning: Bool
        /// Ángulo horario normalizado: −1 (medianoche, mañana) … 0 (mediodía) … 1 (medianoche).
        public var hourAngle: Double
    }

    public static func position(at date: Date, latitude: Double, longitude: Double) -> Position {
        let rad = Double.pi / 180
        let n = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
        let meanLongitude = (280.460 + 0.985_647_4 * n).truncatingRemainder(dividingBy: 360)
        let anomaly = (357.528 + 0.985_600_3 * n).truncatingRemainder(dividingBy: 360) * rad
        let eclipticLongitude = (meanLongitude + 1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)) * rad
        let obliquity = (23.439 - 0.000_000_4 * n) * rad
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let sidereal = (280.460_618_37 + 360.985_647_366_29 * n + longitude) * rad
        var hour = (sidereal - rightAscension).truncatingRemainder(dividingBy: 2 * .pi)
        if hour > .pi { hour -= 2 * .pi }
        if hour < -.pi { hour += 2 * .pi }
        let lat = latitude * rad
        let elevation = asin(sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hour))
        return Position(elevation: elevation / rad, isMorning: hour < 0, hourAngle: hour / .pi)
    }
}
