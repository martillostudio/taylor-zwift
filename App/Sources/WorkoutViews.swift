import CicloBluetooth
import CicloKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Colores de las zonas de potencia (los habituales en Zwift, TrainingPeaks…).
extension PowerZone {
    var color: Color {
        switch self {
        case .z1: Color(red: 0.55, green: 0.55, blue: 0.58)
        case .z2: Color(red: 0.20, green: 0.50, blue: 0.90)
        case .z3: Color(red: 0.20, green: 0.70, blue: 0.32)
        case .z4: Color(red: 0.96, green: 0.80, blue: 0.10)
        case .z5: Color(red: 0.96, green: 0.50, blue: 0.10)
        case .z6: Color(red: 0.86, green: 0.16, blue: 0.16)
        case .z7: Color(red: 0.55, green: 0.25, blue: 0.75)
        }
    }

    /// «< 110 W», «111–150 W», «> 300 W» con tu FTP.
    func wattsText(ftp: Int) -> String {
        let f = Double(ftp)
        let low = Int((range.low * f).rounded())
        guard let high = range.high else { return "> \(low) W" }
        let hi = Int((high * f).rounded())
        return self == .z1 ? "< \(hi) W" : "\(low)–\(hi) W"
    }
}

func formatClock(_ seconds: Double) -> String {
    let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond
    return Duration.seconds(max(seconds, 0)).formatted(.time(pattern: pattern))
}

// MARK: - Pestaña «Entrenar»

func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3_600, m = (seconds % 3_600) / 60
    return h > 0 ? (m > 0 ? "\(h) h \(m)'" : "\(h) h") : "\(m)'"
}

struct WorkoutsView: View {
    @Environment(RideController.self) private var ride
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var progressColumns: [GridItem] {
        var count = 2
        #if os(iOS)
        if sizeClass == .compact { count = 1 }
        #endif
        return Array(repeating: GridItem(.flexible(), spacing: Space.l, alignment: .top), count: count)
    }
    @State private var importing = false
    @State private var importError: String?

    private var zwoTypes: [UTType] {
        [UTType(filenameExtension: "zwo"), .xml].compactMap { $0 }
    }
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    TodayCard()
                    // Tu progreso: dos columnas en Mac e iPad, una en iPhone.
                    LazyVGrid(columns: progressColumns, alignment: .leading, spacing: Space.l) {
                        RoadAheadCard()
                        WeeklyLoadCard()
                        FitnessCard()
                        ImprovementCard()
                    }
                    PlanBox()
                    ProfileBox()

                    if ride.mode == .workout, let w = ride.workout {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Entreno cargado").font(Theme.font(.titleLarge)).foregroundStyle(Color.primary)
                            NavigationLink { WorkoutDetailView(workout: w) } label: {
                                WorkoutCard(workout: w).frame(maxWidth: 440)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ForEach(WorkoutCategory.allCases.filter { $0 != .imported }, id: \.self) { category in
                        let items = Workout.library.filter { $0.category == category }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(category.rawValue).font(Theme.font(.titleLarge)).foregroundStyle(Color.primary)
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                    ForEach(items) { w in
                                        NavigationLink { WorkoutDetailView(workout: w) } label: { WorkoutCard(workout: w) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(WorkoutCategory.imported.rawValue).font(Theme.font(.titleLarge)).foregroundStyle(Color.primary)
                            Spacer()
                            Button("Importar .zwo…", systemImage: "square.and.arrow.down") { importing = true }
                                .buttonStyle(.bordered)
                        }
                        if ride.importedWorkouts.isEmpty {
                            Text("Ficheros .zwo (el formato de Zwift): los que hagas tú o descargues.")
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(ride.importedWorkouts) { w in
                                NavigationLink { WorkoutDetailView(workout: w) } label: { WorkoutCard(workout: w) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Borrar", systemImage: "trash", role: .destructive) { ride.deleteImported(w) }
                                    }
                            }
                        }
                    }
                }
                .screenPadding()
            }
            .background(Theme.background)
            .navigationTitle("Entrenar")
            .fileImporter(isPresented: $importing, allowedContentTypes: zwoTypes, allowsMultipleSelection: true) { result in
                importFiles(result)
            }
            .alert("No se pudo importar", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("Vale", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            var errors: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    _ = try ride.importZwo(data, fileName: url.lastPathComponent)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !errors.isEmpty { importError = errors.joined(separator: "\n") }
        }
    }
}

/// FTP, peso, FC máxima y las zonas de potencia y de pulso.
private struct ProfileBox: View {
    @Environment(RideController.self) private var ride
    @Environment(IntervalsService.self) private var intervals

    var body: some View {
        @Bindable var ride = ride
        Card(style: .filled) {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Tu perfil", subtitle: "FTP, peso y frecuencia cardiaca máxima: de aquí salen tus zonas.")
                HStack(spacing: 24) {
                    Stepper("FTP: **\(ride.ftp) W**", value: $ride.ftp, in: 50...600, step: 5)
                    Stepper("Peso: **\(ride.weightKg.formatted(.number.precision(.fractionLength(1)))) kg**",
                            value: $ride.weightKg, in: 40...150, step: 0.5)
                    Stepper("FC máx.: **\(ride.maxHeartRate)**", value: $ride.maxHeartRate, in: 140...220)
                }
                Text("\((Double(ride.ftp) / ride.weightKg).formatted(.number.precision(.fractionLength(2)))) W/kg al FTP. Si no sabes tu FTP, haz el test de rampa: al terminar te propone el valor.")
                    .font(.caption).foregroundStyle(.secondary)
                if let eftp = intervals.estimatedFTP, abs(eftp - ride.ftp) >= 5 {
                    HStack(spacing: Space.m) {
                        Label("intervals.icu estima tu FTP en **\(eftp) W** con tus últimas salidas (eFTP).",
                              systemImage: "chart.line.uptrend.xyaxis")
                            .font(Theme.font(.bodyMedium))
                        Button("Usar \(eftp) W") { ride.ftp = eftp }.buttonStyle(.bordered)
                    }
                }
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Potencia").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(PowerZone.allCases, id: \.self) { zone in
                            ZoneLine(color: zone.color, title: "Z\(zone.rawValue) \(zone.name)", value: zone.wattsText(ftp: ride.ftp))
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pulso").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(HeartRateZone.allCases, id: \.self) { zone in
                            let r = zone.bpmRange(max: ride.maxHeartRate)
                            ZoneLine(color: zone.color, title: "Z\(zone.rawValue) \(zone.name)", value: "\(r.lowerBound)–\(r.upperBound)")
                        }
                    }
                }
            }
        }
    }
}

private struct ZoneLine: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(title)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: 300)
    }
}

extension HeartRateZone {
    var color: Color {
        switch self {
        case .z1: Color(red: 0.55, green: 0.55, blue: 0.58)
        case .z2: Color(red: 0.20, green: 0.50, blue: 0.90)
        case .z3: Color(red: 0.20, green: 0.70, blue: 0.32)
        case .z4: Color(red: 0.96, green: 0.50, blue: 0.10)
        case .z5: Color(red: 0.86, green: 0.16, blue: 0.16)
        }
    }
}

/// La semana del plan que toca: «hoy toca», cómo vas y acceso al plan entero.
private struct PlanBox: View {
    @Environment(RideController.self) private var ride
    @Environment(ActivityStore.self) private var store
    @Environment(IntervalsService.self) private var intervals

    var body: some View {
        @Bindable var ride = ride
        Card(style: .filled, padding: Space.xl) {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .top) {
                    SectionTitle(title: ride.plan.name, subtitle: ride.plan.summary)
                    Spacer()
                    DatePicker("Empieza el lunes", selection: $ride.planStart, displayedComponents: .date)
                        .fixedSize()
                }
                if let week = ride.currentPlanWeek {
                    let statuses = ride.planStatus(week)
                    if let next = ride.plan.nextSession(in: week, statuses: statuses) {
                        NextSessionBanner(session: next, week: week, status: statuses[next.id] ?? .upcoming)
                    } else {
                        Label("Semana completada. ¡Buen trabajo! Descansa hasta el lunes.", systemImage: "checkmark.seal.fill")
                            .font(Theme.font(.titleMedium)).foregroundStyle(Theme.positive)
                    }
                    PlanWeekView(week: week, isCurrent: true)
                } else if ride.planStart > Date() {
                    Text("Empieza el \(ride.planStart.formatted(date: .complete, time: .omitted)). Así será la primera semana:")
                        .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                    PlanWeekView(week: ride.plan.weeks[0], isCurrent: false)
                } else {
                    Text("Plan terminado. Pon una fecha nueva para repetirlo (con tu FTP nuevo).")
                        .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                }
                HStack(spacing: Space.m) {
                    NavigationLink {
                        PlanView()
                    } label: {
                        Label("Ver las 16 semanas", systemImage: "calendar")
                    }
                    .buttonStyle(.bordered)
                    OutdoorSyncLine()
                }
            }
        }
        .task { await ride.syncIntervals() }
    }
}

/// De dónde salen las salidas en exterior del plan: intervals.icu (que las trae de Garmin).
private struct OutdoorSyncLine: View {
    @Environment(RideController.self) private var ride
    @Environment(IntervalsService.self) private var intervals
    @State private var confirming = false

    private var pushTitle: String {
        guard let pushed = ride.planPushedStart else { return "Mandar a intervals.icu" }
        return pushed == ride.planStart ? "Volver a mandar a intervals.icu" : "Actualizar fechas en intervals.icu"
    }

    var body: some View {
        if intervals.isConnected {
            HStack(spacing: Space.s) {
                Button(pushTitle, systemImage: "calendar.badge.plus") { confirming = true }
                    .buttonStyle(.bordered)
                    .disabled(intervals.isBusy)
                    .confirmationDialog("¿Mandar el plan a intervals.icu?", isPresented: $confirming) {
                        Button("Mandar \(ride.plan.weeks.reduce(0) { $0 + $1.sessions.count }) sesiones") {
                            Task { await ride.pushPlanToIntervals() }
                        }
                    } message: {
                        Text("Se ponen en tu calendario desde el \(ride.planStart.formatted(date: .long, time: .omitted)). Si lo mandaste antes, se sustituye (no se duplica). Con la sincronización de Garmin activada, intervals.icu las pasa también a Garmin Connect y al reloj.")
                    }
                Text(syncText).font(Theme.font(.bodySmall)).foregroundStyle(Color.secondary)
                Button(intervals.isBusy ? "Sincronizando…" : "Actualizar", systemImage: "arrow.clockwise") {
                    Task { await ride.syncIntervals(force: true) }
                }
                .buttonStyle(.borderless)
                .disabled(intervals.isBusy)
            }
        } else {
            Button("Conecta intervals.icu para que tus salidas cuenten solas", systemImage: "link") {
                ride.selectedTab = "historial"
            }
            .buttonStyle(.borderless)
        }
    }

    private var syncText: String {
        let rides = intervals.outdoorRides.count
        let when = intervals.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "nunca"
        return "Salidas en exterior de intervals.icu: \(rides) · sincronizado \(when)"
    }
}

/// «Hoy toca»: la sesión siguiente del plan con un botón para cargarla.
private struct NextSessionBanner: View {
    let session: PlanSession
    let week: PlanWeek
    let status: PlanSessionStatus
    @Environment(RideController.self) private var ride

    private var title: String {
        switch status {
        case .today: "Hoy toca"
        case .partial: "A medias"
        default: "Próxima sesión · \(ride.date(of: session, in: week).formatted(.dateTime.weekday(.wide).day()))"
        }
    }

    var body: some View {
        HStack(spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title.uppercased()).font(Theme.font(.labelMedium)).tracking(0.6)
                    .foregroundStyle(Theme.accent.opacity(0.8))
                Text(session.workout?.name ?? "Salida en exterior").font(Theme.font(.titleLarge))
                    .foregroundStyle(Theme.accent)
                Text(session.workout.map { "\(formatDuration($0.durationSeconds)) · \($0.shortDescription)" } ?? session.note)
                    .font(Theme.font(.bodyMedium)).foregroundStyle(Theme.accent.opacity(0.8))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let w = session.workout {
                NavigationLink {
                    WorkoutDetailView(workout: w)
                        .onAppear {
                            // Se carga solo, salvo que estés en plena actividad con otra cosa.
                            if !ride.isRunning, ride.workout?.id != w.id || ride.mode != .workout { ride.load(w) }
                        }
                } label: {
                    Label("Ir al entreno", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Marcar hecha", systemImage: "checkmark") { ride.toggleManualMark(session, week: week) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Space.l)
        .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }
}

/// Una semana del plan: bloque, objetivo y sus sesiones con su estado.
struct PlanWeekView: View {
    let week: PlanWeek
    var isCurrent = false
    @Environment(RideController.self) private var ride
    @Environment(ActivityStore.self) private var store

    var body: some View {
        let statuses = ride.planStatus(week)
        let done = week.sessions.filter { statuses[$0.id]?.isDone == true }.count
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("Semana \(week.number)").font(Theme.font(.titleMedium))
                Text("\(week.block) · \(week.focus)").font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(done)/\(week.sessions.count)")
                    .font(Theme.font(.labelLarge, numeric: true))
                    .foregroundStyle(done == week.sessions.count ? Theme.positive : Color.secondary)
                if isCurrent {
                    Text("ESTA SEMANA").font(Theme.font(.labelSmall))
                        .padding(.horizontal, Space.s).padding(.vertical, 2)
                        .background(Theme.neutralFill, in: Capsule())
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: Space.m)],
                      alignment: .leading, spacing: Space.m) {
                ForEach(week.sessions) { session in
                    SessionCell(session: session, week: week, status: statuses[session.id] ?? .upcoming)
                }
            }
        }
    }
}

/// Una sesión: día, estado y su tarjeta (o la salida en exterior).
private struct SessionCell: View {
    let session: PlanSession
    let week: PlanWeek
    let status: PlanSessionStatus
    @Environment(RideController.self) private var ride

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(ride.date(of: session, in: week).formatted(.dateTime.weekday(.abbreviated).day()).uppercased())
                    .font(Theme.font(.labelMedium)).tracking(0.6).foregroundStyle(Color.secondary)
                Spacer()
                StatusBadge(status: status)
            }
            Group {
                if let w = session.workout {
                    NavigationLink { WorkoutDetailView(workout: w) } label: { WorkoutCard(workout: w, compact: true) }
                        .buttonStyle(.plain)
                } else {
                    OutdoorCard(note: session.note)
                }
            }
            .opacity(status.isDone || status == .skipped ? 0.6 : 1)
            if session.workout != nil, !session.note.isEmpty {
                Text(session.note).font(Theme.font(.bodySmall)).foregroundStyle(Color.secondary)
            }
        }
        .contextMenu {
            Button(ride.manualPlanMarks.contains(session.key(week: week.number)) ? "Quitar marca de hecha" : "Marcar como hecha",
                   systemImage: "checkmark.circle") {
                ride.toggleManualMark(session, week: week)
            }
        }
    }
}

private struct StatusBadge: View {
    let status: PlanSessionStatus

    var body: some View {
        let (text, icon, color): (String, String, Color) = switch status {
        case .done: ("Hecha", "checkmark.circle.fill", Theme.positive)
        case .partial(let f, _): ("\(Int((f * 100).rounded())) %", "circle.lefthalf.filled", Color.orange)
        case .today: ("Hoy", "circle.fill", Theme.accent)
        case .skipped: ("No hecha", "minus.circle", Color.secondary)
        case .upcoming: ("", "", Color.clear)
        }
        if !text.isEmpty {
            Label(text, systemImage: icon)
                .font(Theme.font(.labelMedium))
                .foregroundStyle(color)
        }
    }
}

private struct OutdoorCard: View {
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Image(systemName: "sun.max.fill").font(.title2).foregroundStyle(.orange)
            Text("Salida en exterior").font(Theme.font(.titleMedium))
            Text(note).font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Cuenta sola con una salida de 1 h 30 min o más en intervals.icu · o clic derecho → «Marcar como hecha»")
                .font(Theme.font(.labelSmall)).foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.separator))
    }
}

/// El plan completo, semana a semana.
struct PlanView: View {
    @Environment(RideController.self) private var ride

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(ride.plan.summary).foregroundStyle(.secondary)
                Text("Cómo funciona: 3 semanas de carga y 1 de descarga. La mayor parte del tiempo suave (Z2) y 2 días de calidad por semana: fuerza a cadencia baja, sweet spot/umbral y VO2max. Test de FTP al empezar y en las descargas para ajustar los vatios. Si un día no puedes, no lo recuperes: sigue con el siguiente.")
                    .font(.callout)
                ForEach(ride.plan.weeks) { week in
                    let current = ride.currentPlanWeek?.number == week.number
                    VStack(alignment: .leading, spacing: 4) {
                        PlanWeekView(week: week, isCurrent: current)
                        Text("Rodillo: \(formatDuration(week.plannedSeconds)) · TSS ≈ \(week.plannedTSS)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(week.isRecovery ? Color.green.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .screenPadding()
        }
        .background(Theme.background)
        .navigationTitle(ride.plan.name)
    }
}

/// Tarjeta de un entreno: perfil, nombre, en qué consiste, tiempo por zonas, duración y carga.
struct WorkoutCard: View {
    let workout: Workout
    var compact = false

    var body: some View {
        let zone = workout.mainZone
        VStack(alignment: .leading, spacing: 8) {
            WorkoutChart(workout: workout, height: compact ? 40 : 60, showAxes: false)
            HStack(alignment: .firstTextBaseline) {
                Text(workout.name).font(Theme.font(.titleMedium)).foregroundStyle(Color.primary)
                    .lineLimit(2, reservesSpace: !compact)
                Spacer(minLength: 4)
                if workout.ftpTest != nil {
                    Text("TEST").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2), in: Capsule())
                }
            }
            Text(workout.shortDescription)
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: !compact)
            ZoneBar(workout: workout)
            HStack(spacing: 12) {
                Label(formatDuration(workout.durationSeconds), systemImage: "clock")
                Label("TSS \(Int(workout.tss.rounded()))", systemImage: "bolt.fill")
                if workout.hasCadenceTargets {
                    Label("rpm", systemImage: "gauge.with.dots.needle.33percent")
                }
                Spacer(minLength: 0)
                // Siempre en una línea: si no cabe el nombre de la zona, solo «Z7».
                ViewThatFits(in: .horizontal) {
                    zoneBadge("Z\(zone.rawValue) \(zone.name)", zone)
                    zoneBadge("Z\(zone.rawValue)", zone)
                }
                .layoutPriority(1)
            }
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.separator))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(zone.color)
                .frame(height: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }

    private func zoneBadge(_ text: String, _ zone: PowerZone) -> some View {
        Text(text)
            .font(.caption2.bold())
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(zone == .z4 ? Color.black : Color.white)
            .background(zone.color, in: Capsule())
    }
}

/// Barra con el reparto del tiempo por zonas.
struct ZoneBar: View {
    let workout: Workout

    var body: some View {
        let byZone = workout.secondsByZone
        let total = max(byZone.values.reduce(0, +), 1)
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(PowerZone.allCases, id: \.self) { z in
                    if let s = byZone[z], s > 0 {
                        z.color.frame(width: geo.size.width * Double(s) / Double(total))
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }
}

/// Perfil del entreno: barras por tramo con el color de su zona (en % del FTP).
struct WorkoutChart: View {
    let workout: Workout
    var elapsed: Double?
    var height: CGFloat = 140
    var showAxes = true
    /// Lo que llevas hecho (vatios reales), dibujado encima del perfil.
    var trace: [RideController.TracePoint] = []
    var ftp: Int = 0
    /// Trozo a enseñar, en minutos (`nil` = el entreno entero).
    var window: ClosedRange<Double>?

    private struct TraceBucket: Identifiable {
        let id: Int
        let minute: Double
        let percent: Double
    }

    /// Medias de 10 s de la potencia real, en % del FTP.
    private var traceBuckets: [TraceBucket] {
        guard ftp > 0, !trace.isEmpty else { return [] }
        var result: [TraceBucket] = []
        var i = 0
        while i < trace.count {
            let chunk = trace[i..<min(i + 10, trace.count)]
            let avg = Double(chunk.map(\.power).reduce(0, +)) / Double(chunk.count)
            let t = chunk.map(\.t).reduce(0, +) / Double(chunk.count)
            result.append(TraceBucket(id: result.count, minute: t / 60, percent: avg / Double(ftp) * 100))
            i += 10
        }
        return result
    }

    /// % FTP que toca en el segundo `t` (`nil` en tramos libres).
    private func targetPercent(at t: Double) -> Double? {
        guard let s = workout.segments.last(where: { Double($0.startSeconds) <= t }) else { return nil }
        return s.power(at: t).map { $0 * 100 }
    }

    private struct Bar: Identifiable {
        let id: Int
        let start: Double // minutos
        let end: Double
        let power: Double // % FTP
        let color: Color
    }

    /// Las rampas se pintan en escalones de 30 s.
    private var bars: [Bar] {
        var result: [Bar] = []
        for s in workout.segments {
            let pieces = s.isRamp ? max(1, s.durationSeconds / 30) : 1
            let pieceSeconds = Double(s.durationSeconds) / Double(pieces)
            for i in 0..<pieces {
                let t0 = Double(s.startSeconds) + Double(i) * pieceSeconds
                let fraction = s.power(at: t0 + pieceSeconds / 2)
                result.append(Bar(
                    id: result.count,
                    start: t0 / 60,
                    end: (t0 + pieceSeconds) / 60,
                    power: (fraction ?? 0.5) * 100,
                    color: fraction.map { PowerZone(fractionOfFTP: $0).color } ?? Color.gray.opacity(0.35)
                ))
            }
        }
        return result
    }

    var body: some View {
        Chart {
            ForEach(bars) { b in
                RectangleMark(
                    xStart: .value("min", b.start), xEnd: .value("min", b.end),
                    yStart: .value("%", 0), yEnd: .value("%", b.power)
                )
                .foregroundStyle(b.color.opacity(elapsed.map { b.end * 60 <= $0 ? 0.35 : 1 } ?? 1))
            }
            ForEach(traceBuckets) { p in
                LineMark(x: .value("min", p.minute), y: .value("%", p.percent), series: .value("serie", "real"))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if showAxes {
                RuleMark(y: .value("%", 100))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let elapsed {
                RuleMark(x: .value("min", elapsed / 60))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("min", elapsed / 60), y: .value("%", targetPercent(at: elapsed) ?? 50))
                    .symbol(.circle)
                    .symbolSize(showAxes ? 160 : 70)
                    .foregroundStyle(Theme.accent)
                    .annotation(position: .top, spacing: 4) {
                        if showAxes {
                            Text("Estás aquí")
                                .font(Theme.font(.labelMedium)).foregroundStyle(Color.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
            }
        }
        .chartXScale(domain: window ?? 0...max(Double(workout.durationSeconds) / 60, 1))
        .chartXAxis(showAxes ? .automatic : .hidden)
        .chartYAxis(showAxes ? .automatic : .hidden)
        .chartXAxisLabel(showAxes ? "min" : "")
        .chartYAxisLabel(showAxes ? "% FTP" : "")
        .chartPlotStyle { $0.clipped() }
        .frame(height: height)
    }
}

// MARK: - Detalle y ejecución

struct WorkoutDetailView: View {
    let workout: Workout
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub

    private var isLoaded: Bool { ride.mode == .workout && ride.workout?.id == workout.id }

    @State private var showsSegments = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if isLoaded {
                    compactHeader
                    if let summary = ride.summary { summaryCard(summary) }
                    intervalCard
                    Card(style: .filled, padding: Space.xl) {
                        VStack(alignment: .leading, spacing: Space.l) {
                            LiveHero(showsTarget: false)
                            Divider().overlay(Theme.separator)
                            LiveStrip()
                        }
                    }
                    profileCard
                    DisclosureGroup(isExpanded: $showsSegments) {
                        segmentsList.padding(.top, Space.s)
                    } label: {
                        Text("Tramos (\(workout.segments.count))").font(Theme.font(.titleMedium))
                    }
                    .padding(Space.l)
                    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                } else {
                    header
                    Card(style: .filled) {
                        VStack(alignment: .leading, spacing: Space.m) {
                            Text("PERFIL").font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
                            WorkoutChart(workout: workout, height: 160)
                            ZoneBar(workout: workout)
                        }
                    }
                    Card(style: .outlined) { segmentsList }
                }
            }
            .screenPadding()
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle(workout.name)
        .overlay(alignment: .bottom) { actions.padding(Space.xl) }
    }

    private var header: some View {
        Card(style: .filled) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(workout.name).font(Theme.font(.headlineSmall)).foregroundStyle(Color.primary)
                        Text(workout.shortDescription).font(Theme.font(.titleSmall)).foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Chip(title: "Z\(workout.mainZone.rawValue) \(workout.mainZone.name)", dot: workout.mainZone.color)
                }
                Text(workout.summary).font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                HStack(spacing: Space.l) {
                    Stat(title: "Duración", value: formatDuration(workout.durationSeconds), size: .headlineSmall)
                    Stat(title: "TSS", value: "\(Int(workout.tss.rounded()))", size: .headlineSmall)
                    Stat(title: "IF", value: workout.intensityFactor.formatted(.number.precision(.fractionLength(2))), size: .headlineSmall)
                    Stat(title: "Con tu FTP", value: "\(ride.ftp)", unit: "W", size: .headlineSmall)
                }
            }
        }
    }

    /// Mientras entrenas, la cabecera se queda en una línea: nombre, zona y FTP.
    private var compactHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.name).font(Theme.font(.headlineSmall)).foregroundStyle(Color.primary)
                Text("\(formatDuration(workout.durationSeconds)) · TSS \(Int(workout.tss.rounded())) · FTP \(ride.ftp) W")
                    .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
            }
            Spacer()
            if ride.isRunning {
                Label("Grabando", systemImage: "record.circle").font(Theme.font(.labelLarge)).foregroundStyle(Color.red)
            }
            Chip(title: "Z\(workout.mainZone.rawValue) \(workout.mainZone.name)", dot: workout.mainZone.color)
        }
    }

    /// Lo más importante durante un intervalo: cuánto queda, qué vatios tocan y qué viene después.
    private var intervalCard: some View {
        let progress = ride.workoutProgress
        let watts = ride.targetWatts
        let zone = progress?.target.map { PowerZone(fractionOfFTP: $0 * ride.intensity) }
        return Card(style: .filled, padding: Space.xl) {
            VStack(alignment: .leading, spacing: Space.l) {
                if let p = progress {
                    HStack(alignment: .top, spacing: Space.xl) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("TRAMO \(p.segment.id + 1) DE \(workout.segments.count) · \(p.segment.summary.uppercased())")
                                .font(Theme.font(.labelMedium)).tracking(0.6).foregroundStyle(Color.secondary)
                                .lineLimit(1)
                            Text(formatClock(p.secondsLeftInSegment))
                                .font(Theme.font(.displayLarge, numeric: true).weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.primary)
                            Text(p.next.map { "Después: \($0.summary)" } ?? "Último tramo")
                                .font(Theme.font(.bodyLarge)).foregroundStyle(Color.secondary)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: Space.xs) {
                            Text("OBJETIVO").font(Theme.font(.labelMedium)).tracking(0.6).foregroundStyle(Color.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                                Text(watts.map { "\($0)" } ?? "Libre")
                                    .font(Theme.font(.displayLarge, numeric: true).weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(zone?.color ?? Theme.accent)
                                if watts != nil {
                                    Text("W").font(Theme.font(.titleMedium)).foregroundStyle(Color.secondary)
                                }
                            }
                            Text(zone.map { "Z\($0.rawValue) · \($0.name)" } ?? "Marcha \(ride.gearText) · ↑/↓ pendiente")
                                .font(Theme.font(.labelLarge)).foregroundStyle(Color.secondary)
                        }
                    }
                    ProgressView(value: 1 - p.secondsLeftInSegment / Double(max(p.segment.durationSeconds, 1)))
                        .tint(zone?.color ?? Theme.accent)
                    if ride.heartRateAboveCap, let cap = ride.heartRateCap {
                        heartRateWarning(cap: cap)
                    }
                    intensityRow
                } else if ride.summary == nil {
                    HStack(spacing: Space.m) {
                        Image(systemName: "play.circle").font(.system(size: 28)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Listo para empezar").font(Theme.font(.titleLarge))
                            Text(hub.trainerConnection == .connected
                                 ? "Pulsa «Empezar» cuando estés pedaleando."
                                 : "Conecta el rodillo para empezar.")
                                .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
        }
    }

    /// En los entrenos de base el pulso manda: por encima del 70 % de la FC máxima ya no es Z2.
    private func heartRateWarning(cap: Int) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: "heart.fill").foregroundStyle(Color.orange)
            Text("Pulso por encima de Z2 (más de \(cap) ppm). Afloja un poco: hoy toca base.")
                .font(Theme.font(.bodyMedium))
            Spacer(minLength: 0)
            Button("−2 %", systemImage: "minus") { ride.easier() }
                .buttonStyle(.bordered)
        }
        .padding(Space.m)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
    }

    @ViewBuilder
    private var intensityRow: some View {
        if ride.intensityLocked {
            Label("Test: intensidad fija al 100 %. Mantén 85–95 rpm hasta el final.", systemImage: "lock.fill")
                .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
        } else if !ride.usesGears {
            HStack(spacing: Space.m) {
                Text("Intensidad").font(Theme.font(.labelLarge)).foregroundStyle(Color.secondary)
                IconButton(systemImage: "minus", size: 36) { ride.easier() }
                Text("\(Int((ride.intensity * 100).rounded())) %")
                    .font(Theme.font(.titleLarge, numeric: true)).monospacedDigit()
                    .frame(minWidth: 64)
                IconButton(systemImage: "plus", size: 36) { ride.harder() }
                Spacer(minLength: 0)
                Text("Mando derecho: + / Z suben · Y bajan · A empieza/pausa · B dos veces termina")
                    .font(Theme.font(.bodySmall)).foregroundStyle(Color.secondary)
            }
        }
    }

    /// Perfil: zoom de lo que viene (grande) y el entreno entero en una tira con tiempos.
    private var profileCard: some View {
        let minutes = ride.workoutSeconds / 60
        let total = Double(workout.durationSeconds) / 60
        let span = min(20, total)
        let lower = min(max(minutes - 5, 0), max(total - span, 0))
        return Card(style: .filled) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    Text(total > span ? "PRÓXIMOS MINUTOS" : "PERFIL")
                        .font(Theme.font(.labelMedium)).tracking(0.6).foregroundStyle(Color.secondary)
                    Spacer()
                    Label("Plan", systemImage: "square.fill").foregroundStyle(Color.secondary)
                    Label("Tu potencia", systemImage: "line.diagonal").foregroundStyle(Color.primary)
                }
                .font(Theme.font(.labelMedium))
                WorkoutChart(workout: workout, elapsed: ride.workoutSeconds, height: 180,
                             trace: ride.trace, ftp: ride.ftp,
                             window: total > span ? lower...(lower + span) : nil)
                if total > span {
                    WorkoutChart(workout: workout, elapsed: ride.workoutSeconds, height: 36, showAxes: false,
                                 trace: ride.trace, ftp: ride.ftp)
                    HStack {
                        Text(formatClock(ride.workoutSeconds)).monospacedDigit()
                        Spacer()
                        Text(formatDuration(workout.durationSeconds))
                    }
                    .font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private var segmentsList: some View {
        VStack(alignment: .leading, spacing: 2) {
                ForEach(workout.segments) { s in
                    let current = isLoaded && ride.workoutProgress?.segment.id == s.id
                    HStack(spacing: 10) {
                        Text(formatClock(Double(s.startSeconds))).monospacedDigit().foregroundStyle(Color.secondary)
                            .frame(width: 60, alignment: .leading)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(s.startPower.map { PowerZone(fractionOfFTP: max($0, s.endPower ?? $0)).color } ?? Color.gray)
                            .frame(width: 6, height: 18)
                        Text(s.summary)
                        Spacer()
                        Text(wattsText(s)).monospacedDigit().foregroundStyle(Color.secondary)
                    }
                    .font(Theme.font(current ? .titleSmall : .bodyMedium))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(current ? Theme.neutralFill : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                }
            }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if isLoaded {
                if hub.trainerConnection != .connected {
                    Button("Conectar", systemImage: "antenna.radiowaves.left.and.right") { hub.connectEverything() }
                        .buttonStyle(.bordered)
                }
                Button("Terminar", systemImage: "flag.checkered") { ride.finish() }
                    .buttonStyle(.bordered)
                    .disabled(ride.workoutSeconds == 0 || ride.summary != nil)
                Button("A cero", systemImage: "arrow.counterclockwise") { ride.reset() }
                    .buttonStyle(.borderless)
                if ride.isRunning {
                    ActionButton(title: "Pausa", systemImage: "pause.fill", prominent: false) { ride.pause() }
                } else {
                    ActionButton(title: "Empezar", systemImage: "play.fill") { ride.start() }
                        .disabled(hub.trainerConnection != .connected || ride.summary != nil)
                }
            } else {
                ActionButton(title: "Cargar este entreno", systemImage: "square.and.arrow.down.on.square") { ride.load(workout) }
            }
        }
        .padding(Space.s)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    private func wattsText(_ s: WorkoutSegment) -> String {
        guard let a = s.startPower, let b = s.endPower else { return "libre" }
        let f = Double(ride.ftp)
        let wa = Int((a * f).rounded()), wb = Int((b * f).rounded())
        return wa == wb ? "\(wa) W" : "\(wa)→\(wb) W"
    }

    private func summaryCard(_ s: RideSummary) -> some View {
        func w(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "—" }
        return Card(style: .outlined) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: "Resumen", subtitle: ride.lastSaved.map { "Guardado en el historial: \($0.name)" })
                    Spacer()
                    if let saved = ride.lastSaved {
                        GarminImportButton(activity: saved)
                        IntervalsBadge(activity: saved)
                        StravaBadge(activity: saved)
                    }
                }
                HStack(spacing: 16) {
                    Stat(title: "Mejor 1'", value: w(s.best1Min), unit: "W", size: .headlineSmall)
                    Stat(title: "Mejor 5'", value: w(s.best5Min), unit: "W", size: .headlineSmall)
                    Stat(title: "Mejor 20'", value: w(s.best20Min), unit: "W", size: .headlineSmall)
                    Stat(title: "TSS", value: ride.lastSaved?.tss.map { "\($0)" } ?? "—", size: .headlineSmall)
                }
                if let ftp = s.suggestedFTP {
                    HStack {
                        Text("FTP estimado: **\(ftp) W** (ahora tienes \(ride.ftp) W)").font(Theme.font(.bodyLarge))
                        Spacer()
                        Button("Usar \(ftp) W", systemImage: "checkmark") { ride.acceptSuggestedFTP() }
                            .buttonStyle(.borderedProminent)
                            .disabled(ftp == ride.ftp)
                    }
                } else if s.ftpTest != nil {
                    Text("No hay datos suficientes para estimar el FTP (la rampa necesita al menos 1 minuto; el test de 20', los 20 minutos).")
                        .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                }
                if let v = s.vo2max {
                    Text("VO2max estimado ≈ \(Int(v.rounded())) ml/kg/min con tu mejor 5' y \(ride.weightKg.formatted()) kg. Solo vale si esos 5' fueron a tope.")
                        .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                }
            }
        }
    }
}

private struct Info: View {
    let title: String
    let value: String
    var big = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(big ? .system(size: 28, weight: .semibold, design: .rounded) : .body)
                .monospacedDigit()
        }
    }
}
