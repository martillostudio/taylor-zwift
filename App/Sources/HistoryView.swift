import AuthenticationServices
import CicloBluetooth
import CicloKit
import Charts
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Historial de entrenos guardados, totales y conexión con Strava.
struct HistoryView: View {
    @Environment(ActivityStore.self) private var store

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Historial").font(Theme.font(.headlineMedium)).foregroundStyle(Color.primary)
                    TotalsCard()
                    IntervalsCard()
                    GarminCard()
                    StravaCard()
                    if store.activities.isEmpty {
                        Card(style: .outlined) {
                            Label("Aún no hay entrenos guardados. Cada entreno de más de 1 minuto se guarda al pulsar «Terminar» (o al ponerlo a cero).",
                                  systemImage: "tray")
                                .font(Theme.font(.bodyLarge)).foregroundStyle(Color.secondary)
                        }
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(store.activities) { a in
                            NavigationLink { ActivityDetailView(activityID: a.id) } label: { ActivityCard(activity: a) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(24)
            }
            .background(Theme.background)
        }
    }
}

/// Esta semana y este mes: entrenos, horas, km y TSS.
private struct TotalsCard: View {
    @Environment(ActivityStore.self) private var store

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let week = store.activities.filter { cal.isDate($0.start, equalTo: now, toGranularity: .weekOfYear) }
        let month = store.activities.filter { cal.isDate($0.start, equalTo: now, toGranularity: .month) }
        Card(style: .filled) {
            HStack(spacing: 24) {
                totals("Esta semana", week)
                Divider().overlay(Theme.separator)
                totals("Este mes", month)
            }
        }
    }

    private func totals(_ title: String, _ list: [Activity]) -> some View {
        let seconds = list.reduce(0) { $0 + $1.timerSeconds }
        let km = list.reduce(0) { $0 + $1.distanceMeters } / 1000
        let tss = list.compactMap(\.tss).reduce(0, +)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
            HStack(spacing: 16) {
                Stat(title: "Entrenos", value: "\(list.count)", size: .headlineMedium)
                Stat(title: "Tiempo", value: formatDuration(Int(seconds)), size: .headlineMedium)
                Stat(title: "Distancia", value: km.formatted(.number.precision(.fractionLength(0))), unit: "km", size: .headlineMedium)
                Stat(title: "TSS", value: "\(tss)", size: .headlineMedium)
            }
        }
    }
}

/// Conexión con Strava: pasos para crear tu «app» de Strava, conectar y subida automática.
/// intervals.icu: subida automática con la clave de API (gratis, sin suscripción).
struct IntervalsCard: View {
    @Environment(IntervalsService.self) private var intervals
    @Environment(\.openURL) private var openURL
    @State private var key = ""

    static let brand = Color(red: 0.13, green: 0.47, blue: 0.85)

    var body: some View {
        @Bindable var intervals = intervals
        Card(style: .outlined) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .top, spacing: Space.m) {
                    Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Self.brand, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                    SectionTitle(title: "intervals.icu", subtitle: intervals.isConnected
                                   ? "Conectado como \(intervals.athleteName ?? "tu cuenta")"
                                   : "Gratis. Analiza tu carga y tu forma, y junta el rodillo con tus salidas de Garmin.")
                    Spacer()
                    if intervals.isConnected {
                        Toggle("Subir al terminar", isOn: $intervals.autoUpload).toggleStyle(.switch).fixedSize()
                        Button("Desconectar") { intervals.disconnect() }.buttonStyle(.borderless)
                    }
                }
                if !intervals.isConnected {
                    Text("1. Crea una cuenta en intervals.icu (puedes entrar con Garmin) y conecta Garmin Connect para que traiga tus salidas.\n2. En **Settings → Developer Settings** copia tu **API Key** y pégala aquí.")
                        .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                    HStack(spacing: Space.m) {
                        SecureField("API Key", text: $key).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        Button(intervals.isBusy ? "Comprobando…" : "Conectar", systemImage: "link") {
                            Task {
                                await intervals.connect(apiKey: key)
                                if intervals.isConnected { key = "" }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || intervals.isBusy)
                        Button("Abrir ajustes", systemImage: "arrow.up.right.square") {
                            openURL(URL(string: "https://intervals.icu/settings")!)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if let status = intervals.status {
                    Text(status).font(Theme.font(.bodySmall)).foregroundStyle(Color.secondary)
                }
            }
        }
    }
}

/// Estado de un entreno en intervals.icu: enlace si ya está, o botón para subirlo.
struct IntervalsBadge: View {
    let activity: Activity
    @Environment(RideController.self) private var ride
    @Environment(IntervalsService.self) private var intervals

    var body: some View {
        if let id = activity.intervalsActivityID, let url = IntervalsService.activityURL(id) {
            Link(destination: url) {
                Label("Ver en intervals.icu", systemImage: "arrow.up.right.square")
                    .font(Theme.font(.labelLarge)).foregroundStyle(IntervalsCard.brand)
            }
        } else if intervals.isConnected {
            Button(intervals.isBusy ? "Subiendo…" : "Subir a intervals.icu", systemImage: "arrow.up.circle") {
                ride.uploadToIntervals(activity)
            }
            .buttonStyle(.bordered)
            .disabled(intervals.isBusy)
        }
    }
}

struct StravaCard: View {
    @Environment(StravaService.self) private var strava
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var connecting = false

    var body: some View {
        @Bindable var strava = strava
        Card(style: .outlined) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "figure.outdoor.cycle").foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Theme.strava, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                    SectionTitle(title: "Strava", subtitle: strava.isConnected
                                   ? "Conectado como \(strava.athleteName ?? "tu cuenta")"
                                   : "Opcional. Strava exige suscripción para usar su API: sin ella, no se puede conectar.")
                    Spacer()
                    if strava.isConnected {
                        Toggle("Subir al terminar", isOn: $strava.autoUpload).toggleStyle(.switch).fixedSize()
                        Button("Desconectar") { strava.disconnect() }.buttonStyle(.borderless)
                    }
                }
                if !strava.isConnected {
                    Text("""
                    1. En strava.com/settings/api crea una aplicación (nombre: Taylor Zwift; web: http://localhost) con **Authorization Callback Domain = localhost**.
                    2. Copia aquí su **Client ID** y su **Client Secret** y pulsa «Conectar con Strava».
                    """)
                    .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                    HStack(spacing: 12) {
                        TextField("Client ID", text: $strava.clientID).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                        SecureField("Client Secret", text: $strava.clientSecret).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        Button(connecting ? "Conectando…" : "Conectar con Strava", systemImage: "link") { connect() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!strava.canConnect || connecting)
                    }
                }
                if let status = strava.status {
                    Text(status).font(Theme.font(.bodySmall)).foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private func connect() {
        guard let url = strava.authorizeURL else { return }
        connecting = true
        Task {
            defer { connecting = false }
            do {
                let callback = try await webAuthenticationSession.authenticate(
                    using: url, callbackURLScheme: StravaService.callbackScheme, preferredBrowserSession: .ephemeral)
                await strava.handleCallback(callback)
            } catch {
                // Cancelado por el usuario: no hace falta avisar.
            }
        }
    }
}

/// Lleva un entreno a Garmin Connect por la vía oficial: abre su página «Importar datos» en el
/// navegador y te deja el .fit a mano (en el Mac, seleccionado en el Finder para arrastrarlo).
/// La API personal de Garmin solo permite descargar, no subir.
struct GarminImportButton: View {
    let activity: Activity
    @Environment(ActivityStore.self) private var store
    @Environment(\.openURL) private var openURL

    static let importPage = URL(string: "https://connect.garmin.com/modern/import-data")!

    var body: some View {
        #if os(macOS)
        Button("Subir a Garmin Connect", systemImage: "arrow.up.forward.app") {
            let fit = store.fitURL(activity)
            if !FileManager.default.fileExists(atPath: fit.path) {
                try? store.fitData(activity).write(to: fit)
            }
            NSWorkspace.shared.activateFileViewerSelecting([fit])
            openURL(Self.importPage)
        }
        .buttonStyle(.bordered)
        .help("Abre «Importar datos» de Garmin Connect y te enseña el .fit en el Finder: arrástralo a la página.")
        #else
        HStack {
            ShareLink(item: store.fitURL(activity)) { Label(".fit", systemImage: "square.and.arrow.up") }
                .buttonStyle(.bordered)
            Button("Garmin Connect", systemImage: "arrow.up.forward.app") { openURL(Self.importPage) }
                .buttonStyle(.bordered)
        }
        #endif
    }
}

/// Explica cómo llevar los entrenos a Garmin Connect.
struct GarminCard: View {
    var body: some View {
        Card(style: .outlined) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "applewatch.side.right").foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Color(red: 0, green: 0.48, blue: 0.76), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Garmin Connect").font(Theme.font(.titleLarge))
                    Text("Cada entreno se guarda como .fit. Con «Subir a Garmin Connect» se abre su página de importar y el fichero aparece seleccionado en el Finder: arrástralo a la página y listo. Si la página no reacciona, prueba con Chrome o Edge (Safari a veces falla al importar).")
                        .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                }
            }
        }
    }
}

/// Tarjeta de un entreno guardado.
struct ActivityCard: View {
    let activity: Activity

    var body: some View {
        let a = activity
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(a.start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                    .font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
                Spacer()
                if a.stravaActivityID != nil {
                    Text("STRAVA").font(Theme.font(.labelSmall)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.strava, in: Capsule())
                }
            }
            Text(a.name).font(Theme.font(.titleMedium)).foregroundStyle(Color.primary).lineLimit(1)
            PowerSparkline(activity: a).frame(height: 44)
            HStack(spacing: 14) {
                Label(formatDuration(Int(a.timerSeconds)), systemImage: "clock")
                Label("\((a.distanceMeters / 1000).formatted(.number.precision(.fractionLength(1)))) km", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                if let p = a.averagePower { Label("\(p) W", systemImage: "bolt.fill") }
                if let t = a.tss { Label("TSS \(t)", systemImage: "flame") }
                if let hr = a.averageHeartRate { Label("\(hr)", systemImage: "heart.fill") }
            }
            .font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.separator))
    }
}

struct SeriesPoint: Identifiable {
    /// Segundo desde el inicio.
    let index: Int
    let value: Double
    var id: Int { index }
}

/// Medias cada `seconds` segundos de una serie, para dibujar sin miles de puntos.
func downsample(_ values: [Double?], every seconds: Int) -> [SeriesPoint] {
    guard seconds > 0 else { return [] }
    var result: [SeriesPoint] = []
    var i = 0
    while i < values.count {
        let chunk = values[i..<min(i + seconds, values.count)].compactMap { $0 }
        if !chunk.isEmpty { result.append(SeriesPoint(index: i, value: chunk.reduce(0, +) / Double(chunk.count))) }
        i += seconds
    }
    return result
}

private struct PowerSparkline: View {
    let activity: Activity

    var body: some View {
        let step = max(activity.samples.count / 120, 5)
        let points = downsample(activity.samples.map { $0.power.map(Double.init) }, every: step)
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("t", p.index), y: .value("W", p.value))
                    .foregroundStyle(Theme.accent.opacity(0.18))
                LineMark(x: .value("t", p.index), y: .value("W", p.value))
                    .foregroundStyle(Theme.accent)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

/// Detalle de un entreno: gráficas, mejores marcas, zonas, exportar y Strava.
struct ActivityDetailView: View {
    let activityID: UUID
    @Environment(ActivityStore.self) private var store
    @Environment(RideController.self) private var ride
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let a = store.activities.first(where: { $0.id == activityID }) {
            content(a)
        } else {
            Text("Entreno borrado.").foregroundStyle(Color.secondary)
        }
    }

    private func content(_ a: Activity) -> some View {
        let history = a.powerHistory
        let fitURL = store.fitURL(a)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(style: .filled) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(a.name).font(Theme.font(.headlineSmall))
                                Text(a.start.formatted(date: .complete, time: .shortened))
                                    .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            GarminImportButton(activity: a)
                            IntervalsBadge(activity: a)
                            StravaBadge(activity: a)
                        }
                        HStack(spacing: 16) {
                            Stat(title: "Tiempo", value: formatDuration(Int(a.timerSeconds)), size: .headlineSmall)
                            Stat(title: "Distancia", value: (a.distanceMeters / 1000).formatted(.number.precision(.fractionLength(1))), unit: "km", size: .headlineSmall)
                            Stat(title: "Media", value: a.averagePower.map { "\($0)" } ?? "—", unit: "W", size: .headlineSmall)
                            Stat(title: "NP", value: a.normalizedPower.map { "\($0)" } ?? "—", unit: "W", size: .headlineSmall)
                            Stat(title: "TSS", value: a.tss.map { "\($0)" } ?? "—", size: .headlineSmall)
                            Stat(title: "IF", value: a.intensityFactor.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—", size: .headlineSmall)
                            Stat(title: "Pulso", value: a.averageHeartRate.map { "\($0)" } ?? "—", unit: "ppm", size: .headlineSmall)
                            Stat(title: "Desnivel", value: "\(Int(a.ascentMeters))", unit: "m", size: .headlineSmall)
                        }
                    }
                }
                Card(style: .filled) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("POTENCIA Y PULSO").font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
                        ActivityChart(activity: a).frame(height: 220)
                    }
                }
                Card(style: .filled) {
                    HStack(spacing: 16) {
                        ForEach([5, 60, 300, 1_200, 3_600], id: \.self) { seconds in
                            let label = seconds < 60 ? "\(seconds)''" : "\(seconds / 60)'"
                            Stat(title: "Mejor \(label)", value: history.bestAverage(seconds: seconds).map { "\(Int($0.rounded()))" } ?? "—",
                                   unit: "W", size: .headlineSmall)
                        }
                    }
                }
                Card(style: .outlined) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TIEMPO EN CADA ZONA (FTP \(a.ftp) W)").font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
                        ZoneTimeBars(activity: a)
                    }
                }
                HStack(spacing: 12) {
                    ShareLink(item: fitURL) { Label("Exportar .fit", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                    #if os(macOS)
                    Button("Mostrar en Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([fitURL])
                    }
                    .buttonStyle(.borderless)
                    #endif
                    Spacer()
                    Button("Borrar", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.borderless)
                }
                Text("El .fit se puede importar a mano en Garmin Connect, intervals.icu o TrainingPeaks.")
                    .font(Theme.font(.bodySmall)).foregroundStyle(Color.secondary)
            }
            .padding(24)
        }
        .background(Theme.background)
        .navigationTitle(a.name)
        .confirmationDialog("¿Borrar este entreno?", isPresented: $confirmDelete) {
            Button("Borrar", role: .destructive) {
                store.delete(a)
                dismiss()
            }
        } message: {
            Text("Se borra del historial de la app (no de Strava).")
        }
    }
}

private struct ActivityChart: View {
    let activity: Activity

    var body: some View {
        let step = max(activity.samples.count / 300, 5)
        let power = downsample(activity.samples.map { $0.power.map(Double.init) }, every: step)
        let heart = downsample(activity.samples.map { $0.heartRate.map(Double.init) }, every: step)
        Chart {
            ForEach(power) { p in
                AreaMark(x: .value("min", Double(p.index) / 60), y: .value("valor", p.value), series: .value("serie", "Potencia (W)"))
                    .foregroundStyle(Theme.accent.opacity(0.2))
                LineMark(x: .value("min", Double(p.index) / 60), y: .value("valor", p.value), series: .value("serie", "Potencia (W)"))
                    .foregroundStyle(Theme.accent)
            }
            ForEach(heart) { p in
                LineMark(x: .value("min", Double(p.index) / 60), y: .value("valor", p.value), series: .value("serie", "Pulso (ppm)"))
                    .foregroundStyle(Color.red)
            }
        }
        .chartXAxisLabel("min")
    }
}

private struct ZoneTimeBars: View {
    let activity: Activity

    var body: some View {
        let ftp = Double(max(activity.ftp, 1))
        var seconds: [PowerZone: Int] = [:]
        for s in activity.samples { if let p = s.power, p > 0 { seconds[PowerZone(fractionOfFTP: Double(p) / ftp), default: 0] += 1 } }
        let total = max(seconds.values.reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(PowerZone.allCases, id: \.self) { z in
                let s = seconds[z] ?? 0
                HStack(spacing: 10) {
                    Text("Z\(z.rawValue) \(z.name)").font(Theme.font(.bodyMedium)).frame(width: 150, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3).fill(z.color)
                            .frame(width: max(2, geo.size.width * Double(s) / Double(total)))
                    }
                    .frame(height: 12)
                    Text(formatDuration(s)).font(Theme.font(.bodySmall)).monospacedDigit().foregroundStyle(Color.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }
}
