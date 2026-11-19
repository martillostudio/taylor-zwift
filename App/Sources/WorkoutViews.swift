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
    @State private var importing = false
    @State private var importError: String?

    private var zwoTypes: [UTType] {
        [UTType(filenameExtension: "zwo"), .xml].compactMap { $0 }
    }
    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ProfileBox()
                    FreeRideCard()
                    PlanBox()

                    if ride.mode == .workout, let w = ride.workout {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Entreno cargado").font(M3.font(.titleLarge)).foregroundStyle(M3.onSurface)
                            NavigationLink { WorkoutDetailView(workout: w) } label: {
                                WorkoutCard(workout: w).frame(maxWidth: 380)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ForEach(WorkoutCategory.allCases.filter { $0 != .imported }, id: \.self) { category in
                        let items = Workout.library.filter { $0.category == category }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(category.rawValue).font(M3.font(.titleLarge)).foregroundStyle(M3.onSurface)
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
                            Text(WorkoutCategory.imported.rawValue).font(M3.font(.titleLarge)).foregroundStyle(M3.onSurface)
                            Spacer()
                            Button("Importar .zwo…", systemImage: "square.and.arrow.down") { importing = true }
                                .buttonStyle(.m3Tonal)
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
                .padding(24)
            }
            .background(M3.surface)
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

/// Acceso al entreno libre: sin plan ni estructura, a tu aire.
private struct FreeRideCard: View {
    @Environment(RideController.self) private var ride

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "bicycle.circle.fill").font(.system(size: 40)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Entreno libre").font(M3.font(.titleLarge)).foregroundStyle(M3.onSurface)
                Text("Sin plan ni intervalos: eliges la pendiente y la marcha y ruedas a tu aire. Cuenta distancia, tiempo, potencia y pulso.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rodar libre", systemImage: "play.fill") { ride.startFreeRide() }
                .buttonStyle(.m3Filled)
        }
        .padding(14)
        .background(M3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: M3.Shape.medium))
        .overlay(RoundedRectangle(cornerRadius: M3.Shape.medium).strokeBorder(M3.outlineVariant))
    }
}

/// FTP, peso, FC máxima y las zonas de potencia y de pulso.
private struct ProfileBox: View {
    @Environment(RideController.self) private var ride

    var body: some View {
        @Bindable var ride = ride
        M3Card(style: .filled) {
            VStack(alignment: .leading, spacing: 12) {
                M3SectionTitle(title: "Tu perfil", subtitle: "FTP, peso y frecuencia cardiaca máxima: de aquí salen tus zonas.")
                HStack(spacing: 24) {
                    Stepper("FTP: **\(ride.ftp) W**", value: $ride.ftp, in: 50...600, step: 5)
                    Stepper("Peso: **\(ride.weightKg.formatted(.number.precision(.fractionLength(1)))) kg**",
                            value: $ride.weightKg, in: 40...150, step: 0.5)
                    Stepper("FC máx.: **\(ride.maxHeartRate)**", value: $ride.maxHeartRate, in: 140...220)
                }
                Text("\((Double(ride.ftp) / ride.weightKg).formatted(.number.precision(.fractionLength(2)))) W/kg al FTP. Si no sabes tu FTP, haz el test de rampa: al terminar te propone el valor.")
                    .font(.caption).foregroundStyle(.secondary)
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

/// La semana del plan que toca y acceso al plan entero.
private struct PlanBox: View {
    @Environment(RideController.self) private var ride

    var body: some View {
        @Bindable var ride = ride
        M3Card(style: .filled) {
            VStack(alignment: .leading, spacing: 12) {
                M3SectionTitle(title: ride.plan.name)
                HStack {
                    Text(ride.plan.summary).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("Empieza el lunes", selection: $ride.planStart, displayedComponents: .date)
                        .fixedSize()
                }
                if let week = ride.currentPlanWeek {
                    PlanWeekView(week: week, isCurrent: true)
                } else if ride.planStart > Date() {
                    Text("Empieza el \(ride.planStart.formatted(date: .complete, time: .omitted)). Así será la primera semana:")
                        .foregroundStyle(.secondary)
                    PlanWeekView(week: ride.plan.weeks[0], isCurrent: false)
                } else {
                    Text("Plan terminado. Pon una fecha nueva para repetirlo (con tu FTP nuevo).")
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    PlanView()
                } label: {
                    Label("Ver las 16 semanas", systemImage: "calendar")
                }
                .buttonStyle(.m3Tonal)
            }
        }
    }
}

/// Una semana del plan: bloque, objetivo y sus 3 sesiones en tarjetas.
struct PlanWeekView: View {
    let week: PlanWeek
    var isCurrent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Semana \(week.number)").font(M3.font(.titleMedium))
                Text("· \(week.block) · \(week.focus)").foregroundStyle(.secondary)
                Spacer()
                if isCurrent {
                    Text("ESTA SEMANA").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(week.sessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.day).font(.caption.bold()).foregroundStyle(.secondary)
                        if let w = session.workout {
                            NavigationLink { WorkoutDetailView(workout: w) } label: { WorkoutCard(workout: w, compact: true) }
                                .buttonStyle(.plain)
                        } else {
                            OutdoorCard(note: session.note)
                        }
                        if session.workout != nil, !session.note.isEmpty {
                            Text(session.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct OutdoorCard: View {
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "sun.max.fill").font(.title2).foregroundStyle(.orange)
            Text("Salida en exterior").font(.headline)
            Text(note).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(M3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: M3.Shape.medium))
        .overlay(RoundedRectangle(cornerRadius: M3.Shape.medium).strokeBorder(M3.outlineVariant))
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
            .padding(24)
        }
        .background(M3.surface)
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
                Text(workout.name).font(M3.font(.titleMedium)).foregroundStyle(M3.onSurface).lineLimit(2)
                Spacer(minLength: 4)
                if workout.ftpTest != nil {
                    Text("TEST").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2), in: Capsule())
                }
            }
            Text(workout.shortDescription)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            ZoneBar(workout: workout)
            HStack(spacing: 12) {
                Label(formatDuration(workout.durationSeconds), systemImage: "clock")
                Label("TSS \(Int(workout.tss.rounded()))", systemImage: "bolt.fill")
                if workout.hasCadenceTargets {
                    Label("rpm", systemImage: "gauge.with.dots.needle.33percent")
                }
                Spacer(minLength: 0)
                Text("Z\(zone.rawValue) \(zone.name)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(zone == .z4 ? Color.black : Color.white)
                    .background(zone.color, in: Capsule())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(M3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: M3.Shape.medium))
        .overlay(RoundedRectangle(cornerRadius: M3.Shape.medium).strokeBorder(M3.outlineVariant))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
                .fill(zone.color)
                .frame(height: 4)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
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
                    .foregroundStyle(M3.onSurface)
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
                    .foregroundStyle(M3.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("min", elapsed / 60), y: .value("%", targetPercent(at: elapsed) ?? 50))
                    .symbol(.circle)
                    .symbolSize(showAxes ? 160 : 70)
                    .foregroundStyle(M3.primary)
                    .annotation(position: .top, spacing: 4) {
                        if showAxes {
                            Text("Estás aquí")
                                .font(M3.font(.labelMedium)).foregroundStyle(M3.onPrimary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(M3.primary, in: Capsule())
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if isLoaded {
                    if let summary = ride.summary { summaryCard(summary) }
                    liveCard
                    LiveMetricsCard()
                } else {
                    M3Card(style: .filled) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PERFIL").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                            WorkoutChart(workout: workout, height: 160)
                            ZoneBar(workout: workout)
                        }
                    }
                }
                segmentsCard
            }
            .padding(24)
            .padding(.bottom, 80)
        }
        .background(M3.surface)
        .navigationTitle(workout.name)
        .overlay(alignment: .bottomTrailing) { actions.padding(24) }
    }

    private var header: some View {
        M3Card(style: .filled) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workout.name).font(M3.font(.headlineSmall)).foregroundStyle(M3.onSurface)
                        Text(workout.shortDescription).font(M3.font(.titleSmall)).foregroundStyle(M3.primary)
                    }
                    Spacer()
                    M3Chip(title: "Z\(workout.mainZone.rawValue) \(workout.mainZone.name)", dot: workout.mainZone.color)
                }
                Text(workout.summary).font(M3.font(.bodyMedium)).foregroundStyle(M3.onSurfaceVariant)
                HStack(spacing: 16) {
                    M3Stat(title: "Duración", value: formatDuration(workout.durationSeconds), size: .headlineSmall)
                    M3Stat(title: "TSS", value: "\(Int(workout.tss.rounded()))", size: .headlineSmall)
                    M3Stat(title: "IF", value: workout.intensityFactor.formatted(.number.precision(.fractionLength(2))), size: .headlineSmall)
                    M3Stat(title: "Con tu FTP", value: "\(ride.ftp)", unit: "W", size: .headlineSmall)
                }
            }
        }
    }

    private var liveCard: some View {
        let progress = ride.workoutProgress
        let watts = ride.targetWatts
        let zone = watts.map { PowerZone(fractionOfFTP: Double($0) / Double(max(ride.ftp, 1))) }
        let hrZone = hub.heartRateBpm.map { HeartRateZone(bpm: $0, max: ride.maxHeartRate) }
        return M3Card(style: .filled, padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    if let watts, let zone {
                        M3Stat(title: "Objetivo", value: "\(watts)", unit: "W", size: .displayLarge, color: zone.color,
                               caption: "Z\(zone.rawValue) \(zone.name) · \(Int((Double(watts) / Double(ride.ftp) * 100).rounded())) % FTP")
                    } else {
                        M3Stat(title: "Objetivo", value: progress == nil ? "—" : "Libre", size: .displayLarge,
                               caption: progress == nil ? nil : "Marcha \(ride.gearText)")
                    }
                    M3Stat(title: "Potencia 3 s", value: ride.power3s.map { "\($0)" } ?? "—", unit: "W", size: .displayMedium,
                           color: ride.power3s.map { PowerZone(fractionOfFTP: Double($0) / Double(max(ride.ftp, 1))).color } ?? M3.onSurface,
                           caption: watts.flatMap { w in ride.power3s.map { p in deltaText(p - w) } })
                    M3Stat(title: "Cadencia", value: hub.bikeData.cadenceRpm.map { "\(Int($0))" } ?? "—", unit: "rpm", size: .displayMedium,
                           color: progress?.segment.cadence == nil ? M3.onSurface : .orange,
                           caption: progress?.segment.cadence.map { "Objetivo \($0) rpm" }, captionColor: .orange)
                    M3Stat(title: "Pulso", value: hub.heartRateBpm.map { "\($0)" } ?? "—", unit: "ppm", size: .displayMedium,
                           color: hrZone?.color ?? M3.onSurface, caption: hrZone.map { "Z\($0.rawValue) \($0.name)" })
                }
                profile
                if let p = progress {
                    HStack(alignment: .top, spacing: 16) {
                        M3Stat(title: "Queda en el tramo", value: formatClock(p.secondsLeftInSegment), size: .displaySmall, color: M3.primary)
                        M3Stat(title: "Siguiente", value: p.next?.summary ?? "Fin", size: .titleLarge)
                        M3Stat(title: "Queda en total", value: formatClock(p.secondsLeftInWorkout), size: .headlineMedium)
                    }
                    ProgressView(value: ride.workoutSeconds, total: Double(workout.durationSeconds))
                        .tint(zone?.color ?? M3.primary)
                } else if ride.summary == nil {
                    Text("Pulsa «Empezar» cuando estés listo.").font(M3.font(.bodyLarge)).foregroundStyle(M3.onSurfaceVariant)
                }
                HStack(spacing: 12) {
                    Text("Intensidad").font(M3.font(.labelLarge)).foregroundStyle(M3.onSurfaceVariant)
                    M3IconButton(systemImage: "minus", size: 40) { ride.easier() }
                    Text("\(Int((ride.intensity * 100).rounded())) %").font(M3.font(.titleLarge, numeric: true)).monospacedDigit()
                    M3IconButton(systemImage: "plus", size: 40) { ride.harder() }
                    Spacer()
                    Text("Mandos: + / Z suben, − / Y bajan (en tramos libres, marchas).")
                        .font(M3.font(.bodySmall)).foregroundStyle(M3.onSurfaceVariant)
                }
            }
        }
    }

    private func deltaText(_ d: Int) -> String {
        abs(d) <= 3 ? "En objetivo" : (d > 0 ? "+\(d) W de más" : "\(d) W")
    }

    /// Perfil entero con «Estás aquí» y, debajo, un zoom de lo que viene (los próximos 15').
    private var profile: some View {
        let minutes = ride.workoutSeconds / 60
        let total = Double(workout.durationSeconds) / 60
        let span = min(20, total)
        let lower = min(max(minutes - 5, 0), max(total - span, 0))
        return VStack(alignment: .leading, spacing: 8) {
            WorkoutChart(workout: workout, elapsed: ride.workoutSeconds, height: 70, showAxes: false,
                         trace: ride.trace, ftp: ride.ftp)
            if total > span {
                Text("PRÓXIMOS MINUTOS").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                WorkoutChart(workout: workout, elapsed: ride.workoutSeconds, height: 170,
                             trace: ride.trace, ftp: ride.ftp, window: lower...(lower + span))
            } else {
                WorkoutChart(workout: workout, elapsed: ride.workoutSeconds, height: 170,
                             trace: ride.trace, ftp: ride.ftp)
            }
            HStack(spacing: 16) {
                Label("Plan", systemImage: "square.fill").foregroundStyle(M3.onSurfaceVariant)
                Label("Lo que llevas", systemImage: "line.diagonal").foregroundStyle(M3.onSurface)
            }
            .font(M3.font(.labelMedium))
        }
    }

    private var segmentsCard: some View {
        M3Card(style: .outlined) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TRAMOS").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                ForEach(workout.segments) { s in
                    let current = isLoaded && ride.workoutProgress?.segment.id == s.id
                    HStack(spacing: 10) {
                        Text(formatClock(Double(s.startSeconds))).monospacedDigit().foregroundStyle(M3.onSurfaceVariant)
                            .frame(width: 60, alignment: .leading)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(s.startPower.map { PowerZone(fractionOfFTP: max($0, s.endPower ?? $0)).color } ?? Color.gray)
                            .frame(width: 6, height: 18)
                        Text(s.summary)
                        Spacer()
                        Text(wattsText(s)).monospacedDigit().foregroundStyle(M3.onSurfaceVariant)
                    }
                    .font(M3.font(current ? .titleSmall : .bodyMedium))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(current ? M3.secondaryContainer : Color.clear, in: RoundedRectangle(cornerRadius: M3.Shape.small))
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if isLoaded {
                if hub.trainerConnection != .connected {
                    Button("Conectar", systemImage: "antenna.radiowaves.left.and.right") { hub.connectEverything() }
                        .buttonStyle(.m3Tonal)
                }
                Button("Terminar", systemImage: "flag.checkered") { ride.finish() }
                    .buttonStyle(.m3Outlined)
                    .disabled(ride.workoutSeconds == 0 || ride.summary != nil)
                Button("A cero", systemImage: "arrow.counterclockwise") { ride.reset() }
                    .buttonStyle(.m3Text)
                if ride.isRunning {
                    M3FAB(title: "Pausa", systemImage: "pause.fill", tone: M3.secondaryContainer, onTone: M3.onSecondaryContainer) { ride.pause() }
                } else {
                    M3FAB(title: "Empezar", systemImage: "play.fill") { ride.start() }
                        .disabled(hub.trainerConnection != .connected || ride.summary != nil)
                }
            } else {
                M3FAB(title: "Cargar este entreno", systemImage: "square.and.arrow.down.on.square") { ride.load(workout) }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: M3.Shape.extraLarge))
    }

    private func wattsText(_ s: WorkoutSegment) -> String {
        guard let a = s.startPower, let b = s.endPower else { return "libre" }
        let f = Double(ride.ftp)
        let wa = Int((a * f).rounded()), wb = Int((b * f).rounded())
        return wa == wb ? "\(wa) W" : "\(wa)→\(wb) W"
    }

    private func summaryCard(_ s: RideSummary) -> some View {
        func w(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "—" }
        return M3Card(style: .outlined) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    M3SectionTitle(title: "Resumen", subtitle: ride.lastSaved.map { "Guardado en el historial: \($0.name)" })
                    Spacer()
                    if let saved = ride.lastSaved {
                        GarminImportButton(activity: saved)
                        StravaBadge(activity: saved)
                    }
                }
                HStack(spacing: 16) {
                    M3Stat(title: "Mejor 1'", value: w(s.best1Min), unit: "W", size: .headlineSmall)
                    M3Stat(title: "Mejor 5'", value: w(s.best5Min), unit: "W", size: .headlineSmall)
                    M3Stat(title: "Mejor 20'", value: w(s.best20Min), unit: "W", size: .headlineSmall)
                    M3Stat(title: "TSS", value: ride.lastSaved?.tss.map { "\($0)" } ?? "—", size: .headlineSmall)
                }
                if let ftp = s.suggestedFTP {
                    HStack {
                        Text("FTP estimado: **\(ftp) W** (ahora tienes \(ride.ftp) W)").font(M3.font(.bodyLarge))
                        Spacer()
                        Button("Usar \(ftp) W", systemImage: "checkmark") { ride.acceptSuggestedFTP() }
                            .buttonStyle(.m3Filled)
                            .disabled(ftp == ride.ftp)
                    }
                } else if s.ftpTest != nil {
                    Text("No hay datos suficientes para estimar el FTP (la rampa necesita al menos 1 minuto; el test de 20', los 20 minutos).")
                        .font(M3.font(.bodyMedium)).foregroundStyle(M3.onSurfaceVariant)
                }
                if let v = s.vo2max {
                    Text("VO2max estimado ≈ \(Int(v.rounded())) ml/kg/min con tu mejor 5' y \(ride.weightKg.formatted()) kg. Solo vale si esos 5' fueron a tope.")
                        .font(M3.font(.bodyMedium)).foregroundStyle(M3.onSurfaceVariant)
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
