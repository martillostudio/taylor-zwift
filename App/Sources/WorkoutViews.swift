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

struct WorkoutsView: View {
    @Environment(RideController.self) private var ride
    @State private var importing = false
    @State private var importError: String?

    private var zwoTypes: [UTType] {
        [UTType(filenameExtension: "zwo"), .xml].compactMap { $0 }
    }

    var body: some View {
        @Bindable var ride = ride
        NavigationStack {
            List {
                Section {
                    Stepper("FTP: \(ride.ftp) W", value: $ride.ftp, in: 50...600, step: 5)
                    Stepper("Peso: \(ride.weightKg.formatted(.number.precision(.fractionLength(1)))) kg",
                            value: $ride.weightKg, in: 40...150, step: 0.5)
                    LabeledContent("W/kg al FTP",
                                   value: (Double(ride.ftp) / ride.weightKg).formatted(.number.precision(.fractionLength(2))))
                    ForEach(PowerZone.allCases, id: \.self) { zone in
                        HStack {
                            RoundedRectangle(cornerRadius: 3).fill(zone.color).frame(width: 14, height: 14)
                            Text("Z\(zone.rawValue) · \(zone.name)")
                            Spacer()
                            Text(zone.wattsText(ftp: ride.ftp)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                } header: {
                    Text("Tu perfil")
                } footer: {
                    Text("Si no sabes tu FTP, empieza por el test de rampa: al terminar te propone el valor.")
                }

                if ride.mode == .workout, let w = ride.workout {
                    Section("Entreno cargado") {
                        NavigationLink { WorkoutDetailView(workout: w) } label: { WorkoutRow(workout: w) }
                    }
                }

                ForEach(WorkoutCategory.allCases.filter { $0 != .imported }, id: \.self) { category in
                    let items = Workout.library.filter { $0.category == category }
                    if !items.isEmpty {
                        Section(category.rawValue) {
                            ForEach(items) { w in
                                NavigationLink { WorkoutDetailView(workout: w) } label: { WorkoutRow(workout: w) }
                            }
                        }
                    }
                }

                Section {
                    ForEach(ride.importedWorkouts) { w in
                        NavigationLink { WorkoutDetailView(workout: w) } label: { WorkoutRow(workout: w) }
                            .contextMenu {
                                Button("Borrar", systemImage: "trash", role: .destructive) { ride.deleteImported(w) }
                            }
                    }
                    Button("Importar entrenos .zwo…", systemImage: "square.and.arrow.down") { importing = true }
                } header: {
                    Text(WorkoutCategory.imported.rawValue)
                } footer: {
                    Text("Ficheros .zwo (el formato de Zwift): los que hayas hecho tú o descargado. Clic derecho para borrar.")
                }
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

/// Fila de la biblioteca: nombre, duración, TSS y perfil en miniatura.
struct WorkoutRow: View {
    let workout: Workout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(workout.name).font(.headline)
                Spacer()
                Text("\(workout.durationSeconds / 60)' · TSS \(Int(workout.tss.rounded()))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            WorkoutChart(workout: workout, height: 36, showAxes: false)
        }
        .padding(.vertical, 2)
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
                    } else {
                        Text("Libre").font(.system(size: 44, weight: .bold, design: .rounded))
                        Text("Marcha \(ride.gearText)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Metric(title: "Potencia", value: hub.bikeData.powerWatts.map { "\($0)" }, unit: "W")
                Metric(title: "Cadencia", value: hub.bikeData.cadenceRpm.map { "\(Int($0))" }, unit: "rpm")
                Metric(title: "Pulso", value: hub.heartRateBpm.map { "\($0)" }, unit: "ppm")
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
