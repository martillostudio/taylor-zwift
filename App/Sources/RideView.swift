import CicloBluetooth
import CicloKit
import SwiftUI

/// Pestaña «Rodar»: el entrenamiento, con vista 2D al estilo de un Garmin / Wahoo.
struct RideView: View {
    @Environment(BluetoothHub.self) private var hub
    @Environment(RideController.self) private var ride

    /// Metros del adelanto del perfil (como el «2 km» de Wahoo).
    private let previewMeters = 2_000.0

    var body: some View {
        @Bindable var ride = ride
        Form {
            connectionSection

            Section {
                Picker("Modo", selection: $ride.mode) {
                    ForEach(RideController.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if ride.mode == .route {
                    Picker("Ruta", selection: $ride.route) {
                        ForEach(Route.builtIn) { Text($0.name).tag($0) }
                    }
                    Picker("Desarrollo", selection: $ride.drivetrain) {
                        ForEach(Drivetrain.all) { Text($0.name).tag($0) }
                    }
                }
            }

            dashboardSection

            if ride.mode == .route {
                if let status = ride.climbStatus {
                    climbSection(status)
                }
                previewSection
                routeSection
            }

            controlsSection
        }
        .formStyle(.grouped)
    }

    // MARK: Conexión

    private var connectionSection: some View {
        Section {
            HStack(spacing: 16) {
                StatusDot(state: hub.trainerConnection)
                Text("Rodillo: \(hub.trainerName ?? "—")")
                Spacer()
                let clicks = hub.clicks.filter { $0.connection == .connected }.count
                Label("\(clicks)", systemImage: "gamecontroller")
                    .foregroundStyle(clicks > 0 ? Color.primary : Color.secondary)
                StatusDot(state: hub.heartRateConnection)
                Label(hub.heartRateName ?? "Pulsómetro", systemImage: "heart")
                    .foregroundStyle(hub.heartRateConnection == .connected ? Color.primary : Color.secondary)
            }
            Button("Conectar rodillo, mandos y pulsómetro", systemImage: "antenna.radiowaves.left.and.right") {
                hub.connectEverything()
            }
        } footer: {
            Text("Cierra Zwift, MyWhoosh y la app de Wahoo antes. Si algo se desconecta, se reconecta solo. El pulsómetro tiene que llevarse puesto para que se anuncie.")
        }
    }

    // MARK: Datos en vivo

    private var dashboardSection: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                if ride.mode == .route {
                    GradeTile(grade: ride.currentGrade)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Marcha").font(.caption).foregroundStyle(.secondary)
                        Text("\(ride.gears.number)")
                            .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("\(ride.gears.gear.label) · \(ride.gears.gear.developmentMeters.formatted(.number.precision(.fractionLength(1)))) m")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Metric(title: "Objetivo", value: "\(ride.ergWatts)", unit: "W")
                }
                Spacer()
                HeartTile(bpm: hub.heartRateBpm)
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Metric(title: "Potencia", value: hub.bikeData.powerWatts.map { "\($0)" }, unit: "W")
                    Metric(title: "Cadencia", value: hub.bikeData.cadenceRpm.map { "\(Int($0))" }, unit: "rpm")
                    Metric(title: "Velocidad",
                           value: ride.speedKmh.map { $0.formatted(.number.precision(.fractionLength(1))) },
                           unit: "km/h")
                }
                GridRow {
                    Metric(title: "Distancia",
                           value: (ride.session.distanceMeters / 1000).formatted(.number.precision(.fractionLength(2))),
                           unit: "km")
                    Metric(title: "Tiempo",
                           value: Duration.seconds(ride.session.movingSeconds)
                               .formatted(.time(pattern: .hourMinuteSecond)),
                           unit: "")
                    Metric(title: "Potencia media", value: ride.session.averagePowerWatts.map { "\($0)" }, unit: "W")
                }
                GridRow {
                    Metric(title: "Pulso medio", value: ride.session.averageHeartRateBpm.map { "\($0)" }, unit: "ppm")
                    Metric(title: "Pulso máx.", value: ride.session.maxHeartRateBpm.map { "\($0)" }, unit: "ppm")
                    Metric(title: "Trabajo", value: "\(ride.session.workKilojoules)", unit: "kJ")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if ride.mode == .route, ride.route.isFinished(atDistance: ride.session.distanceMeters) {
                Label("¡Ruta terminada! Sigues en llano.", systemImage: "flag.checkered")
            }
        }
    }

    // MARK: Subida (tipo ClimbPro)

    private func climbSection(_ status: ClimbStatus) -> some View {
        let c = status.climb
        let d = ride.session.distanceMeters
        // Distancias absolutas de la subida (en circular, pueden ser de la vuelta siguiente).
        let absStart = status.isOnClimb ? d - (ride.route.positionInLap(d) - c.startMeters) : d + status.distanceToStart
        let chunkSize = max(c.lengthMeters / 40, 25)
        let chunks = ride.route.chunks(from: absStart, to: absStart + c.lengthMeters, size: chunkSize)
        let band = c.category.band
        return Section {
            HStack(alignment: .firstTextBaseline) {
                if status.isOnClimb {
                    ClimbNumber(title: "Quedan", value: km(status.remainingMeters), unit: "km")
                    ClimbNumber(title: "Desnivel", value: "+\(Int(status.remainingAscentMeters.rounded()))", unit: "m")
                    ClimbNumber(title: "Media restante",
                                value: status.remainingAverageGradePercent.formatted(.number.precision(.fractionLength(1))),
                                unit: "%")
                } else {
                    ClimbNumber(title: "Empieza en", value: km(status.distanceToStart), unit: "km")
                    ClimbNumber(title: "Longitud", value: km(c.lengthMeters), unit: "km")
                    ClimbNumber(title: "Media",
                                value: c.averageGradePercent.formatted(.number.precision(.fractionLength(1))),
                                unit: "%")
                }
            }
            ProgressView(value: status.progress)
                .tint(band.color)
            GradeProfileChart(chunks: chunks, xOffset: absStart,
                              doneUpTo: status.isOnClimb ? d : nil,
                              marker: status.isOnClimb ? d : nil,
                              height: 120)
        } header: {
            HStack {
                Image(systemName: "mountain.2.fill").foregroundStyle(band.color)
                Text(status.isOnClimb ? "Subida en curso" : "Subida a la vista")
                Spacer()
                Text("\(km(c.lengthMeters)) km al \(c.averageGradePercent.formatted(.number.precision(.fractionLength(1)))) % · \(c.category.label)")
            }
        }
    }

    // MARK: Perfiles

    private var previewSection: some View {
        let d = ride.session.distanceMeters
        return Section {
            GradeProfileChart(chunks: ride.route.chunks(from: d, to: d + previewMeters, size: 25),
                              xOffset: d, height: 110)
        } header: {
            Text("Próximos 2 km")
        }
    }

    private var routeSection: some View {
        let route = ride.route
        let position = route.positionInLap(ride.session.distanceMeters)
        let chunkSize = max(route.lengthMeters / 150, 25)
        let climbs = route.climbs
        return Section {
            GradeProfileChart(chunks: route.chunks(from: 0, to: route.lengthMeters, size: chunkSize),
                              doneUpTo: position, marker: position, height: 150)
            GradeLegend()
            Text("\(km(route.lengthMeters)) km · +\(Int(route.climbMeters)) m" + (route.isLoop ? " por vuelta" : ""))
                .font(.caption).foregroundStyle(.secondary)
            if climbs.isEmpty {
                Text("Sin subidas puntuables (repechos de menos de 500 m o del 3 %).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(climbs) { c in
                HStack {
                    Image(systemName: "mountain.2.fill").foregroundStyle(c.category.band.color)
                    Text("km \(km(c.startMeters))–\(km(c.endMeters))")
                    Spacer()
                    Text("\(km(c.lengthMeters)) km al \(c.averageGradePercent.formatted(.number.precision(.fractionLength(1)))) % · +\(Int(c.ascentMeters)) m · \(c.category.label)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        } header: {
            Text("Ruta")
        }
    }

    // MARK: Controles

    private var controlsSection: some View {
        Section {
            HStack {
                if ride.isRunning {
                    Button("Pausa", systemImage: "pause.fill") { ride.pause() }
                } else {
                    Button("Empezar", systemImage: "play.fill") { ride.start() }
                        .disabled(hub.trainerConnection != .connected)
                }
                Button("A cero", systemImage: "arrow.counterclockwise") { ride.reset() }
                Spacer()
                Button(ride.mode == .route ? "Marcha −" : "−\(RideController.ergStep) W",
                       systemImage: "minus.circle") { ride.easier() }
                Button(ride.mode == .route ? "Marcha +" : "+\(RideController.ergStep) W",
                       systemImage: "plus.circle") { ride.harder() }
            }
        } footer: {
            Text(ride.mode == .route
                 ? "Mandos: + (dcha) o Z, marcha más dura; − (izq) o Y, más blanda. En una subida, baja de marcha para mantener la cadencia."
                 : "Mandos: + (dcha) o Z, +\(RideController.ergStep) W; − (izq) o Y, −\(RideController.ergStep) W. En ERG, mantén la cadencia por encima de ~70 rpm.")
        }
    }

    private func km(_ meters: Double) -> String {
        (meters / 1000).formatted(.number.precision(.fractionLength(1)))
    }
}

private struct ClimbNumber: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HeartTile: View {
    let bpm: Int?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label("Pulso", systemImage: "heart.fill").font(.caption).foregroundStyle(.red)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(bpm.map { "\($0)" } ?? "—")
                    .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                Text("ppm").foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatusDot: View {
    let state: ConnectionState

    var body: some View {
        Circle()
            .fill(state == .connected ? Color.green : state == .connecting ? Color.orange : Color.secondary)
            .frame(width: 10, height: 10)
    }
}
