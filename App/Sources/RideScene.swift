import CicloBluetooth
import CicloKit
import SpriteKit
import SwiftUI

/// Simulador 2D en pixel art: tú de perfil sobre el relieve de la ruta, con un escenario que
/// pega con ella (en ruta se elige solo; en entrenos y ERG lo eliges tú). Si no están
/// instalados los fondos (App/Escenarios), un pixel art hecho por código. Ocupa toda la ventana;
/// los datos van en un panel arriba. Esc o «Salir» para volver.
struct RideScene: View {
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub
    @State private var motion = SceneMotion()
    @State private var location = SceneLocation()
    @State private var sun: Sun.Position?
    @State private var world: PixelWorldScene?
    /// Escenario en ruta: «auto» (según la ruta) o uno fijo.
    @AppStorage("zonaRutas") private var routeZoneID = "auto"
    /// Escenario en entrenos y ERG.
    @AppStorage("zonaEntrenos") private var workoutZoneID = "prados"

    private var palette: ScenePalette { sun.map { ScenePalette(sun: $0) } ?? .day }
    /// El que pega con la ruta elegida.
    private var autoZone: PixelZone? { PixelZone.matching(Scenery.forRoute(ride.route)) }
    private var zone: PixelZone? {
        let available = PixelZone.available
        guard !available.isEmpty else { return nil }
        let id = ride.mode == .route ? (routeZoneID == "auto" ? autoZone?.id : routeZoneID) : workoutZoneID
        return available.first { $0.id == id } ?? autoZone ?? available.first
    }

    var body: some View {
        let route = Self.sceneryRoute(ride)
        let table = motion.table(for: route)
        let _ = { motion.palette = palette }()
        ZStack {
            if zone != nil {
                if let world {
                    SpriteView(scene: world, preferredFramesPerSecond: 30, options: [.ignoresSiblingOrder])
                        .id(world.zone.id) // escena nueva al cambiar de escenario
                        .ignoresSafeArea()
                }
            } else {
                // Sin fondos instalados: pixel art hecho por código.
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    Canvas { context, size in
                        let now = timeline.date.timeIntervalSinceReferenceDate
                        let d = motion.distance(at: now, recorded: ride.session.distanceMeters,
                                                speedKmh: ride.isRunning ? ride.speedKmh ?? 0 : 0)
                        let crank = motion.crank(at: now, cadence: ride.isRunning ? hub.bikeData.cadenceRpm ?? 0 : 0)
                        PixelRenderer(cam: SceneCamera(size: size, distance: d, table: table, isLoop: route.isLoop),
                                      palette: palette, time: now, crank: crank)
                            .draw(in: &context)
                    }
                }
                .ignoresSafeArea()
            }
            VStack {
                SceneHUD(table: table)
                Spacer()
                SceneBottomBar(table: table, zone: zone, autoZone: autoZone,
                               routeZoneID: $routeZoneID, workoutZoneID: $workoutZoneID)
            }
            .padding(Space.xl)
        }
        .background(Color.black)
        // Panel y botones en claro u oscuro según el cielo.
        .environment(\.colorScheme, palette.isNight ? .dark : .light)
        // El cielo sigue al sol de verdad: se recalcula cada minuto con tu ubicación.
        .task {
            location.request()
            while !Task.isCancelled {
                updateSun()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: location.coordinate?.latitude) { updateSun() }
        // El escenario cambia con la ruta (al leerse las rutas o al elegir otra) o con tu elección.
        .onAppear { if let zone { makeWorld(zone) } }
        .onChange(of: zone?.id) { if let zone, zone != world?.zone { makeWorld(zone) } }
        #if os(macOS)
        // Para desarrollar: `--args -capturaVentana 10` guarda a los 10 s la ventana entera (panel
        // incluido) como ventana.png en la carpeta temporal de la app.
        .task {
            let delay = UserDefaults.standard.double(forKey: "capturaVentana")
            guard delay > 0 else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("ventana.png"))
        }
        #endif
    }

    /// En ruta, la ruta; en entrenos y ERG, un llano (el paisaje, sin cuestas que no existen).
    static func sceneryRoute(_ ride: RideController) -> Route { ride.mode == .route ? ride.route : .flat }

    private func updateSun() {
        // Tu ubicación; si no la hay, la de la ruta (tus rutas son de por aquí); si tampoco, Barcelona.
        let routeStart = ride.route.track?.points.first
        let lat = location.coordinate?.latitude ?? routeStart?.latitude ?? 41.39
        let lon = location.coordinate?.longitude ?? routeStart?.longitude ?? 2.17
        sun = Sun.position(at: ScenePalette.forcedDate ?? Date(), latitude: lat, longitude: lon)
    }

    /// Monta la escena de SpriteKit del escenario; en cada fotograma pide distancia, pedalada,
    /// cielo y relieve.
    private func makeWorld(_ zone: PixelZone) {
        hub.appendLog("🏞 Escenario: \(zone.title)")
        let scene = PixelWorldScene(zone: zone)
        let motion = motion, ride = ride, hub = hub
        scene.feed = {
            let now = Date().timeIntervalSinceReferenceDate
            let route = Self.sceneryRoute(ride)
            let d = motion.distance(at: now, recorded: ride.session.distanceMeters,
                                    speedKmh: ride.isRunning ? ride.speedKmh ?? 0 : 0)
            let crank = motion.crank(at: now, cadence: ride.isRunning ? hub.bikeData.cadenceRpm ?? 0 : 0)
            return PixelWorldFeed(distance: d, crank: crank, palette: motion.palette, table: motion.table(for: route),
                                  isLoop: route.isLoop)
        }
        world = scene
    }
}

/// Distancia suave para dibujar: la del rodillo llega 2 veces por segundo; entre medias se
/// avanza a tu velocidad (sin pasarse más de 0,6 s) y nunca se va hacia atrás.
final class SceneMotion {
    private var cachedTable: RouteElevationTable?
    /// El cielo de ahora (para la escena de SpriteKit, que lo lee en cada fotograma).
    var palette = ScenePalette.day

    /// Tabla de alturas de la ruta (se hace una vez por ruta).
    func table(for route: Route) -> RouteElevationTable {
        if let t = cachedTable, t.routeID == route.id { return t }
        let t = RouteElevationTable(route)
        cachedTable = t
        return t
    }

    private var smoothCadence = 0.0
    private var crankAngle = 0.0
    private var lastCrankTime: Double?

    /// Ángulo de las bielas: se va sumando con la cadencia del rodillo, suavizada (≈ 0,6 s), así
    /// que va a tu ritmo y un cambio de cadencia no hace saltar las piernas.
    func crank(at now: Double, cadence: Double) -> Double {
        let dt = lastCrankTime.map { min(max(now - $0, 0), 0.1) } ?? 0
        lastCrankTime = now
        smoothCadence += (cadence - smoothCadence) * (1 - exp(-dt / 0.6))
        crankAngle = (crankAngle + dt * smoothCadence / 60 * 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        return crankAngle
    }

    private var recorded = -1.0
    private var recordedAt = 0.0
    private var shown = 0.0

    func distance(at now: Double, recorded d: Double, speedKmh: Double) -> Double {
        if d != recorded {
            if d < recorded - 50 || recorded < 0 { shown = d } // ruta nueva o puesta a cero
            recorded = d
            recordedAt = now
        }
        let ahead = d + speedKmh / 3.6 * min(now - recordedAt, 0.6)
        shown = max(shown, ahead)
        if shown > ahead + 20 { shown = ahead } // por si acaso: no alejarse de lo real
        return shown
    }
}

// MARK: - Cielo según el sol

/// Un color en RGB que se puede mezclar (para pasar suave de la noche al día).
struct RGB: Equatable {
    var r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
    var color: Color { Color(red: r, green: g, blue: b) }
}

/// Colores de la escena según la altura del sol: noche, hora azul, amanecer o atardecer, hora
/// dorada y día, mezclados de forma continua.
struct ScenePalette: Equatable {
    var skyTop: RGB
    var skyBottom: RGB
    /// Sol (o luna, de noche).
    var light: RGB
    /// Sierras, de la más lejana a la más cercana.
    var ridges: [RGB]
    /// Terreno, árboles y ciclista (la silueta más oscura).
    var ground: RGB
    /// Dónde va el sol (0…1 del ancho y del alto); por debajo del horizonte queda tapado.
    var lightX: Double = 0.75
    var lightY: Double = 0.2
    var isMoon = false
    /// Opacidad de las estrellas.
    var stars: Double = 0
    /// Panel en modo oscuro.
    var isNight = false

    /// Para probar otra hora: `--args -horaSimulador 20` (hora local de hoy).
    static var forcedDate: Date? {
        // Los argumentos de arranque llegan como texto: `integer(forKey:)` los convierte.
        guard UserDefaults.standard.object(forKey: "horaSimulador") != nil else { return nil }
        let h = UserDefaults.standard.integer(forKey: "horaSimulador")
        return Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())
    }

    init(skyTop: RGB, skyBottom: RGB, light: RGB, ridges: [RGB], ground: RGB) {
        self.skyTop = skyTop; self.skyBottom = skyBottom; self.light = light; self.ridges = ridges; self.ground = ground
    }

    func mix(_ o: ScenePalette, _ t: Double) -> ScenePalette {
        ScenePalette(skyTop: skyTop.mix(o.skyTop, t), skyBottom: skyBottom.mix(o.skyBottom, t), light: light.mix(o.light, t),
                     ridges: zip(ridges, o.ridges).map { $0.mix($1, t) }, ground: ground.mix(o.ground, t))
    }

    /// Los fotogramas del cielo de un estilo.
    struct Keys {
        var night, blueHour, dawn, dusk, golden, day: ScenePalette
        var moon: RGB

        static let silhouette = Keys(night: .night, blueHour: .blueHour, dawn: .dawn, dusk: .dusk, golden: .golden,
                                     day: .day, moon: RGB(0.92, 0.94, 1.0))
    }

    init(sun: Sun.Position, keys k: Keys = .silhouette) {
        let e = sun.elevation
        // Fotogramas clave por altura del sol (grados); amanecer y atardecer tienen su tono.
        let twilight = sun.isMorning ? k.dawn : k.dusk
        let keys: [(Double, ScenePalette)] = [(-12, k.night), (-5, k.blueHour), (0, twilight), (7, k.golden), (20, k.day)]
        var p = keys[0].1
        if e >= keys[keys.count - 1].0 {
            p = keys[keys.count - 1].1
        } else if e > keys[0].0 {
            let i = keys.lastIndex { $0.0 <= e } ?? 0
            let (e0, p0) = keys[i], (e1, p1) = keys[i + 1]
            p = p0.mix(p1, (e - e0) / (e1 - e0))
        }
        self = p
        stars = min(max((-e - 3) / 8, 0), 1)
        isNight = e < -4
        if e > -2 {
            // El sol cruza de izquierda (mañana) a derecha (tarde) y baja hasta el horizonte.
            lightX = min(max(0.5 + sun.hourAngle * 1.3, 0.08), 0.92)
            lightY = 0.58 - min(max(e, -4), 60) / 60 * 0.30
        } else {
            isMoon = true
            lightX = 0.85
            lightY = 0.27
            light = k.moon
        }
    }

    static let day = ScenePalette(
        skyTop: RGB(0.36, 0.60, 0.86), skyBottom: RGB(0.80, 0.88, 0.93), light: RGB(1.0, 0.97, 0.88),
        ridges: [RGB(0.62, 0.72, 0.80), RGB(0.45, 0.57, 0.66), RGB(0.30, 0.42, 0.48), RGB(0.19, 0.29, 0.32)],
        ground: RGB(0.10, 0.17, 0.18))
    static let golden = ScenePalette(
        skyTop: RGB(0.33, 0.52, 0.80), skyBottom: RGB(0.99, 0.84, 0.64), light: RGB(1.0, 0.92, 0.70),
        ridges: [RGB(0.78, 0.72, 0.68), RGB(0.58, 0.55, 0.57), RGB(0.38, 0.38, 0.44), RGB(0.22, 0.23, 0.29)],
        ground: RGB(0.12, 0.12, 0.16))
    static let dawn = ScenePalette(
        skyTop: RGB(0.40, 0.48, 0.72), skyBottom: RGB(0.99, 0.78, 0.62), light: RGB(1.0, 0.88, 0.68),
        ridges: [RGB(0.80, 0.66, 0.68), RGB(0.60, 0.50, 0.58), RGB(0.40, 0.34, 0.45), RGB(0.25, 0.21, 0.32)],
        ground: RGB(0.13, 0.11, 0.18))
    static let dusk = ScenePalette(
        skyTop: RGB(0.24, 0.22, 0.45), skyBottom: RGB(0.98, 0.58, 0.38), light: RGB(1.0, 0.76, 0.50),
        ridges: [RGB(0.80, 0.48, 0.45), RGB(0.58, 0.34, 0.40), RGB(0.38, 0.22, 0.32), RGB(0.22, 0.13, 0.22)],
        ground: RGB(0.11, 0.07, 0.12))
    static let blueHour = ScenePalette(
        skyTop: RGB(0.10, 0.13, 0.30), skyBottom: RGB(0.40, 0.40, 0.60), light: RGB(0.92, 0.94, 1.0),
        ridges: [RGB(0.32, 0.33, 0.52), RGB(0.23, 0.24, 0.42), RGB(0.15, 0.17, 0.31), RGB(0.09, 0.10, 0.21)],
        ground: RGB(0.05, 0.05, 0.11))
    static let night = ScenePalette(
        skyTop: RGB(0.03, 0.05, 0.12), skyBottom: RGB(0.12, 0.16, 0.28), light: RGB(0.92, 0.94, 1.0),
        ridges: [RGB(0.17, 0.22, 0.33), RGB(0.12, 0.16, 0.26), RGB(0.08, 0.11, 0.19), RGB(0.05, 0.07, 0.13)],
        ground: RGB(0.02, 0.03, 0.06))
}

// MARK: - Panel de datos

/// Seis tarjetas iguales: etiqueta, número grande con su unidad y una línea de abajo (zona,
/// media, lo que viene o una barra). En ruta: potencia, pulso, cadencia, velocidad, pendiente
/// y marcha; en un entreno, objetivo y tramo en vez de pendiente y marcha; en ERG, objetivo y tiempo.
private struct SceneHUD: View {
    let table: RouteElevationTable
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub

    var body: some View {
        let cards = self.cards
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.offset) { i, card in
                HUDCard(card: card)
                if i < cards.count - 1 {
                    Rectangle().fill(.separator).frame(width: 1).padding(.horizontal, Space.m)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.extraLarge))
        .frame(maxWidth: 1100)
    }

    private var cards: [HUDCard.Data] {
        var list = [power, heartRate, cadence, speed]
        switch ride.mode {
        case .route: list += [grade, gear]
        case .workout: list.insert(target, at: 1); list.append(segment)
        case .erg: list.insert(ergTarget, at: 1); list.append(time)
        }
        return list
    }

    private func one(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) }
    private func clock(_ s: Double) -> String { Duration.seconds(max(s, 0)).formatted(.time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond)) }

    private var power: HUDCard.Data {
        let watts = ride.power3s
        let zone = watts.map { PowerZone(fractionOfFTP: Double($0) / Double(max(ride.ftp, 1))) }
        return .init(title: "POTENCIA", value: watts.map { "\($0)" } ?? "—", unit: "W",
                     footer: .text(zone.map { "Z\($0.rawValue) · \($0.name)" } ?? "—", dot: zone?.color))
    }

    private var heartRate: HUDCard.Data {
        let bpm = hub.heartRateBpm
        let zone = bpm.map { HeartRateZone(bpm: $0, max: ride.maxHeartRate) }
        return .init(title: "PULSO", value: bpm.map { "\($0)" } ?? "—", unit: "ppm",
                     footer: .text(zone.map { "Z\($0.rawValue) · \($0.name)" } ?? "sin pulsómetro", dot: zone?.color))
    }

    private var cadence: HUDCard.Data {
        let rpm = hub.bikeData.cadenceRpm.map { "\(Int($0.rounded()))" } ?? "—"
        if ride.mode == .workout, let target = ride.workoutProgress?.segment.cadence {
            return .init(title: "CADENCIA", value: rpm, unit: "rpm", footer: .text("objetivo \(target) rpm", dot: Theme.accent))
        }
        return .init(title: "CADENCIA", value: rpm, unit: "rpm",
                     footer: .text(ride.averageCadence.map { "media \($0) rpm" } ?? "—", dot: nil))
    }

    private var speed: HUDCard.Data {
        let s = ride.session
        let average = s.movingSeconds > 30 ? s.distanceMeters / s.movingSeconds * 3.6 : nil
        return .init(title: "VELOCIDAD", value: ride.speedKmh.map(one) ?? "—", unit: "km/h",
                     footer: .text(average.map { "media \(one($0)) km/h" } ?? "—", dot: nil))
    }

    private var grade: HUDCard.Data {
        let g = ride.currentGrade
        let d = ride.session.distanceMeters
        let ahead = (table.elevation(atDistance: d + 500) - table.elevation(atDistance: d)) / 5
        return .init(title: "PENDIENTE", value: one(g), unit: "%", valueColor: GradeBand(gradePercent: g).color,
                     footer: .text("próx. 500 m: \(one(ahead)) %", dot: GradeBand(gradePercent: ahead).color))
    }

    private var gear: HUDCard.Data {
        .init(title: "MARCHA", value: "\(ride.gears.number)", unit: "de \(ride.gears.count)",
              footer: .ladder(ride.gears.number, ride.gears.count, ride.gears.gear.label))
    }

    private var target: HUDCard.Data {
        guard let p = ride.workoutProgress else {
            return .init(title: "OBJETIVO", value: "—", unit: "W", footer: .text("elige un entreno", dot: nil))
        }
        let done = 1 - p.secondsLeftInSegment / Double(max(p.segment.durationSeconds, 1))
        return .init(title: "OBJETIVO", value: ride.targetWatts.map { "\($0)" } ?? "libre", unit: ride.targetWatts == nil ? "" : "W",
                     valueColor: Theme.accent,
                     footer: .bar(done, Theme.accent, "quedan \(clock(p.secondsLeftInSegment))"))
    }

    private var segment: HUDCard.Data {
        guard let w = ride.workout, let p = ride.workoutProgress else {
            return .init(title: "TRAMO", value: "—", unit: "", footer: .text("—", dot: nil))
        }
        let next = p.next.map { "luego \($0.summary)" } ?? "último tramo"
        return .init(title: "TRAMO", value: "\(p.segment.id + 1)", unit: "de \(w.segments.count)",
                     footer: .text(next, dot: p.next?.startPower.map { PowerZone(fractionOfFTP: $0).color }))
    }

    private var ergTarget: HUDCard.Data {
        .init(title: "OBJETIVO", value: "\(ride.ergWatts)", unit: "W", valueColor: Theme.accent,
              footer: .text("+ / − con los mandos (10 W)", dot: nil))
    }

    private var time: HUDCard.Data {
        .init(title: "TIEMPO", value: clock(ride.session.movingSeconds), unit: "",
              footer: .text("\(one(ride.session.distanceMeters / 1000)) km", dot: nil))
    }
}

/// Una tarjeta del panel. Todas miden lo mismo y tienen las mismas tres filas.
private struct HUDCard: View {
    struct Data {
        var title: String
        var value: String
        var unit: String
        var valueColor: Color? = nil
        var footer: Footer
    }

    enum Footer {
        case text(String, dot: Color?)
        case bar(Double, Color, String)
        case ladder(Int, Int, String)
    }

    let card: Data

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title).font(Theme.font(.labelSmall)).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(card.value).font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(card.valueColor ?? Color.primary)
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(card.unit).font(Theme.font(.bodyMedium)).foregroundStyle(.secondary).lineLimit(1)
            }
            footer.frame(height: 16, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        switch card.footer {
        case .text(let text, let dot):
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(text).font(Theme.font(.labelSmall)).foregroundStyle(.secondary).lineLimit(1)
            }
        case .bar(let fraction, let tint, let label):
            HStack(spacing: 6) {
                CapsuleBar(fraction: fraction, tint: tint, height: 5).frame(maxWidth: 70)
                Text(label).font(Theme.font(.labelSmall)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
        case .ladder(let n, let count, let label):
            HStack(alignment: .bottom, spacing: 6) {
                HStack(alignment: .bottom, spacing: count > 12 ? 1.5 : 2) {
                    ForEach(1...max(count, 1), id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i == n ? Theme.accent : Color.primary.opacity(i < n ? 0.45 : 0.15))
                            .frame(width: count > 12 ? 3 : 4, height: 4 + CGFloat(i) / CGFloat(max(count, 1)) * 11)
                    }
                }
                Text(label).font(Theme.font(.labelSmall)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Barra de abajo

/// Abajo: empezar/pausa; la ruta (km, subida y perfil con el color de la pendiente) o el entreno
/// (perfil con dónde vas); y el escenario, pantalla completa y salir.
private struct SceneBottomBar: View {
    let table: RouteElevationTable
    let zone: PixelZone?
    let autoZone: PixelZone?
    @Binding var routeZoneID: String
    @Binding var workoutZoneID: String
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            if ride.isRunning {
                RoundButton(systemImage: "pause.fill", prominent: true, help: "Pausa (A en el mando)") { ride.pause() }
            } else {
                RoundButton(systemImage: "play.fill", prominent: true, help: "Empezar (A en el mando)") { ride.start() }
                    .disabled(ride.summary != nil || hub.trainerConnection != .connected)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.m) {
                    Text(title).font(Theme.font(.bodyMedium).weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(Theme.font(.bodyMedium)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: Space.m)
                    if let climb = climbText {
                        Label(climb, systemImage: "mountain.2.fill")
                            .font(Theme.font(.bodyMedium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                profile.frame(height: 46)
            }
            zoneMenu
            #if os(macOS)
            RoundButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Pantalla completa") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            #endif
            RoundButton(systemImage: "xmark", help: "Salir (Esc)") { ride.showScene = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Space.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.extraLarge))
        .frame(maxWidth: 1100)
    }

    @ViewBuilder
    private var profile: some View {
        switch ride.mode {
        case .route:
            GradeProfile(table: table, position: ride.route.positionInLap(ride.session.distanceMeters))
        case .workout:
            if let w = ride.workout { WorkoutStrip(workout: w, elapsed: ride.workoutSeconds) }
        case .erg:
            HStack {
                Text("Modo ERG: el rodillo mantiene los vatios aunque cambies la cadencia.")
                    .font(Theme.font(.bodySmall)).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var title: String {
        switch ride.mode {
        case .route: ride.route.name
        case .workout: ride.workout?.name ?? "Entreno"
        case .erg: "ERG \(ride.ergWatts) W"
        }
    }

    private var subtitle: String {
        let km = (ride.session.distanceMeters / 1000).formatted(.number.precision(.fractionLength(1)))
        switch ride.mode {
        case .route:
            let total = (ride.route.lengthMeters / 1000).formatted(.number.precision(.fractionLength(1)))
            return ride.route.isLoop ? "km \(km) · vuelta de \(total) km" : "km \(km) de \(total)"
        case .workout:
            let left = ride.workoutProgress?.secondsLeftInWorkout ?? 0
            return "quedan \(Duration.seconds(left).formatted(.time(pattern: .minuteSecond))) · \(km) km"
        case .erg:
            return "\(km) km"
        }
    }

    private var climbText: String? {
        guard ride.mode == .route, let s = ride.climbStatus else { return nil }
        func km(_ m: Double) -> String { (m / 1000).formatted(.number.precision(.fractionLength(1))) }
        let avg = s.climb.averageGradePercent.formatted(.number.precision(.fractionLength(1)))
        return s.isOnClimb
            ? "Subida: quedan \(km(s.remainingMeters)) km y \(Int(s.remainingAscentMeters)) m"
            : "Subida en \(km(s.distanceToStart)) km: \(km(s.climb.lengthMeters)) km al \(avg) %"
    }

    /// Escenario: en ruta, automático (según la ruta) o uno fijo; en entrenos y ERG, el que elijas.
    @ViewBuilder
    private var zoneMenu: some View {
        if !PixelZone.available.isEmpty {
            Menu {
                if ride.mode == .route {
                    Picker("Escenario", selection: $routeZoneID) {
                        Text("Automático: \(autoZone?.title ?? "—")").tag("auto")
                        ForEach(PixelZone.available) { z in Text(z.title).tag(z.id) }
                    }
                    .pickerStyle(.inline)
                } else {
                    Picker("Escenario", selection: $workoutZoneID) {
                        ForEach(PixelZone.available) { z in Text(z.title).tag(z.id) }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label(zone?.title ?? "Escenario", systemImage: "mountain.2.fill")
                    .font(Theme.font(.bodyMedium).weight(.semibold))
                    .padding(.horizontal, Space.m).frame(height: 38)
                    .background(.quaternary, in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Escenario del simulador")
        }
    }
}

private struct RoundButton: View {
    let systemImage: String
    var prominent = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 20 : 15, weight: .semibold))
                .frame(width: prominent ? 52 : 38, height: prominent ? 52 : 38)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// El perfil de toda la ruta (o de la vuelta) con el color de la pendiente en cada trozo;
/// lo ya hecho, apagado, y una línea donde vas.
private struct GradeProfile: View {
    let table: RouteElevationTable
    let position: Double

    var body: some View {
        Canvas { c, size in
            let n = 200
            let length = max(table.lengthMeters, 1)
            let heights = (0...n).map { table.elevation(atDistance: Double($0) / Double(n) * length) }
            let lo = heights.min() ?? 0, hi = max(heights.max() ?? 1, lo + 30)
            func y(_ i: Int) -> CGFloat { size.height - CGFloat((heights[i] - lo) / (hi - lo)) * (size.height - 6) - 1 }
            let w = size.width / CGFloat(n)
            for i in 0..<n {
                var slice = Path()
                slice.move(to: CGPoint(x: CGFloat(i) * w, y: size.height))
                slice.addLine(to: CGPoint(x: CGFloat(i) * w, y: y(i)))
                slice.addLine(to: CGPoint(x: CGFloat(i + 1) * w + 0.5, y: y(i + 1)))
                slice.addLine(to: CGPoint(x: CGFloat(i + 1) * w + 0.5, y: size.height))
                slice.closeSubpath()
                // Pendiente media de unos 400 m alrededor (el GPS mete ruido en tramos cortos).
                let half = max(Int((200 / (length / Double(n))).rounded()), 1)
                let a = max(i - half + 1, 0), b = min(i + half, n)
                let grade = (heights[b] - heights[a]) / (Double(b - a) * length / Double(n)) * 100
                c.fill(slice, with: .color(GradeBand(gradePercent: grade).color))
            }
            // Lo hecho, apagado.
            let done = CGFloat(min(max(position / length, 0), 1)) * size.width
            c.fill(Path(CGRect(x: 0, y: 0, width: done, height: size.height)), with: .color(Color.gray.opacity(0.55)))
            // Dónde vas.
            var marker = Path()
            marker.addRect(CGRect(x: done - 1, y: 0, width: 2, height: size.height))
            c.fill(marker, with: .color(.primary))
            let i = min(max(Int((position / length * Double(n)).rounded()), 0), n)
            c.fill(Path(ellipseIn: CGRect(x: done - 5, y: y(i) - 5, width: 10, height: 10)), with: .color(Theme.accent))
            c.stroke(Path(ellipseIn: CGRect(x: done - 5, y: y(i) - 5, width: 10, height: 10)), with: .color(.white), lineWidth: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
        .accessibilityLabel("Perfil de la ruta con la pendiente")
    }
}

/// El entreno entero en pequeño: un bloque por tramo, con su altura y el color de su zona; lo
/// hecho, apagado, y una línea donde vas.
private struct WorkoutStrip: View {
    let workout: Workout
    let elapsed: Double

    var body: some View {
        Canvas { c, size in
            let total = Double(max(workout.durationSeconds, 1))
            let peak = max(workout.segments.compactMap { max($0.startPower ?? 0, $0.endPower ?? 0) }.max() ?? 1, 1.2)
            func x(_ t: Double) -> CGFloat { CGFloat(t / total) * size.width }
            func y(_ f: Double) -> CGFloat { size.height - CGFloat(f / peak) * (size.height - 3) }
            for seg in workout.segments {
                var block = Path()
                let a = seg.startPower ?? 0.5, b = seg.endPower ?? 0.5
                block.move(to: CGPoint(x: x(Double(seg.startSeconds)), y: size.height))
                block.addLine(to: CGPoint(x: x(Double(seg.startSeconds)), y: y(a)))
                block.addLine(to: CGPoint(x: x(Double(seg.endSeconds)), y: y(b)))
                block.addLine(to: CGPoint(x: x(Double(seg.endSeconds)), y: size.height))
                block.closeSubpath()
                let color = seg.isFree ? Color.gray.opacity(0.5) : PowerZone(fractionOfFTP: max(a, b)).color
                c.fill(block, with: .color(color))
            }
            let done = x(min(elapsed, total))
            c.fill(Path(CGRect(x: 0, y: 0, width: done, height: size.height)), with: .color(Color.gray.opacity(0.55)))
            c.fill(Path(CGRect(x: done - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
        .accessibilityLabel("Perfil del entreno")
    }
}
