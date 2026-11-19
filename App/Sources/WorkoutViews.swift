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
                            Text("Entreno cargado").font(.title3.bold())
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
                                Text(category.rawValue).font(.title3.bold())
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
                            Text(WorkoutCategory.imported.rawValue).font(.title3.bold())
                            Spacer()
                            Button("Importar .zwo…", systemImage: "square.and.arrow.down") { importing = true }
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
                .padding(20)
            }
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
                Text("Entreno libre").font(.title3.bold())
                Text("Sin plan ni intervalos: eliges la pendiente y la marcha y ruedas a tu aire. Cuenta distancia, tiempo, potencia y pulso.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rodar libre", systemImage: "play.fill") { ride.startFreeRide() }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// FTP, peso, FC máxima y las zonas de potencia y de pulso.
private struct ProfileBox: View {
    @Environment(RideController.self) private var ride

    var body: some View {
        @Bindable var ride = ride
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(6)
        } label: {
            Label("Tu perfil", systemImage: "person.crop.circle")
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
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
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
            }
            .padding(6)
        } label: {
            Label(ride.plan.name, systemImage: "calendar.badge.clock")
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
                Text("Semana \(week.number)").font(.headline)
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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
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
            .padding(20)
        }
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
                Text(workout.name).font(.headline).lineLimit(2)
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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
                .fill(zone.color)
                .frame(height: 4)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Barra con el reparto del tiempo por zonas.
private struct ZoneBar: View {
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
                .foregroundStyle(b.color)
            }
            if showAxes {
                RuleMark(y: .value("%", 100))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let elapsed {
                RuleMark(x: .value("min", elapsed / 60))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXScale(domain: 0...max(Double(workout.durationSeconds) / 60, 1))
        .chartXAxis(showAxes ? .automatic : .hidden)
        .chartYAxis(showAxes ? .automatic : .hidden)
        .chartXAxisLabel(showAxes ? "min" : "")
        .chartYAxisLabel(showAxes ? "% FTP" : "")
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
        Form {
            Section {
                Text(workout.summary)
                HStack(spacing: 24) {
                    Info(title: "Duración", value: formatClock(Double(workout.durationSeconds)))
                    Info(title: "TSS", value: "\(Int(workout.tss.rounded()))")
                    Info(title: "IF", value: workout.intensityFactor.formatted(.number.precision(.fractionLength(2))))
                    Info(title: "Zona principal", value: "Z\(workout.mainZone.rawValue) \(workout.mainZone.name)")
                }
                WorkoutChart(workout: workout, elapsed: isLoaded ? ride.workoutSeconds : nil)
            }

            if isLoaded {
                liveSection
                controlsSection
                if let summary = ride.summary { summarySection(summary) }
            } else {
                Section {
                    Button("Cargar este entreno", systemImage: "square.and.arrow.down.on.square") { ride.load(workout) }
                } footer: {
                    Text("Con FTP \(ride.ftp) W. Los objetivos se mandan al rodillo en modo ERG; en los tramos libres vas en llano con tus marchas.")
                }
            }

            Section("Tramos") {
                ForEach(workout.segments) { s in
                    HStack {
                        Text(formatClock(Double(s.startSeconds))).monospacedDigit().foregroundStyle(.secondary)
                        Circle().fill(s.startPower.map { PowerZone(fractionOfFTP: max($0, s.endPower ?? $0)).color } ?? .gray)
                            .frame(width: 8, height: 8)
                        Text(s.summary)
                        Spacer()
                        Text(wattsText(s)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(workout.name)
    }

    private func wattsText(_ s: WorkoutSegment) -> String {
        guard let a = s.startPower, let b = s.endPower else { return "libre" }
        let f = Double(ride.ftp)
        let wa = Int((a * f).rounded()), wb = Int((b * f).rounded())
        return wa == wb ? "\(wa) W" : "\(wa)→\(wb) W"
    }

    private var liveSection: some View {
        let progress = ride.workoutProgress
        return Section {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Objetivo").font(.caption).foregroundStyle(.secondary)
                    if let watts = ride.targetWatts {
                        let zone = PowerZone(fractionOfFTP: Double(watts) / Double(ride.ftp))
                        Text("\(watts) W")
                            .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(zone.color)
                        Text("Z\(zone.rawValue) · \(Int((Double(watts) / Double(ride.ftp) * 100).rounded())) % FTP")
                            .font(.caption).foregroundStyle(.secondary)
                        if let rpm = progress?.segment.cadence {
                            Label("a \(rpm) rpm", systemImage: "gauge.with.dots.needle.33percent")
                                .font(.headline).foregroundStyle(.orange)
                        }
                    } else {
                        Text("Libre").font(.system(size: 44, weight: .bold, design: .rounded))
                        Text("Marcha \(ride.gearText)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Metric(title: "Potencia", value: hub.bikeData.powerWatts.map { "\($0)" }, unit: "W")
                Metric(title: "Cadencia", value: hub.bikeData.cadenceRpm.map { "\(Int($0))" }, unit: "rpm")
                VStack(alignment: .leading, spacing: 2) {
                    Metric(title: "Pulso", value: hub.heartRateBpm.map { "\($0)" }, unit: "ppm")
                    if let bpm = hub.heartRateBpm {
                        let z = HeartRateZone(bpm: bpm, max: ride.maxHeartRate)
                        Text("Z\(z.rawValue) \(z.name)").font(.caption).foregroundStyle(z.color)
                    }
                }
            }
            if let p = progress {
                HStack(spacing: 24) {
                    Info(title: "Queda en el tramo", value: formatClock(p.secondsLeftInSegment), big: true)
                    Info(title: "Siguiente", value: p.next?.summary ?? "fin")
                    Info(title: "Queda en total", value: formatClock(p.secondsLeftInWorkout))
                }
                ProgressView(value: ride.workoutSeconds, total: Double(workout.durationSeconds))
            } else if ride.summary == nil {
                Text("Pulsa «Empezar» cuando estés listo.").foregroundStyle(.secondary)
            }
        } header: {
            Text("En vivo")
        }
    }

    private var controlsSection: some View {
        Section {
            HStack {
                if ride.isRunning {
                    Button("Pausa", systemImage: "pause.fill") { ride.pause() }
                } else {
                    Button("Empezar", systemImage: "play.fill") { ride.start() }
                        .disabled(hub.trainerConnection != .connected || ride.summary != nil)
                }
                Button("Terminar", systemImage: "flag.checkered") { ride.finish() }
                    .disabled(ride.workoutSeconds == 0 || ride.summary != nil)
                Button("A cero", systemImage: "arrow.counterclockwise") { ride.reset() }
                Spacer()
                Text("Intensidad \(Int((ride.intensity * 100).rounded())) %").monospacedDigit()
                Button("", systemImage: "minus.circle") { ride.easier() }
                Button("", systemImage: "plus.circle") { ride.harder() }
            }
            if hub.trainerConnection != .connected {
                Button("Conectar rodillo, mandos y pulsómetro", systemImage: "antenna.radiowaves.left.and.right") {
                    hub.connectEverything()
                }
            }
        } footer: {
            Text("Mandos: + (dcha) o Z suben la intensidad un 2 % (en tramos libres, marcha más dura); − (izq) o Y la bajan. En ERG, mantén la cadencia por encima de ~70 rpm.")
        }
    }

    private func summarySection(_ s: RideSummary) -> some View {
        func w(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) W" } ?? "—" }
        return Section {
            HStack(spacing: 24) {
                Info(title: "Mejor 1'", value: w(s.best1Min))
                Info(title: "Mejor 5'", value: w(s.best5Min))
                Info(title: "Mejor 20'", value: w(s.best20Min))
                Info(title: "TSS (aprox.)", value: "\(Int(ride.session.movingSeconds / 3600 * 100 * pow(Double(ride.session.averagePowerWatts ?? 0) / Double(ride.ftp), 2)))")
            }
            if let ftp = s.suggestedFTP {
                HStack {
                    Text("FTP estimado: **\(ftp) W** (ahora tienes \(ride.ftp) W)")
                    Spacer()
                    Button("Usar \(ftp) W") { ride.acceptSuggestedFTP() }
                        .disabled(ftp == ride.ftp)
                }
            } else if s.ftpTest != nil {
                Text("No hay datos suficientes para estimar el FTP (el test de rampa necesita al menos 1 minuto; el de 20', los 20 minutos).")
                    .foregroundStyle(.secondary)
            }
            if let v = s.vo2max {
                Text("VO2max estimado: ≈ \(Int(v.rounded())) ml/kg/min con tu mejor 5' y \(ride.weightKg.formatted()) kg. Solo vale si esos 5' fueron a tope.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Resumen")
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
