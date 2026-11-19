import CicloBluetooth
import CicloKit
import Charts
import SwiftUI

/// Pestaña «Rodar»: el entrenamiento de verdad (Fase 2).
struct RideView: View {
    @Environment(BluetoothHub.self) private var hub
    @Environment(RideController.self) private var ride

    var body: some View {
        @Bindable var ride = ride
        Form {
            Section {
                HStack {
                    StatusDot(state: hub.trainerConnection)
                    Text("Rodillo: \(hub.trainerName ?? "—") · \(hub.trainerConnection.description)")
                    Spacer()
                    Text("Mandos: \(hub.clicks.filter { $0.connection == .connected }.count)")
                        .foregroundStyle(.secondary)
                }
                Button("Conectar rodillo y mandos", systemImage: "antenna.radiowaves.left.and.right") {
                    hub.connectEverything()
                }
            } footer: {
                Text("Cierra Zwift, MyWhoosh y la app de Wahoo antes. Si algo se desconecta, se reconecta solo.")
            }

            Section {
                Picker("Modo", selection: $ride.mode) {
                    ForEach(RideController.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if ride.mode == .route {
                    Picker("Ruta", selection: $ride.route) {
                        ForEach(Route.builtIn) { Text($0.name).tag($0) }
                    }
                    RouteProfile(route: ride.route, distance: ride.session.distanceMeters)
                }
            }

            Section("En vivo") {
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
                        Metric(title: "Media", value: ride.session.averagePowerWatts.map { "\($0)" }, unit: "W")
                    }
                    GridRow {
                        if ride.mode == .route {
                            Metric(title: "Pendiente",
                                   value: ride.currentGrade.formatted(.number.precision(.fractionLength(1))),
                                   unit: "%")
                            Metric(title: "Marcha", value: "\(ride.gears.number)", unit: "/ \(ride.gears.count)")
                        } else {
                            Metric(title: "Objetivo", value: "\(ride.ergWatts)", unit: "W")
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                        Metric(title: "Trabajo", value: "\(ride.session.workKilojoules)", unit: "kJ")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if ride.mode == .route, ride.route.isFinished(atDistance: ride.session.distanceMeters) {
                    Label("¡Ruta terminada! Sigues en llano.", systemImage: "flag.checkered")
                }
            }

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
        .formStyle(.grouped)
    }
}

/// Perfil de la ruta con tu posición.
private struct RouteProfile: View {
    let route: Route
    let distance: Double

    var body: some View {
        let points = route.profile()
        let position = route.positionInLap(distance)
        let minElevation = points.map(\.elevationMeters).min() ?? 0
        Chart {
            ForEach(points, id: \.self) { p in
                AreaMark(
                    x: .value("km", p.distanceMeters / 1000),
                    yStart: .value("m", minElevation),
                    yEnd: .value("m", p.elevationMeters)
                )
                .foregroundStyle(Color.accentColor.opacity(0.25))
                LineMark(x: .value("km", p.distanceMeters / 1000), y: .value("m", p.elevationMeters))
            }
            RuleMark(x: .value("km", position / 1000))
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXAxisLabel("km")
        .chartYAxisLabel("m")
        .frame(height: 140)
        Text("\((route.lengthMeters / 1000).formatted(.number.precision(.fractionLength(1)))) km · +\(Int(route.climbMeters)) m"
             + (route.isLoop ? " por vuelta" : ""))
            .font(.caption)
            .foregroundStyle(.secondary)
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
