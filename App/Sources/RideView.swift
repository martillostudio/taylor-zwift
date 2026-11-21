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
                        // En ruta la marcha va aquí, con los datos: todo en una pantalla.
                        if gearsInHero {
                            Divider().overlay(M3.outlineVariant)
                            GearControl(compact: true)
                        }
                    }
                }

                switch ride.mode {
                case .free: freeCard
                case .route: routeCards
                case .erg: ergCard
                case .workout: workoutCard
                }

                if ride.usesGears, !gearsInHero { gearCard }
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

    private var gearsInHero: Bool { ride.mode == .route && ride.usesGears }

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
            let asleep = hub.clicks.filter { $0.asleep && $0.connection != .connected }.count
            M3Chip(title: "\(clicks) \(clicks == 1 ? "mando" : "mandos")" + (asleep > 0 ? " · \(asleep) 💤" : ""),
                   systemImage: "gamecontroller", dot: clicks > 0 ? Color.green : (asleep > 0 ? Color.orange : M3.outline))
                .help(asleep > 0 ? "Un mando se ha dormido por no usarlo. Púlsalo una vez para despertarlo (esa pulsación no cuenta)." : "")
            M3Chip(title: hub.heartRateBpm.map { "\($0) ppm" } ?? "Pulso", systemImage: "heart", dot: color(hub.heartRateConnection))
            if hub.trainerConnection != .connected || hub.heartRateConnection != .connected || clicks + asleep == 0 {
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
        // Elegir ruta solo antes de empezar: cambiarla a mitad (aunque sea en pausa) cerraría la salida.
        if !ride.isRunning, ride.session.movingSeconds == 0 {
            RoutePicker { importingGPX = true }
        }
        if ride.route.id.hasPrefix("gpx-") {
            selectedRouteCards
        }
    }

    /// Perfil con «estás aquí» (2/3) y mapa siguiéndote (1/3); debajo, la subida y la lista de subidas.
    @ViewBuilder
    private var selectedRouteCards: some View {
        SplitRow(fraction: 2.0 / 3.0, spacing: Space.l) {
            routeProfileCard
            if let track = ride.route.track {
                RouteMapCard(route: ride.route, track: track, distance: ride.session.distanceMeters,
                             mapHeight: nil, followsOnAppear: ride.isRunning || ride.session.movingSeconds > 0)
            }
        }
        if let status = ride.climbStatus { climbCard(status) }
        if !ride.route.climbs.isEmpty { climbListCard }
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
        let d = ride.session.distanceMeters
        let position = route.positionInLap(d)
        let left = max(route.lengthMeters - position, 0)
        let climbLeft = route.chunks(from: position, to: route.lengthMeters, size: 25)
            .reduce(0) { $0 + max($1.endElevation - $1.startElevation, 0) }
        return M3Card(style: .filled) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.name).font(M3.font(.titleMedium)).lineLimit(1)
                        Text("km \(km(position)) de \(km(route.lengthMeters)) · quedan \(km(left)) km y +\(Int(climbLeft.rounded())) m")
                            .font(M3.font(.bodyMedium, numeric: true)).foregroundStyle(M3.onSurfaceVariant)
                    }
                    Spacer()
                    Text("\(Int(route.elevation(atDistance: d).rounded())) m")
                        .font(M3.font(.titleMedium, numeric: true)).foregroundStyle(M3.onSurfaceVariant)
                        .help("Altura donde estás")
                }
                GradeProfileChart(chunks: route.chunks(from: 0, to: route.lengthMeters, size: max(route.lengthMeters / 150, 25)),
                                  doneUpTo: position, marker: position, markerLabel: "Estás aquí", height: 150)
                HStack(alignment: .center, spacing: Space.l) {
                    GradeTile(grade: ride.currentGrade)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PRÓXIMOS 2 KM").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                        GradeProfileChart(chunks: route.chunks(from: d, to: d + previewMeters, size: 25),
                                          xOffset: d, height: 70)
                    }
                }
                if route.isFinished(atDistance: d) {
                    Label("¡Ruta terminada! Sigues en llano.", systemImage: "flag.checkered")
                        .font(M3.font(.titleMedium)).foregroundStyle(M3.tertiary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var climbListCard: some View {
        M3Card(style: .filled) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SUBIDAS DE LA RUTA").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                    Spacer()
                    GradeLegend()
                }
                ForEach(ride.route.climbs) { c in
                    let done = c.endMeters <= ride.route.positionInLap(ride.session.distanceMeters)
                    HStack {
                        Image(systemName: done ? "checkmark.circle.fill" : "mountain.2.fill")
                            .foregroundStyle(done ? M3.outline : c.category.band.color)
                        Text("km \(km(c.startMeters))–\(km(c.endMeters))").font(M3.font(.bodyMedium))
                        Spacer()
                        Text("\(km(c.lengthMeters)) km al \(c.averageGradePercent.formatted(.number.precision(.fractionLength(1)))) % · \(c.category.label)")
                            .font(M3.font(.bodyMedium)).foregroundStyle(M3.onSurfaceVariant)
                    }
                    .opacity(done ? 0.6 : 1)
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
        M3Card(style: .filled) { GearControl() }
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

/// La marcha: número, combinación, rayitas y botones − / + (y el desarrollo de la bici).
/// En compacto va en una línea dentro de la tarjeta de datos (modo ruta).
struct GearControl: View {
    var compact = false
    @Environment(RideController.self) private var ride

    var body: some View {
        @Bindable var ride = ride
        HStack(spacing: compact ? Space.l : 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MARCHA").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(ride.gears.number)")
                        .font(M3.font(compact ? .headlineMedium : .displayMedium, numeric: true).weight(.semibold))
                    Text("/ \(ride.gears.count)").font(M3.font(.titleMedium)).foregroundStyle(M3.onSurfaceVariant)
                    if compact {
                        Text("\(ride.gears.gear.label) · \(meters) m").font(M3.font(.titleSmall))
                            .foregroundStyle(M3.onSurfaceVariant)
                    }
                }
                if !compact {
                    Text("\(ride.gears.gear.label) · \(meters) m por pedalada")
                        .font(M3.font(.bodySmall)).foregroundStyle(M3.onSurfaceVariant)
                }
            }
            .fixedSize()
            GearStrip(count: ride.gears.count, current: ride.gears.index)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            M3IconButton(systemImage: "minus", size: compact ? 48 : 56) { ride.easier() }
                .help("Marcha más blanda")
            M3IconButton(systemImage: "plus", size: compact ? 48 : 56) { ride.harder() }
                .help("Marcha más dura")
            Picker("Desarrollo", selection: $ride.drivetrain) {
                ForEach(Drivetrain.all) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var meters: String {
        ride.gears.gear.developmentMeters.formatted(.number.precision(.fractionLength(1)))
    }
}

/// Dos bloques en fila: el primero ocupa `fraction` del ancho y el segundo el resto, los dos
/// con la misma altura. En pantallas estrechas (iPhone) van uno debajo del otro.
struct SplitRow: Layout {
    var fraction: CGFloat
    var spacing: CGFloat
    var minWidthSideBySide: CGFloat = 640

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let first = ((total - spacing) * fraction).rounded()
        return (first, total - spacing - first)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 900
        guard subviews.count == 2, total >= minWidthSideBySide else {
            let hs = subviews.map { $0.sizeThatFits(ProposedViewSize(width: total, height: nil)).height }
            return CGSize(width: total, height: hs.reduce(0, +) + spacing * CGFloat(max(hs.count - 1, 0)))
        }
        let (w1, w2) = widths(total)
        let h = max(subviews[0].sizeThatFits(ProposedViewSize(width: w1, height: nil)).height,
                    subviews[1].sizeThatFits(ProposedViewSize(width: w2, height: nil)).height)
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2, bounds.width >= minWidthSideBySide else {
            var y = bounds.minY
            for v in subviews {
                let h = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                v.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + spacing
            }
            return
        }
        let (w1, w2) = widths(bounds.width)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: w1, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + w1 + spacing, y: bounds.minY),
                          proposal: ProposedViewSize(width: w2, height: bounds.height))
    }
}
