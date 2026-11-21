import CicloBluetooth
import CicloKit
import SwiftUI
import UniformTypeIdentifiers

/// Pestaña «Rodar»: el entrenamiento en vivo, con Material 3 y vista 2D tipo Garmin / Wahoo.
struct RideView: View {
    @Environment(BluetoothHub.self) private var hub
    @Environment(RideController.self) private var ride
    @Environment(StravaService.self) private var strava

    /// Metros del adelanto del perfil (como el «2 km» de Wahoo).
    private let previewMeters = 2_000.0
    @State private var importingGPX = false
    @State private var importError: String?

    var body: some View {
        @Bindable var ride = ride
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header
                M3SegmentedButtons(options: [
                    (RideController.Mode.free, "Libre", "bicycle"),
                    (.route, "Ruta", "map"),
                    (.erg, "ERG", "bolt"),
                    (.workout, "Entreno", "list.bullet.rectangle"),
                ], selection: $ride.mode)

                if let summary = ride.summary, ride.mode != .workout { summaryCard(summary) }

                M3Card(style: .filled, padding: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.l) {
                        LiveHero()
                        Divider().overlay(M3.outlineVariant)
                        LiveStrip()
                    }
                }

                switch ride.mode {
                case .free: freeCard
                case .route: routeCards
                case .erg: ergCard
                case .workout: workoutCard
                }

                if ride.usesGears { gearCard }
            }
            .padding(Space.xl)
            .padding(.bottom, 96) // sitio para la barra de acciones flotante
            .frame(maxWidth: Space.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(M3.surface)
        .overlay(alignment: .bottom) { actionBar.padding(Space.xl) }
        .fileImporter(isPresented: $importingGPX,
                      allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]) { result in
            importGPX(result)
        }
        .alert("No se pudo importar la ruta", isPresented: Binding(get: { importError != nil },
                                                                 set: { if !$0 { importError = nil } })) {
            Button("Vale", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func importGPX(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let r = try ride.importGPX(Data(contentsOf: url), fileName: url.lastPathComponent)
            ride.route = r
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: Cabecera y conexión

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rodar").font(M3.font(.headlineMedium)).foregroundStyle(M3.onSurface)
                Text(ride.isRunning ? "Grabando · \(ride.activityName)" : "Listo para rodar")
                    .font(M3.font(.bodyMedium)).foregroundStyle(ride.isRunning ? M3.primary : M3.onSurfaceVariant)
            }
            Spacer()
            M3Chip(title: hub.trainerName ?? "Rodillo", systemImage: "bicycle", dot: color(hub.trainerConnection))
            let clicks = hub.clicks.filter { $0.connection == .connected }.count
            M3Chip(title: "\(clicks) mandos", systemImage: "gamecontroller", dot: clicks > 0 ? Color.green : M3.outline)
            M3Chip(title: hub.heartRateBpm.map { "\($0) ppm" } ?? "Pulso", systemImage: "heart", dot: color(hub.heartRateConnection))
            if hub.trainerConnection != .connected || hub.heartRateConnection != .connected || clicks == 0 {
                Button("Conectar", systemImage: "antenna.radiowaves.left.and.right") { hub.connectEverything() }
                    .buttonStyle(.m3Tonal)
            }
        }
    }

    private func color(_ state: ConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: M3.outline
        }
    }

    // MARK: Modo libre

    private var freeCard: some View {
        M3Card(style: .filled) {
            VStack(alignment: .leading, spacing: 14) {
                M3SectionTitle(title: "Entreno libre", subtitle: "Tú eliges la pendiente (o con la cruceta ↑/↓ del mando izquierdo) y la marcha.")
                HStack(spacing: 16) {
                    GradeTile(grade: ride.freeGrade)
                    M3IconButton(systemImage: "minus") { ride.setFreeGrade(ride.freeGrade - RideController.freeGradeStep) }
                    Slider(value: Binding(get: { ride.freeGrade }, set: { ride.setFreeGrade($0) }),
                           in: -10...20, step: RideController.freeGradeStep)
                        .tint(GradeBand(gradePercent: ride.freeGrade).color)
                    M3IconButton(systemImage: "plus") { ride.setFreeGrade(ride.freeGrade + RideController.freeGradeStep) }
                }
                HStack(spacing: 8) {
                    ForEach([-2.0, 0, 3, 6, 8, 10, 12], id: \.self) { g in
                        Button { ride.setFreeGrade(g) } label: {
                            M3Chip(title: "\(Int(g)) %", selected: ride.freeGrade == g, dot: GradeBand(gradePercent: g).color)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Ruta

    @ViewBuilder
    private var routeCards: some View {
        @Bindable var ride = ride
        M3Card(style: .filled) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    M3SectionTitle(title: ride.route.name,
                                   subtitle: "\(km(ride.route.lengthMeters)) km · +\(Int(ride.route.climbMeters)) m\(ride.route.isLoop ? " por vuelta" : "")")
                    Spacer()
                    Picker("Ruta", selection: $ride.route) {
                        Section("Incluidas") {
                            ForEach(Route.builtIn) { Text($0.name).tag($0) }
                        }
                        if !ride.importedRoutes.isEmpty {
                            Section("Mis rutas") {
                                ForEach(ride.importedRoutes) { Text($0.name).tag($0) }
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Menu {
                        Button("Importar GPX…", systemImage: "square.and.arrow.down") { importingGPX = true }
                        if ride.route.id.hasPrefix("gpx-") {
                            Button("Borrar «\(ride.route.name)»", systemImage: "trash", role: .destructive) {
                                ride.deleteRoute(ride.route)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 20))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Importar una ruta GPX (de Garmin Connect, Strava, Komoot…)")
                }
                HStack(alignment: .center, spacing: 16) {
                    GradeTile(grade: ride.currentGrade)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PRÓXIMOS 2 KM").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                        let d = ride.session.distanceMeters
                        GradeProfileChart(chunks: ride.route.chunks(from: d, to: d + previewMeters, size: 25),
                                          xOffset: d, height: 90)
                    }
                }
                if ride.route.isFinished(atDistance: ride.session.distanceMeters) {
                    Label("¡Ruta terminada! Sigues en llano.", systemImage: "flag.checkered")
                        .font(M3.font(.titleMedium)).foregroundStyle(M3.tertiary)
                }
            }
        }
        if let status = ride.climbStatus { climbCard(status) }
        if let track = ride.route.track {
            RouteMapCard(route: ride.route, track: track, distance: ride.session.distanceMeters)
        }
        routeProfileCard
    }

    private func climbCard(_ status: ClimbStatus) -> some View {
        let c = status.climb
        let d = ride.session.distanceMeters
        let absStart = status.isOnClimb ? d - (ride.route.positionInLap(d) - c.startMeters) : d + status.distanceToStart
        let chunks = ride.route.chunks(from: absStart, to: absStart + c.lengthMeters, size: max(c.lengthMeters / 40, 25))
        let band = c.category.band
        return M3Card(style: .outlined) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "mountain.2.fill").foregroundStyle(band.color)
                    Text(status.isOnClimb ? "Subida en curso" : "Subida a la vista").font(M3.font(.titleMedium))
                    Spacer()
                    M3Chip(title: c.category.label, dot: band.color)
                }
                HStack(spacing: 16) {
                    if status.isOnClimb {
                        M3Stat(title: "Quedan", value: km(status.remainingMeters), unit: "km", size: .headlineMedium)
                        M3Stat(title: "Desnivel", value: "+\(Int(status.remainingAscentMeters.rounded()))", unit: "m", size: .headlineMedium)
                        M3Stat(title: "Media restante", value: status.remainingAverageGradePercent.formatted(.number.precision(.fractionLength(1))),
                               unit: "%", size: .headlineMedium)
                    } else {
                        M3Stat(title: "Empieza en", value: km(status.distanceToStart), unit: "km", size: .headlineMedium)
                        M3Stat(title: "Longitud", value: km(c.lengthMeters), unit: "km", size: .headlineMedium)
                        M3Stat(title: "Media", value: c.averageGradePercent.formatted(.number.precision(.fractionLength(1))),
                               unit: "%", size: .headlineMedium)
                    }
                }
                ProgressView(value: status.progress).tint(band.color)
                GradeProfileChart(chunks: chunks, xOffset: absStart,
                                  doneUpTo: status.isOnClimb ? d : nil, marker: status.isOnClimb ? d : nil, height: 110)
            }
        }
    }

    private var routeProfileCard: some View {
        let route = ride.route
        let position = route.positionInLap(ride.session.distanceMeters)
        return M3Card(style: .filled) {
            VStack(alignment: .leading, spacing: 10) {
                Text("PERFIL DE LA RUTA").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                GradeProfileChart(chunks: route.chunks(from: 0, to: route.lengthMeters, size: max(route.lengthMeters / 150, 25)),
                                  doneUpTo: position, marker: position, height: 140)
                GradeLegend()
                ForEach(route.climbs) { c in
                    HStack {
                        Image(systemName: "mountain.2.fill").foregroundStyle(c.category.band.color)
                        Text("km \(km(c.startMeters))–\(km(c.endMeters))").font(M3.font(.bodyMedium))
                        Spacer()
                        Text("\(km(c.lengthMeters)) km al \(c.averageGradePercent.formatted(.number.precision(.fractionLength(1)))) % · \(c.category.label)")
                            .font(M3.font(.bodyMedium)).foregroundStyle(M3.onSurfaceVariant)
                    }
                }
            }
        }
    }

    // MARK: ERG y entreno

    private var ergCard: some View {
        M3Card(style: .filled) {
            HStack(spacing: 16) {
                M3SectionTitle(title: "ERG", subtitle: "El rodillo mantiene la potencia aunque cambies la cadencia. Mantén más de ~70 rpm.")
                Spacer()
                M3IconButton(systemImage: "minus") { ride.easier() }
                Text("\(ride.ergWatts) W").font(M3.font(.displaySmall, numeric: true).weight(.semibold)).monospacedDigit()
                M3IconButton(systemImage: "plus") { ride.harder() }
            }
        }
    }

    private var workoutCard: some View {
        M3Card(style: .filled) {
            HStack(spacing: 16) {
                M3SectionTitle(title: ride.workout?.name ?? "Ningún entreno cargado",
                               subtitle: ride.workoutProgress.map { "Tramo: \($0.segment.summary) · quedan \(formatClock($0.secondsLeftInSegment))" }
                                   ?? "Elige uno en «Entrenar»: allí ves los intervalos en grande.")
                Spacer()
                Button("Ir a Entrenar", systemImage: "list.bullet.rectangle") { ride.selectedTab = "entrenar" }
                    .buttonStyle(.m3Tonal)
            }
        }
    }

    // MARK: Marchas

    private var gearCard: some View {
        @Bindable var ride = ride
        return M3Card(style: .filled) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MARCHA").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(ride.gears.number)").font(M3.font(.displayMedium, numeric: true).weight(.semibold))
                        Text("/ \(ride.gears.count)").font(M3.font(.titleMedium)).foregroundStyle(M3.onSurfaceVariant)
                    }
                    Text("\(ride.gears.gear.label) · \(ride.gears.gear.developmentMeters.formatted(.number.precision(.fractionLength(1)))) m por pedalada")
                        .font(M3.font(.bodySmall)).foregroundStyle(M3.onSurfaceVariant)
                }
                GearStrip(count: ride.gears.count, current: ride.gears.index)
                Spacer()
                M3IconButton(systemImage: "minus", size: 56) { ride.easier() }
                M3IconButton(systemImage: "plus", size: 56) { ride.harder() }
                Picker("Desarrollo", selection: $ride.drivetrain) {
                    ForEach(Drivetrain.all) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: Acciones y resumen

    private var actionBar: some View {
        HStack(spacing: 12) {
            if ride.mode != .workout {
                Button("Terminar", systemImage: "flag.checkered") { ride.finish() }
                    .buttonStyle(.m3Outlined)
                    .disabled(ride.session.movingSeconds == 0)
            }
            Button("A cero", systemImage: "arrow.counterclockwise") { ride.reset() }
                .buttonStyle(.m3Text)
            if ride.isRunning {
                M3FAB(title: "Pausa", systemImage: "pause.fill", tone: M3.secondaryContainer, onTone: M3.onSecondaryContainer) { ride.pause() }
            } else {
                M3FAB(title: "Empezar", systemImage: "play.fill") { ride.start() }
                    .disabled(hub.trainerConnection != .connected)
            }
        }
        .padding(Space.s)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    private func summaryCard(_ s: RideSummary) -> some View {
        M3Card(style: .outlined) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    M3SectionTitle(title: "Resumen", subtitle: ride.lastSaved.map { "Guardado en el historial: \($0.name)" })
                    Spacer()
                    if let saved = ride.lastSaved {
                        GarminImportButton(activity: saved)
                        IntervalsBadge(activity: saved)
                        StravaBadge(activity: saved)
                    }
                }
                HStack(spacing: 16) {
                    M3Stat(title: "Mejor 1'", value: watts(s.best1Min), unit: "W", size: .headlineSmall)
                    M3Stat(title: "Mejor 5'", value: watts(s.best5Min), unit: "W", size: .headlineSmall)
                    M3Stat(title: "Mejor 20'", value: watts(s.best20Min), unit: "W", size: .headlineSmall)
                    M3Stat(title: "Pulso medio", value: ride.session.averageHeartRateBpm.map { "\($0)" } ?? "—", unit: "ppm", size: .headlineSmall)
                }
                if let v = s.vo2max {
                    Text("VO2max estimado ≈ \(Int(v.rounded())) ml/kg/min (solo vale si hiciste 5' a tope).")
                        .font(M3.font(.bodyMedium)).foregroundStyle(M3.onSurfaceVariant)
                }
            }
        }
    }

    private func watts(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))" } ?? "—"
    }

    private func km(_ meters: Double) -> String {
        (meters / 1000).formatted(.number.precision(.fractionLength(1)))
    }
}

/// Las marchas como una fila de rayas, con la actual resaltada (como un cambio electrónico).
private struct GearStrip: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i == current ? M3.primary : (i < current ? M3.primary.opacity(0.35) : M3.outlineVariant))
                    .frame(width: 6, height: 14 + CGFloat(i) / CGFloat(max(count - 1, 1)) * 26)
            }
        }
        .frame(height: 40)
    }
}

/// Estado de un entreno en Strava: subido (enlace) o botón para subirlo.
struct StravaBadge: View {
    let activity: Activity
    @Environment(RideController.self) private var ride
    @Environment(StravaService.self) private var strava

    var body: some View {
        if let id = activity.stravaActivityID, let url = URL(string: "https://www.strava.com/activities/\(id)") {
            Link(destination: url) {
                Label("Ver en Strava", systemImage: "arrow.up.right.square")
                    .font(M3.font(.labelLarge)).foregroundStyle(M3.strava)
            }
        } else if strava.isConnected {
            Button(strava.isUploading ? "Subiendo…" : "Subir a Strava", systemImage: "arrow.up.circle") {
                ride.uploadToStrava(activity)
            }
            .buttonStyle(.m3Tonal)
            .disabled(strava.isUploading)
        }
    }
}
