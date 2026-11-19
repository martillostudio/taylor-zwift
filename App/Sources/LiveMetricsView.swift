import SwiftUI
import CicloKit
import CicloBluetooth

/// Todos los datos en directo que tienen sentido en un entreno: velocidad, pendiente,
/// distancia, desnivel, medias, NP/IF/TSS, trabajo, pulso y tiempo en cada zona.
struct LiveMetricsCard: View {
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        M3Card(style: .outlined) {
            VStack(alignment: .leading, spacing: 16) {
                Text("EN DIRECTO").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    tile("Velocidad", one(ride.speedKmh), "km/h",
                         caption: ride.gradeIsEquivalent ? "marcha \(ride.gears.number) · \(ride.gears.gear.label)" : nil)
                    tile("Pendiente", one(ride.currentGrade), "%",
                         color: GradeBand(gradePercent: ride.currentGrade).color,
                         caption: ride.gradeIsEquivalent ? "equivalente a tus vatios" : (ride.usesGears ? "↑/↓ en la cruceta" : nil))
                    tile("Distancia", two(ride.session.distanceMeters / 1000), "km")
                    tile("Desnivel +", "\(Int(ride.elevationGain.rounded()))", "m")
                    tile("Tiempo", formatClock(ride.session.movingSeconds), "")
                    tile("Potencia media", int(ride.session.averagePowerWatts), "W",
                         caption: "máx \(ride.session.maxPowerWatts) W")
                    tile("NP", int(ride.normalizedPower), "W",
                         caption: ride.liveIntensityFactor.map { "IF \($0.formatted(.number.precision(.fractionLength(2))))" })
                    tile("TSS", int(ride.liveTSS), "")
                    tile("Trabajo", "\(ride.session.workKilojoules)", "kJ", caption: "≈ \(ride.session.workKilojoules) kcal")
                    tile("W/kg", wkg, "", caption: "con \(ride.weightKg.formatted()) kg")
                    tile("Cadencia media", int(ride.averageCadence), "rpm")
                    tile("Pulso medio", int(ride.session.averageHeartRateBpm), "ppm",
                         caption: ride.session.maxHeartRateBpm.map { "máx \($0) ppm" })
                }
                heartRateZones
            }
        }
    }

    private var wkg: String {
        guard let p = ride.power3s, ride.weightKg > 0 else { return "—" }
        return (Double(p) / ride.weightKg).formatted(.number.precision(.fractionLength(1)))
    }

    /// Las cinco zonas de pulso: la tuya resaltada y el tiempo que llevas en cada una.
    private var heartRateZones: some View {
        let current = hub.heartRateBpm.map { HeartRateZone(bpm: $0, max: ride.maxHeartRate) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ZONAS DE PULSO").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                Spacer()
                if let bpm = hub.heartRateBpm {
                    Text("\(bpm) ppm · \(Int((Double(bpm) / Double(max(ride.maxHeartRate, 1)) * 100).rounded())) % FC máx")
                        .font(M3.font(.labelLarge, numeric: true)).foregroundStyle(current?.color ?? M3.onSurface)
                } else {
                    Text("Sin pulsómetro").font(M3.font(.labelLarge)).foregroundStyle(M3.onSurfaceVariant)
                }
            }
            HStack(spacing: 6) {
                ForEach(HeartRateZone.allCases, id: \.self) { z in
                    let active = z == current
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: M3.Shape.small)
                            .fill(z.color.opacity(active ? 1 : 0.3))
                            .frame(height: active ? 30 : 22)
                            .overlay(Text("Z\(z.rawValue)").font(M3.font(.labelLarge)).foregroundStyle(active ? Color.white : M3.onSurface))
                        Text(formatClock(ride.heartRateZoneSeconds[z] ?? 0))
                            .font(M3.font(.labelMedium, numeric: true)).monospacedDigit()
                            .foregroundStyle(M3.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: current)
        }
    }

    private func tile(_ title: String, _ value: String, _ unit: String,
                      color: Color = M3.onSurface, caption: String? = nil) -> some View {
        M3Stat(title: title, value: value, unit: unit, size: .headlineMedium, color: color, caption: caption)
            .padding(12)
            .background(M3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: M3.Shape.medium))
    }

    private func int(_ v: Int?) -> String { v.map { "\($0)" } ?? "—" }
    private func one(_ v: Double?) -> String { v.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—" }
    private func two(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(2))) }
}
