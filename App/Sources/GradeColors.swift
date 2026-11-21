import CicloKit
import Charts
import SwiftUI

/// Colores de pendiente como en Garmin ClimbPro / Wahoo: verde 0–3 %, amarillo 3–6 %,
/// naranja 6–9 %, rojo 9–12 %, rojo oscuro > 12 %; las bajadas, en azul.
extension GradeBand {
    var color: Color {
        switch self {
        case .descent: Color(red: 0.36, green: 0.60, blue: 0.86)
        case .easy: Color(red: 0.20, green: 0.70, blue: 0.32)
        case .moderate: Color(red: 0.96, green: 0.80, blue: 0.10)
        case .hard: Color(red: 0.96, green: 0.50, blue: 0.10)
        case .veryHard: Color(red: 0.86, green: 0.16, blue: 0.16)
        case .extreme: Color(red: 0.50, green: 0.04, blue: 0.10)
        }
    }

    /// Color del texto encima de `color` (el amarillo necesita texto oscuro).
    var textColor: Color {
        self == .moderate ? .black : .white
    }
}

/// Perfil de altura pintado por trozos con el color de su pendiente.
struct GradeProfileChart: View {
    let chunks: [RouteChunk]
    /// Se resta a las distancias (para que el adelanto empiece en 0 km).
    var xOffset: Double = 0
    /// Lo recorrido hasta aquí se pinta en gris.
    var doneUpTo: Double?
    /// Línea vertical con tu posición.
    var marker: Double?
    /// Etiqueta sobre tu posición («Estás aquí»), con un punto en el perfil.
    var markerLabel: String?
    var height: CGFloat = 140

    var body: some View {
        let lows = chunks.map { min($0.startElevation, $0.endElevation) }
        let highs = chunks.map { max($0.startElevation, $0.endElevation) }
        let bottom = (lows.min() ?? 0) - 2
        let top = max(highs.max() ?? 0, bottom + 20) // en llano, que no parezca una montaña
        Chart {
            ForEach(chunks) { c in
                let done = doneUpTo.map { c.endMeters <= $0 } ?? false
                let color = done ? Color.gray.opacity(0.45) : c.band.color
                AreaMark(
                    x: .value("km", (c.startMeters - xOffset) / 1000),
                    yStart: .value("m", bottom),
                    yEnd: .value("m", c.startElevation),
                    series: .value("tramo", c.id)
                )
                .foregroundStyle(color)
                AreaMark(
                    x: .value("km", (c.endMeters - xOffset) / 1000),
                    yStart: .value("m", bottom),
                    yEnd: .value("m", c.endElevation),
                    series: .value("tramo", c.id)
                )
                .foregroundStyle(color)
            }
            if let marker {
                RuleMark(x: .value("km", (marker - xOffset) / 1000))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                if let markerLabel, let y = elevation(at: marker) {
                    PointMark(x: .value("km", (marker - xOffset) / 1000), y: .value("m", y))
                        .symbolSize(90)
                        .foregroundStyle(Color.primary)
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit, y: .fit)) {
                            Text(markerLabel)
                                .font(Theme.font(.labelMedium))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                        }
                }
            }
        }
        .chartYScale(domain: bottom...top)
        .chartLegend(.hidden)
        .chartXAxisLabel("km")
        .chartYAxisLabel("m")
        .frame(height: height)
    }

    /// Altura del perfil en `d` (interpolada dentro de su tramo).
    private func elevation(at d: Double) -> Double? {
        guard let c = chunks.first(where: { $0.startMeters <= d && d <= $0.endMeters }) ?? chunks.last else { return nil }
        let span = max(c.endMeters - c.startMeters, 1)
        let f = min(max((d - c.startMeters) / span, 0), 1)
        return c.startElevation + (c.endElevation - c.startElevation) * f
    }
}

/// Recuadro con la pendiente actual sobre su color (como el campo de pendiente de Wahoo).
struct GradeTile: View {
    let grade: Double

    var body: some View {
        let band = GradeBand(gradePercent: grade)
        VStack(alignment: .leading, spacing: 2) {
            Text("Pendiente").font(.caption)
            Text("\(grade.formatted(.number.precision(.fractionLength(1)))) %")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: 140, alignment: .leading)
        .foregroundStyle(band.textColor)
        .background(band.color, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Leyenda de colores.
struct GradeLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(GradeBand.allCases, id: \.self) { band in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(band.color).frame(width: 12, height: 8)
                    Text(band.label)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
