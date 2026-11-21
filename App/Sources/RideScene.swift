import CicloBluetooth
import CicloKit
import SwiftUI

/// Simulador 2D: tú de perfil sobre el relieve real de la ruta, con el paisaje desplazándose a tu
/// velocidad. Ocupa toda la ventana (con «Pantalla completa», toda la pantalla); los datos clave
/// van en un panel arriba. Esc o «Salir» para volver.
struct RideScene: View {
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub
    @State private var motion = SceneMotion()
    @State private var location = SceneLocation()
    @State private var palette = ScenePalette.day

    var body: some View {
        let table = motion.table(for: ride.route)
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let d = motion.distance(at: now, recorded: ride.session.distanceMeters,
                                            speedKmh: ride.isRunning ? ride.speedKmh ?? 0 : 0)
                    SceneRenderer(route: ride.route, table: table, distance: d, time: now,
                                  cadence: ride.isRunning ? hub.bikeData.cadenceRpm ?? 0 : 0,
                                  palette: palette)
                        .draw(in: &context, size: size)
                }
            }
            .ignoresSafeArea()
            VStack {
                SceneHUD(table: table)
                Spacer()
                SceneBottomBar(table: table)
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
                updatePalette()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: location.coordinate?.latitude) { updatePalette() }
    }

    private func updatePalette() {
        // Tu ubicación; si no la hay, la de la ruta (tus rutas son de por aquí); si tampoco, Barcelona.
        let routeStart = ride.route.track?.points.first
        let lat = location.coordinate?.latitude ?? routeStart?.latitude ?? 41.39
        let lon = location.coordinate?.longitude ?? routeStart?.longitude ?? 2.17
        let date = ScenePalette.forcedDate ?? Date()
        palette = ScenePalette(sun: Sun.position(at: date, latitude: lat, longitude: lon))
    }
}

/// Distancia suave para dibujar: la del rodillo llega 2 veces por segundo; entre medias se
/// avanza a tu velocidad (sin pasarse más de 0,6 s) y nunca se va hacia atrás.
final class SceneMotion {
    private var cachedTable: RouteElevationTable?

    /// Tabla de alturas de la ruta (se hace una vez por ruta).
    func table(for route: Route) -> RouteElevationTable {
        if let t = cachedTable, t.routeID == route.id { return t }
        let t = RouteElevationTable(route)
        cachedTable = t
        return t
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
        guard let h = UserDefaults.standard.object(forKey: "horaSimulador") as? Int else { return nil }
        return Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())
    }

    init(skyTop: RGB, skyBottom: RGB, light: RGB, ridges: [RGB], ground: RGB) {
        self.skyTop = skyTop; self.skyBottom = skyBottom; self.light = light; self.ridges = ridges; self.ground = ground
    }

    func mix(_ o: ScenePalette, _ t: Double) -> ScenePalette {
        ScenePalette(skyTop: skyTop.mix(o.skyTop, t), skyBottom: skyBottom.mix(o.skyBottom, t), light: light.mix(o.light, t),
                     ridges: zip(ridges, o.ridges).map { $0.mix($1, t) }, ground: ground.mix(o.ground, t))
    }

    init(sun: Sun.Position) {
        let e = sun.elevation
        // Fotogramas clave por altura del sol (grados); amanecer y atardecer tienen su tono.
        let twilight = sun.isMorning ? Self.dawn : Self.dusk
        let keys: [(Double, ScenePalette)] = [(-12, .night), (-5, .blueHour), (0, twilight), (7, .golden), (20, .day)]
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
            lightY = 0.38
            light = RGB(0.92, 0.94, 1.0)
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

// MARK: - Dibujo

private struct SceneRenderer {
    let route: Route
    let table: RouteElevationTable
    let distance: Double
    let time: Double
    let cadence: Double
    let palette: ScenePalette

    /// Metros de ruta que caben a lo ancho y dónde vas tú (fracción del ancho).
    static let metersWide = 650.0
    static let riderX = 0.3
    /// Exageración vertical: la pendiente se ve, pero sin que una subida se salga de la pantalla.
    static let verticalExaggeration = 2.5

    private var length: Double { table.lengthMeters }

    func draw(in c: inout GraphicsContext, size: CGSize) {
        let pxPerM = size.width / Self.metersWide
        let riderX = size.width * Self.riderX
        let yPerM = pxPerM * Self.verticalExaggeration
        // La cámara mira un poco por delante, para ver venir las subidas.
        let camElevation = (elevation(distance) * 3 + elevation(distance + 150)) / 4
        let baseY = size.height * 0.68

        func world(_ x: CGFloat) -> Double { distance + Double(x - riderX) / pxPerM }
        func groundY(_ d: Double) -> CGFloat { baseY - CGFloat(elevation(d) - camElevation) * yPerM }

        drawSky(&c, size)
        // Sierras: cuanto más lejos, más claras, más bajas en contraste y más despacio.
        let layers: [(parallax: Double, top: CGFloat, height: CGFloat, seed: Double)] = [
            (0.04, 0.36, 0.16, 1.3), (0.10, 0.44, 0.15, 2.7), (0.20, 0.52, 0.13, 4.1), (0.38, 0.60, 0.11, 5.9),
        ]
        for (i, l) in layers.enumerated() {
            drawRidge(&c, size, parallax: l.parallax, top: l.top, height: l.height, seed: l.seed,
                      color: palette.ridges[i].color)
        }

        // Terreno (la silueta más oscura).
        let step: CGFloat = 4
        var ground = Path()
        ground.move(to: CGPoint(x: 0, y: size.height))
        var x: CGFloat = 0
        while x <= size.width + step {
            ground.addLine(to: CGPoint(x: x, y: groundY(world(x))))
            x += step
        }
        ground.addLine(to: CGPoint(x: size.width + step, y: size.height))
        ground.closeSubpath()

        drawTrees(&c, size, pxPerM: pxPerM, riderX: riderX, groundY: groundY)
        c.fill(ground, with: .color(palette.ground.color))

        // Borde del terreno: una línea fina y discreta (los colores de la pendiente van en el perfil).
        var edge = Path()
        x = 0
        edge.move(to: CGPoint(x: 0, y: groundY(world(0))))
        while x <= size.width + step {
            edge.addLine(to: CGPoint(x: x, y: groundY(world(x))))
            x += step
        }
        c.stroke(edge, with: .color(palette.ridges[3].mix(palette.skyBottom, 0.35).color), lineWidth: 1.5)

        drawMarkers(&c, size, pxPerM: pxPerM, riderX: riderX, groundY: groundY)

        // Tú.
        let slope = atan2(Double(groundY(distance + 3) - groundY(distance - 3)), 6 * Double(pxPerM))
        drawRider(&c, at: CGPoint(x: riderX, y: groundY(distance) - 1.5), angle: slope,
                  scale: max(size.height / 640, 0.75))
    }

    private func elevation(_ d: Double) -> Double {
        table.elevation(atDistance: route.isLoop ? d : min(max(d, 0), length))
    }

    private func drawSky(_ c: inout GraphicsContext, _ size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        c.fill(Path(rect), with: .linearGradient(Gradient(colors: [palette.skyTop.color, palette.skyBottom.color]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.62)))
        if palette.stars > 0 {
            // Estrellas fijas (siempre en el mismo sitio), con un parpadeo leve.
            for i in 0..<90 {
                let h1 = fract(sin(Double(i) * 12.9898) * 43_758.5453)
                let h2 = fract(sin(Double(i) * 78.233) * 12_345.678)
                let r = CGFloat(0.6 + h1 * 1.2)
                let twinkle = 0.55 + 0.45 * sin(time * (0.8 + h2) + Double(i))
                c.fill(Path(ellipseIn: CGRect(x: CGFloat(h1) * size.width, y: CGFloat(h2) * size.height * 0.45, width: r, height: r)),
                       with: .color(.white.opacity((0.35 + 0.5 * twinkle * h1) * palette.stars)))
            }
        }
        // Sol o luna, con un halo suave.
        let r = size.height * 0.045
        let center = CGPoint(x: size.width * palette.lightX, y: size.height * palette.lightY)
        c.fill(Path(ellipseIn: CGRect(x: center.x - r * 7, y: center.y - r * 7, width: r * 14, height: r * 14)),
               with: .radialGradient(Gradient(colors: [palette.light.color.opacity(0.35), palette.light.color.opacity(0)]),
                                     center: center, startRadius: r, endRadius: r * 7))
        c.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
               with: .color(palette.light.color))
        if palette.isMoon {
            // Luna creciente: un círculo del color del cielo tapa parte del disco.
            c.fill(Path(ellipseIn: CGRect(x: center.x - r * 0.55, y: center.y - r * 1.1, width: r * 2, height: r * 2)),
                   with: .color(palette.skyTop.mix(palette.skyBottom, palette.lightY / 0.62).color))
        }
    }

    /// Una sierra: ruido suave (suma de senos, siempre el mismo en el mismo sitio) con paralaje,
    /// rellena con su color y una bruma clara en la base que la separa de la siguiente.
    private func drawRidge(_ c: inout GraphicsContext, _ size: CGSize, parallax: Double, top: CGFloat,
                           height: CGFloat, seed: Double, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height))
        var x: CGFloat = 0
        let shift = distance * Double(size.width / Self.metersWide) * parallax
        while x <= size.width + 6 {
            let u = (Double(x) + shift) / Double(size.width)
            let n = 0.55 * sin(u * 2.3 + seed) + 0.28 * sin(u * 5.9 + seed * 1.7)
                + 0.12 * sin(u * 13.1 + seed * 2.9) + 0.05 * sin(u * 31.7 + seed * 4.3)
            p.addLine(to: CGPoint(x: x, y: size.height * top + CGFloat(-n) * size.height * height))
            x += 6
        }
        p.addLine(to: CGPoint(x: size.width + 6, y: size.height))
        p.closeSubpath()
        c.fill(p, with: .color(color))
        let hazeTop = size.height * (top + height * 0.4)
        c.fill(p, with: .linearGradient(
            Gradient(colors: [palette.skyBottom.color.opacity(0), palette.skyBottom.color.opacity(0.35 - 0.23 * palette.stars)]),
            startPoint: CGPoint(x: 0, y: hazeTop), endPoint: CGPoint(x: 0, y: hazeTop + size.height * 0.18)))
    }

    /// Árboles en silueta, de alturas y formas distintas, siempre en los mismos metros de la ruta.
    private func drawTrees(_ c: inout GraphicsContext, _ size: CGSize, pxPerM: CGFloat, riderX: CGFloat,
                           groundY: (Double) -> CGFloat) {
        let every = 11.0
        var d = ((distance - Double(riderX / pxPerM)) / every).rounded(.down) * every
        let end = distance + Double((size.width - riderX) / pxPerM) + every
        var trees = Path()
        while d < end {
            let r = fract(sin(d * 12.9898) * 43_758.5453)
            // Bosquecillos: hay árboles donde una onda lenta lo permite.
            let grove = sin(d / 90 + 1.3) + 0.6 * sin(d / 37)
            if grove > 0.2, r > 0.25 {
                let td = d + (r - 0.5) * 6
                let x = riderX + CGFloat(td - distance) * pxPerM
                let y = groundY(td) + 3
                let h = CGFloat(10 + r * 14) * pxPerM
                if r > 0.6 {
                    // Abeto: tres pisos.
                    for k in 0..<3 {
                        let w = h * (0.42 - CGFloat(k) * 0.1)
                        let ty = y - h * (0.25 + CGFloat(k) * 0.25)
                        trees.move(to: CGPoint(x: x, y: ty - h * 0.38))
                        trees.addLine(to: CGPoint(x: x - w, y: ty))
                        trees.addLine(to: CGPoint(x: x + w, y: ty))
                        trees.closeSubpath()
                    }
                } else {
                    // Árbol redondo.
                    let w = h * 0.5
                    trees.addEllipse(in: CGRect(x: x - w, y: y - h, width: w * 2, height: h * 0.8))
                }
                trees.addRect(CGRect(x: x - h * 0.04, y: y - h * 0.3, width: h * 0.08, height: h * 0.3))
            }
            d += every
        }
        c.fill(trees, with: .color(palette.ground.color))
    }

    /// Cartel discreto en cada km y bandera en la meta (en silueta).
    private func drawMarkers(_ c: inout GraphicsContext, _ size: CGSize, pxPerM: CGFloat, riderX: CGFloat,
                             groundY: (Double) -> CGFloat) {
        let left = distance - Double(riderX / pxPerM)
        let right = distance + Double((size.width - riderX) / pxPerM)
        var d = max((left / 1000).rounded(.up), 1) * 1000
        while d <= right {
            let x = riderX + CGFloat(d - distance) * pxPerM
            let y = groundY(d)
            var post = Path()
            post.addRect(CGRect(x: x - 1, y: y - 30, width: 2, height: 30))
            c.fill(post, with: .color(palette.ground.color))
            let label = c.resolve(Text("km \(Int(d / 1000))").font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.ground.color))
            let box = CGRect(x: x - 22, y: y - 50, width: 44, height: 20)
            c.fill(Path(roundedRect: box, cornerRadius: 10), with: .color(.white.opacity(0.85)))
            c.draw(label, at: CGPoint(x: box.midX, y: box.midY))
            d += 1000
        }
        if !route.isLoop {
            let x = riderX + CGFloat(length - distance) * pxPerM
            if x > -40, x < size.width + 40 {
                let y = groundY(length)
                var pole = Path()
                pole.addRect(CGRect(x: x - 1.5, y: y - 64, width: 3, height: 64))
                c.fill(pole, with: .color(palette.ground.color))
                for row in 0..<3 {
                    for col in 0..<5 where (row + col).isMultiple(of: 2) {
                        c.fill(Path(CGRect(x: x + 1.5 + CGFloat(col) * 6, y: y - 64 + CGFloat(row) * 6, width: 6, height: 6)),
                               with: .color(.white))
                    }
                }
                c.stroke(Path(CGRect(x: x + 1.5, y: y - 64, width: 30, height: 18)), with: .color(palette.ground.color), lineWidth: 1)
            }
        }
    }

    /// El ciclista en silueta, de perfil, con las medidas de una bici de carretera y un ciclista
    /// de 1,75 m (1 m ≈ 48 px): ruedas que giran con la distancia, bielas y piernas a tu cadencia.
    /// Se pinta dos veces: primero un contorno de luz (para que no se pierda con los árboles) y
    /// encima la silueta; la pierna y el brazo del otro lado, un poco más claros.
    private func drawRider(_ c: inout GraphicsContext, at p: CGPoint, angle: Double, scale: CGFloat) {
        var g = c
        g.translateBy(x: p.x, y: p.y)
        g.rotate(by: .radians(angle))
        g.scaleBy(x: scale, y: scale)

        let rim = palette.ridges[2].mix(palette.skyBottom, 0.5).color
        drawFigure(&g, near: rim, far: rim, extra: 2.5)
        let ink = palette.ground
        drawFigure(&g, near: ink.color, far: ink.mix(palette.ridges[3], 0.55).color, extra: 0)
    }

    private func drawFigure(_ g: inout GraphicsContext, near: Color, far: Color, extra: CGFloat) {
        func line(_ pts: [CGPoint], _ width: CGFloat, _ color: Color) {
            var path = Path()
            path.move(to: pts[0])
            for q in pts.dropFirst() { path.addLine(to: q) }
            g.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width + extra, lineCap: .round, lineJoin: .round))
        }
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

        // Bici (55): ruedas de 700, batalla de 99 cm, eje de pedalier 7 cm por debajo de los ejes.
        let r: CGFloat = 16
        let rear = pt(-19.7, -r), front = pt(27.8, -r), bb = pt(0, -12.7)
        let seatCluster = pt(-7.1, -36.7), headTop = pt(18.7, -39.1), headBottom = pt(20.7, -32.2)
        let saddle = pt(-9.8, -45.8), barTop = pt(24, -41)
        let crankAngle = time * cadence / 60 * 2 * .pi
        let crank: CGFloat = 8.3
        func pedal(_ side: Double) -> CGPoint {
            pt(bb.x + CGFloat(cos(crankAngle + side)) * crank, bb.y + CGFloat(sin(crankAngle + side)) * crank)
        }

        // Ciclista: cadera sobre el sillín, tronco a ~42°, brazos a las manetas.
        let hip = pt(-11, -46.5)
        let shoulder = pt(-11 + 18.6, -46.5 - 16.7)
        let hands = pt(24.5, -40.5)
        let headCenter = pt(shoulder.x + 6.5, shoulder.y - 5.5)

        // Lado de lejos: pierna y brazo.
        let farPedal = pedal(.pi)
        let farKnee = Self.knee(hip: hip, foot: farPedal, thigh: 20.6, shin: 22.4)
        line([hip, farKnee], 7.5, far)
        line([farKnee, farPedal, pt(farPedal.x + 3.5, farPedal.y + 0.5)], 5, far)

        // Ruedas: cubierta, radios finos (para que se vea el giro) y buje.
        let turn = distance / 2.1 * 2 * .pi
        for w in [rear, front] {
            var tyre = Path()
            tyre.addEllipse(in: CGRect(x: w.x - r, y: w.y - r, width: r * 2, height: r * 2))
            g.stroke(tyre, with: .color(near), lineWidth: 3 + extra)
            if extra == 0 {
                var spokes = Path()
                for k in 0..<4 {
                    let a = turn + Double(k) * .pi / 4
                    spokes.move(to: pt(w.x + CGFloat(cos(a)) * r, w.y + CGFloat(sin(a)) * r))
                    spokes.addLine(to: pt(w.x - CGFloat(cos(a)) * r, w.y - CGFloat(sin(a)) * r))
                }
                g.stroke(spokes, with: .color(near.opacity(0.45)), lineWidth: 0.7)
            }
            g.fill(Path(ellipseIn: CGRect(x: w.x - 2 - extra / 2, y: w.y - 2 - extra / 2, width: 4 + extra, height: 4 + extra)),
                   with: .color(near))
        }

        // Cuadro, horquilla, tija, sillín, potencia y manillar de bajada.
        line([rear, bb, seatCluster, rear], 2.6, near)
        line([bb, headBottom, headTop, seatCluster], 3, near)
        line([headBottom, front], 2.4, near)
        line([seatCluster, pt(saddle.x + 1.5, saddle.y + 1.5)], 2.2, near)
        line([pt(saddle.x - 5, saddle.y), pt(saddle.x + 5.5, saddle.y + 0.4)], 2.6, near)
        line([headTop, barTop], 2.4, near)
        var drop = Path()
        drop.move(to: barTop)
        drop.addQuadCurve(to: pt(barTop.x + 1, barTop.y + 7.5), control: pt(barTop.x + 6, barTop.y + 3))
        g.stroke(drop, with: .color(near), style: StrokeStyle(lineWidth: 2.4 + extra, lineCap: .round))
        // Plato y biela de este lado.
        g.fill(Path(ellipseIn: CGRect(x: bb.x - 4.5 - extra / 2, y: bb.y - 4.5 - extra / 2, width: 9 + extra, height: 9 + extra)),
               with: .color(near))
        let nearPedal = pedal(0)
        line([bb, nearPedal], 2.4, near)

        // Brazo de lejos (detrás del tronco).
        let farElbow = Self.elbow(shoulder: pt(shoulder.x - 1, shoulder.y + 1), hand: pt(hands.x - 1, hands.y), upper: 14.4, fore: 13.2)
        line([pt(shoulder.x - 1, shoulder.y + 1), farElbow, pt(hands.x - 1, hands.y)], 4, far)

        // Tronco (más ancho en la espalda) y glúteo.
        g.fill(Path(ellipseIn: CGRect(x: hip.x - 6 - extra / 2, y: hip.y - 5 - extra / 2, width: 11 + extra, height: 10 + extra)),
               with: .color(near))
        var back = Path()
        back.move(to: hip)
        back.addQuadCurve(to: shoulder, control: pt((hip.x + shoulder.x) / 2 - 2, (hip.y + shoulder.y) / 2 - 5))
        g.stroke(back, with: .color(near), style: StrokeStyle(lineWidth: 11.5 + extra, lineCap: .round))

        // Pierna de cerca.
        let nearKnee = Self.knee(hip: hip, foot: nearPedal, thigh: 20.6, shin: 22.4)
        line([hip, nearKnee], 8.5, near)
        line([nearKnee, nearPedal], 5.5, near)
        line([nearPedal, pt(nearPedal.x + 4, nearPedal.y + 0.5)], 3.5, near)

        // Brazo de cerca.
        let elbow = Self.elbow(shoulder: shoulder, hand: hands, upper: 14.4, fore: 13.2)
        line([shoulder, elbow], 5, near)
        line([elbow, hands], 4.2, near)

        // Cuello, cabeza y casco alargado hacia atrás.
        line([shoulder, pt(headCenter.x - 2, headCenter.y + 2)], 5, near)
        g.fill(Path(ellipseIn: CGRect(x: headCenter.x - 5.3 - extra / 2, y: headCenter.y - 5.3 - extra / 2,
                                      width: 10.6 + extra, height: 10.6 + extra)), with: .color(near))
        var helmet = Path()
        helmet.move(to: pt(headCenter.x + 6, headCenter.y - 1.5))
        helmet.addQuadCurve(to: pt(headCenter.x - 9, headCenter.y - 2), control: pt(headCenter.x - 1, headCenter.y - 12))
        helmet.addQuadCurve(to: pt(headCenter.x + 6, headCenter.y - 1.5), control: pt(headCenter.x - 1, headCenter.y - 4))
        g.fill(helmet, with: .color(near))
        if extra > 0 { g.stroke(helmet, with: .color(near), lineWidth: extra) }
    }

    /// Codo de un brazo de dos tramos del hombro a la mano, doblado hacia abajo.
    static func elbow(shoulder: CGPoint, hand: CGPoint, upper: CGFloat, fore: CGFloat) -> CGPoint {
        let dx = hand.x - shoulder.x, dy = hand.y - shoulder.y
        let dist = min(max(sqrt(dx * dx + dy * dy), 1), upper + fore - 0.01)
        let a = (upper * upper - fore * fore + dist * dist) / (2 * dist)
        let h = sqrt(max(upper * upper - a * a, 0))
        let ux = dx / dist, uy = dy / dist
        let mid = CGPoint(x: shoulder.x + ux * a, y: shoulder.y + uy * a)
        let k1 = CGPoint(x: mid.x - uy * h, y: mid.y + ux * h)
        let k2 = CGPoint(x: mid.x + uy * h, y: mid.y - ux * h)
        return k1.y > k2.y ? k1 : k2
    }

    /// Rodilla de una pierna de dos tramos que va de la cadera al pie, doblada hacia delante.
    static func knee(hip: CGPoint, foot: CGPoint, thigh: CGFloat, shin: CGFloat) -> CGPoint {
        let dx = foot.x - hip.x, dy = foot.y - hip.y
        let dist = min(max(sqrt(dx * dx + dy * dy), 1), thigh + shin - 0.01)
        let a = (thigh * thigh - shin * shin + dist * dist) / (2 * dist)
        let h = sqrt(max(thigh * thigh - a * a, 0))
        let ux = dx / dist, uy = dy / dist
        let mid = CGPoint(x: hip.x + ux * a, y: hip.y + uy * a)
        // Las dos soluciones quedan a cada lado de la línea cadera–pie: la rodilla va hacia delante.
        let k1 = CGPoint(x: mid.x - uy * h, y: mid.y + ux * h)
        let k2 = CGPoint(x: mid.x + uy * h, y: mid.y - ux * h)
        return k1.x > k2.x ? k1 : k2
    }
}

private func fract(_ x: Double) -> Double { x - x.rounded(.down) }

// MARK: - Panel de datos y controles

/// Todo lo que se mira rodando, en un solo panel: potencia (con su zona), pulso, cadencia,
/// velocidad, pendiente y marcha; debajo, la ruta, la subida y el perfil entero con dónde vas.
private struct SceneHUD: View {
    let table: RouteElevationTable
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: 0) {
                powerCell
                divider
                SceneMetric("PULSO", hub.heartRateBpm.map { "\($0)" } ?? "—", "ppm",
                       caption: hub.heartRateBpm.map { let z = HeartRateZone(bpm: $0, max: ride.maxHeartRate); return "Z\(z.rawValue) · \(z.name)" })
                divider
                SceneMetric("CADENCIA", hub.bikeData.cadenceRpm.map { "\(Int($0.rounded()))" } ?? "—", "rpm")
                divider
                SceneMetric("VELOCIDAD", ride.speedKmh.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", "km/h")
                divider
                gradeCell
                divider
                GearGauge()
            }
        }
        .padding(Space.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.extraLarge))
        .frame(maxWidth: 1100)
    }

    private var divider: some View {
        Rectangle().fill(.separator).frame(width: 1, height: 52).padding(.horizontal, Space.m)
    }

    private var powerCell: some View {
        let watts = ride.power3s
        let zone = watts.map { PowerZone(fractionOfFTP: Double($0) / Double(max(ride.ftp, 1))) }
        return SceneMetric("POTENCIA", watts.map { "\($0)" } ?? "—", "W",
                      caption: zone.map { "Z\($0.rawValue) · \($0.name)" }, captionColor: zone?.color)
    }

    private var gradeCell: some View {
        let grade = ride.currentGrade
        let band = GradeBand(gradePercent: grade)
        return VStack(alignment: .leading, spacing: 4) {
            Text("PENDIENTE").font(Theme.font(.labelSmall)).foregroundStyle(.secondary)
            Text("\(grade.formatted(.number.precision(.fractionLength(1)))) %")
                .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(band.textColor)
                .padding(.horizontal, Space.s).padding(.vertical, 2)
                .background(band.color, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        }
        .fixedSize()
    }
}

/// Un dato: etiqueta, número grande con su unidad y una línea de contexto opcional.
private struct SceneMetric: View {
    let title: String
    let value: String
    let unit: String
    var caption: String?
    var captionColor: Color?

    init(_ title: String, _ value: String, _ unit: String, caption: String? = nil, captionColor: Color? = nil) {
        self.title = title; self.value = value; self.unit = unit; self.caption = caption; self.captionColor = captionColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.font(.labelSmall)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit).font(Theme.font(.bodyMedium)).foregroundStyle(.secondary)
            }
            if let caption {
                HStack(spacing: 4) {
                    if let captionColor { Circle().fill(captionColor).frame(width: 8, height: 8) }
                    Text(caption).font(Theme.font(.labelSmall)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// La marcha: «8 de 12», una escalera con todas las marchas (la tuya resaltada) y la combinación.
private struct GearGauge: View {
    @Environment(RideController.self) private var ride

    var body: some View {
        let n = ride.gears.number, count = ride.gears.count
        VStack(alignment: .leading, spacing: 4) {
            Text("MARCHA").font(Theme.font(.labelSmall)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(n)").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("de \(count)").font(Theme.font(.bodyMedium)).foregroundStyle(.secondary)
                Text(ride.gears.gear.label).font(Theme.font(.bodyMedium)).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: count > 12 ? 1.5 : 2.5) {
                ForEach(1...count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i == n ? Theme.accent : Color.primary.opacity(i < n ? 0.45 : 0.15))
                        .frame(width: count > 12 ? 4 : 6, height: 5 + CGFloat(i) / CGFloat(count) * 13)
                }
            }
            .animation(.easeOut(duration: 0.15), value: n)
        }
        .fixedSize()
        .help("Marcha \(n) de \(count) (\(ride.gears.gear.label)) · − más blanda, + más dura")
    }
}

/// Abajo: la ruta (km y subida), el perfil entero con el color de la pendiente y dónde vas,
/// y tres botones redondos: empezar/pausa, pantalla completa y salir. Las marchas, con los mandos.
private struct SceneBottomBar: View {
    let table: RouteElevationTable
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
                    Text(ride.route.name).font(Theme.font(.bodyMedium).weight(.semibold)).lineLimit(1)
                    Text(kmText).font(Theme.font(.bodyMedium)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: Space.m)
                    if let climb = climbText {
                        Label(climb, systemImage: "mountain.2.fill")
                            .font(Theme.font(.bodyMedium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                GradeProfile(table: table, position: ride.route.positionInLap(ride.session.distanceMeters))
                    .frame(height: 46)
            }
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

    private var kmText: String {
        let km = (ride.session.distanceMeters / 1000).formatted(.number.precision(.fractionLength(1)))
        let total = (ride.route.lengthMeters / 1000).formatted(.number.precision(.fractionLength(1)))
        return ride.route.isLoop ? "km \(km) · vuelta de \(total) km" : "km \(km) de \(total)"
    }

    private var climbText: String? {
        guard let s = ride.climbStatus else { return nil }
        func km(_ m: Double) -> String { (m / 1000).formatted(.number.precision(.fractionLength(1))) }
        let avg = s.climb.averageGradePercent.formatted(.number.precision(.fractionLength(1)))
        return s.isOnClimb
            ? "Subida: quedan \(km(s.remainingMeters)) km y \(Int(s.remainingAscentMeters)) m"
            : "Subida en \(km(s.distanceToStart)) km: \(km(s.climb.lengthMeters)) km al \(avg) %"
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
                let grade = (heights[i + 1] - heights[i]) / (length / Double(n)) * 100
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
