import CicloBluetooth
import CicloKit
import SwiftUI

// MARK: - Espaciado

/// Escala de espaciado (múltiplos de 4). Úsala en vez de números sueltos.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

// MARK: - Celda de dato

/// Un dato en directo: etiqueta, número grande con su unidad y una línea de contexto.
/// La línea de contexto siempre ocupa su sitio (aunque esté vacía) para que las celdas
/// de una fila queden alineadas y no «salten» cuando aparece o desaparece.
struct MetricCell<Accessory: View>: View {
    let title: String
    let value: String
    var unit = ""
    var caption: String?
    var color: Color = Color.primary
    var captionColor: Color = Color.secondary
    var size: Theme.TypeStyle = .displayMedium
    var reservesCaption = true
    let accessory: Accessory

    init(_ title: String, _ value: String, unit: String = "", caption: String? = nil,
         color: Color = Color.primary, captionColor: Color = Color.secondary,
         size: Theme.TypeStyle = .displayMedium, reservesCaption: Bool = true,
         @ViewBuilder accessory: () -> Accessory) {
        self.reservesCaption = reservesCaption
        self.title = title
        self.value = value
        self.unit = unit
        self.caption = caption
        self.color = color
        self.captionColor = captionColor
        self.size = size
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title.uppercased())
                .font(Theme.font(.labelMedium)).tracking(0.6)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(value)
                    .font(Theme.font(size, numeric: true).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit).font(Theme.font(.titleSmall)).foregroundStyle(Color.secondary)
                }
            }
            accessory
            if caption != nil || reservesCaption {
                Text(caption ?? " ")
                    .font(Theme.font(.labelMedium))
                    .foregroundStyle(captionColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension MetricCell where Accessory == EmptyView {
    init(_ title: String, _ value: String, unit: String = "", caption: String? = nil,
         color: Color = Color.primary, captionColor: Color = Color.secondary,
         size: Theme.TypeStyle = .displayMedium, reservesCaption: Bool = true) {
        self.init(title, value, unit: unit, caption: caption, color: color, captionColor: captionColor,
                  size: size, reservesCaption: reservesCaption) { EmptyView() }
    }
}

/// Las cinco zonas de pulso en una barrita, con la actual resaltada.
struct HeartRateZoneMeter: View {
    let current: HeartRateZone?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(HeartRateZone.allCases, id: \.self) { z in
                Capsule()
                    .fill(z.color.opacity(z == current ? 1 : 0.22))
                    .frame(height: z == current ? 6 : 4)
            }
        }
        .frame(maxWidth: 160, minHeight: 6, maxHeight: 6)
        .animation(.easeOut(duration: 0.25), value: current)
        .accessibilityHidden(true)
    }
}

// MARK: - Datos principales

/// Los 3–4 números que importan ahora mismo. Cambian según el modo:
/// - con vatios fijos (ERG, tramos de entreno): objetivo, potencia, cadencia y pulso;
/// - con marchas (libre, ruta, tramos libres): potencia, velocidad, cadencia y pulso.
struct LiveHero: View {
    /// En la pantalla del entreno el objetivo ya sale en grande en la tarjeta del tramo.
    var showsTarget = true

    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Space.l, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.l) {
            if showsTarget, let target = ride.targetWatts {
                MetricCell("Objetivo", "\(target)", unit: "W",
                           caption: "\(percentFTP(target)) % FTP", color: Theme.accent)
            }
            power
            if ride.targetWatts == nil {
                MetricCell("Velocidad", one(ride.speedKmh), unit: "km/h",
                           caption: "marcha \(ride.gears.number)/\(ride.gears.count)")
            }
            cadence
            heartRate
        }
    }

    private var power: some View {
        let watts = ride.power3s
        let zone = watts.map { PowerZone(fractionOfFTP: Double($0) / Double(max(ride.ftp, 1))) }
        if let target = ride.targetWatts, let watts {
            let d = watts - target
            let onTarget = abs(d) <= 5
            return MetricCell("Potencia", "\(watts)", unit: "W",
                              caption: onTarget ? "en objetivo" : (d > 0 ? "+\(d) W" : "\(d) W"),
                              color: zone?.color ?? Color.primary,
                              captionColor: onTarget ? Theme.positive : Color.orange)
        }
        return MetricCell("Potencia", watts.map { "\($0)" } ?? "—", unit: "W",
                          caption: zone.map { "Z\($0.rawValue) · \($0.name)" },
                          color: zone?.color ?? Color.primary)
    }

    private var cadence: some View {
        let rpm = hub.bikeData.cadenceRpm.map { Int($0.rounded()) }
        let target = ride.workoutProgress?.segment.cadence
        let off = rpm.flatMap { r in target.map { abs(r - $0) > 5 } } ?? false
        return MetricCell("Cadencia", rpm.map { "\($0)" } ?? "—", unit: "rpm",
                          caption: target.map { "objetivo \($0) rpm" },
                          color: off ? Color.orange : Color.primary,
                          captionColor: off ? Color.orange : Color.secondary)
    }

    private var heartRate: some View {
        let bpm = hub.heartRateBpm
        let zone = bpm.map { HeartRateZone(bpm: $0, max: ride.maxHeartRate) }
        let caption: String? = if hub.heartRateConnection != .connected {
            "sin pulsómetro"
        } else {
            zone.map { "Z\($0.rawValue) · \($0.name)" }
        }
        return MetricCell("Pulso", bpm.map { "\($0)" } ?? "—", unit: "ppm", caption: caption,
                          color: zone?.color ?? Color.primary) {
            HeartRateZoneMeter(current: zone)
        }
    }

    private func percentFTP(_ watts: Int) -> Int {
        Int((Double(watts) / Double(max(ride.ftp, 1)) * 100).rounded())
    }

    private func one(_ v: Double?) -> String {
        v.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
    }
}

// MARK: - Datos secundarios

/// Una fila de 4 datos pequeños: lo acumulado que tiene sentido en cada modo.
struct LiveStrip: View {
    @Environment(RideController.self) private var ride

    private struct Item: Identifiable {
        let title: String
        let value: String
        var unit = ""
        var id: String { title }
    }

    private var items: [Item] {
        let time = Item(title: "Tiempo", value: formatClock(ride.session.movingSeconds))
        let avg = Item(title: "Potencia media", value: ride.session.averagePowerWatts.map { "\($0)" } ?? "—", unit: "W")
        let km = Item(title: "Distancia",
                      value: (ride.session.distanceMeters / 1000).formatted(.number.precision(.fractionLength(1))), unit: "km")
        switch ride.mode {
        case .route:
            return [time, km, Item(title: "Desnivel", value: "+\(Int(ride.elevationGain.rounded()))", unit: "m"), avg]
        case .erg:
            return [time, avg, Item(title: "Trabajo", value: "\(ride.session.workKilojoules)", unit: "kJ"),
                    Item(title: "Pulso medio", value: ride.session.averageHeartRateBpm.map { "\($0)" } ?? "—", unit: "ppm")]
        case .workout:
            let left = ride.workoutProgress?.secondsLeftInWorkout ?? Double(ride.workout?.durationSeconds ?? 0)
            return [Item(title: "Llevas", value: formatClock(ride.workoutSeconds)),
                    Item(title: "Quedan", value: formatClock(left)),
                    avg,
                    Item(title: "TSS", value: ride.liveTSS.map { "\($0)" } ?? "—")]
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: Space.l, alignment: .top)],
                  alignment: .leading, spacing: Space.m) {
            ForEach(items) { i in
                MetricCell(i.title, i.value, unit: i.unit, size: .headlineSmall, reservesCaption: false)
            }
        }
    }
}
