import CicloBluetooth
import CicloKit
import SwiftUI

/// Simulador 2D: tú de perfil sobre el relieve real de la ruta, con el paisaje desplazándose a tu
/// velocidad. Ocupa toda la ventana (con «Pantalla completa», toda la pantalla); los datos clave
/// van encima. Esc o «Salir» para volver.
struct RideScene: View {
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub
    @State private var motion = SceneMotion()
    @State private var palette = ScenePalette.now()

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let d = motion.distance(at: now, recorded: ride.session.distanceMeters,
                                            speedKmh: ride.isRunning ? ride.speedKmh ?? 0 : 0)
                    SceneRenderer(route: ride.route, table: motion.table(for: ride.route), distance: d, time: now,
                                  cadence: ride.isRunning ? hub.bikeData.cadenceRpm ?? 0 : 0,
                                  palette: palette)
                        .draw(in: &context, size: size)
                }
            }
            .ignoresSafeArea()
            VStack {
                SceneHUD()
                Spacer()
                SceneControls()
            }
            .padding(Space.xl)
        }
        .background(Color.black)
        // Datos y botones en claro u oscuro según la escena (de noche, oscuros).
        .environment(\.colorScheme, palette.isNight ? .dark : .light)
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

// MARK: - Dibujo

/// Colores de la escena según la hora: amanecer, día, atardecer o noche.
struct ScenePalette {
    var skyTop: Color
    var skyBottom: Color
    /// Sol o luna.
    var light: Color
    /// Altura del sol (0 = horizonte, 1 = arriba del todo).
    var lightHeight: CGFloat
    /// Capas de sierras, de la más lejana a la más cercana.
    var ridges: [Color]
    /// Terreno, árboles y ciclista (la silueta más oscura).
    var ground: Color
    var isNight: Bool

    /// Para probar otras horas: `--args -horaSimulador 20`.
    static func now(_ date: Date = Date()) -> ScenePalette {
        let forced = UserDefaults.standard.object(forKey: "horaSimulador") as? Int
        let hour = forced ?? Calendar.current.component(.hour, from: date)
        switch hour {
        case 6..<9: return .dawn
        case 9..<18: return .day
        case 18..<21: return .dusk
        default: return .night
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    static let day = ScenePalette(
        skyTop: rgb(0.36, 0.60, 0.86), skyBottom: rgb(0.80, 0.88, 0.93), light: rgb(1.0, 0.97, 0.88), lightHeight: 0.8,
        ridges: [rgb(0.62, 0.72, 0.80), rgb(0.45, 0.57, 0.66), rgb(0.30, 0.42, 0.48), rgb(0.19, 0.29, 0.32)],
        ground: rgb(0.10, 0.17, 0.18), isNight: false)
    static let dawn = ScenePalette(
        skyTop: rgb(0.40, 0.48, 0.72), skyBottom: rgb(0.99, 0.80, 0.62), light: rgb(1.0, 0.90, 0.70), lightHeight: 0.25,
        ridges: [rgb(0.80, 0.66, 0.68), rgb(0.60, 0.50, 0.58), rgb(0.40, 0.34, 0.45), rgb(0.25, 0.21, 0.32)],
        ground: rgb(0.13, 0.11, 0.18), isNight: false)
    static let dusk = ScenePalette(
        skyTop: rgb(0.24, 0.22, 0.45), skyBottom: rgb(0.98, 0.58, 0.38), light: rgb(1.0, 0.78, 0.52), lightHeight: 0.18,
        ridges: [rgb(0.80, 0.48, 0.45), rgb(0.58, 0.34, 0.40), rgb(0.38, 0.22, 0.32), rgb(0.22, 0.13, 0.22)],
        ground: rgb(0.11, 0.07, 0.12), isNight: false)
    static let night = ScenePalette(
        skyTop: rgb(0.03, 0.05, 0.12), skyBottom: rgb(0.13, 0.18, 0.30), light: rgb(0.92, 0.94, 1.0), lightHeight: 0.7,
        ridges: [rgb(0.17, 0.22, 0.33), rgb(0.12, 0.16, 0.26), rgb(0.08, 0.11, 0.19), rgb(0.05, 0.07, 0.13)],
        ground: rgb(0.02, 0.03, 0.06), isNight: true)
}

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
    static let verticalExaggeration = 4.0

    private var length: Double { table.lengthMeters }

    func draw(in c: inout GraphicsContext, size: CGSize) {
        let pxPerM = size.width / Self.metersWide
        let riderX = size.width * Self.riderX
        let yPerM = pxPerM * Self.verticalExaggeration
        // La cámara mira un poco por delante, para ver venir las subidas.
        let camElevation = (elevation(distance) * 2 + elevation(distance + 200)) / 3
        let baseY = size.height * 0.64

        func world(_ x: CGFloat) -> Double { distance + Double(x - riderX) / pxPerM }
        func groundY(_ d: Double) -> CGFloat { baseY - CGFloat(elevation(d) - camElevation) * yPerM }

        drawSky(&c, size)
        // Sierras: cuanto más lejos, más claras, más bajas en contraste y más despacio.
        let layers: [(parallax: Double, top: CGFloat, height: CGFloat, seed: Double)] = [
            (0.04, 0.36, 0.16, 1.3), (0.10, 0.44, 0.15, 2.7), (0.20, 0.52, 0.13, 4.1), (0.38, 0.60, 0.11, 5.9),
        ]
        for (i, l) in layers.enumerated() {
            drawRidge(&c, size, parallax: l.parallax, top: l.top, height: l.height, seed: l.seed,
                      color: palette.ridges[i])
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
        c.fill(ground, with: .color(palette.ground))

        // Línea fina con el color de la pendiente sobre el borde del terreno.
        x = 0
        let chunk: CGFloat = 10
        while x <= size.width {
            let d0 = world(x), d1 = world(x + chunk)
            var p = Path()
            p.move(to: CGPoint(x: x, y: groundY(d0)))
            p.addLine(to: CGPoint(x: x + chunk, y: groundY(d1)))
            let outside = d0 < 0 || (!route.isLoop && d0 > length)
            let color = outside ? Color.white.opacity(0.25)
                : GradeBand(gradePercent: table.grade(atDistance: (d0 + d1) / 2)).color
            c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            x += chunk
        }

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
        c.fill(Path(rect), with: .linearGradient(Gradient(colors: [palette.skyTop, palette.skyBottom]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.62)))
        if palette.isNight {
            // Estrellas fijas (siempre en el mismo sitio), con un parpadeo leve.
            for i in 0..<90 {
                let h1 = fract(sin(Double(i) * 12.9898) * 43_758.5453)
                let h2 = fract(sin(Double(i) * 78.233) * 12_345.678)
                let r = CGFloat(0.6 + h1 * 1.2)
                let twinkle = 0.55 + 0.45 * sin(time * (0.8 + h2) + Double(i))
                c.fill(Path(ellipseIn: CGRect(x: CGFloat(h1) * size.width, y: CGFloat(h2) * size.height * 0.45, width: r, height: r)),
                       with: .color(.white.opacity(0.35 + 0.5 * twinkle * h1)))
            }
        }
        // Sol o luna, con un halo suave.
        let r = size.height * 0.045
        let center = CGPoint(x: size.width * 0.74, y: size.height * (0.56 - 0.42 * palette.lightHeight))
        c.fill(Path(ellipseIn: CGRect(x: center.x - r * 7, y: center.y - r * 7, width: r * 14, height: r * 14)),
               with: .radialGradient(Gradient(colors: [palette.light.opacity(0.35), palette.light.opacity(0)]),
                                     center: center, startRadius: r, endRadius: r * 7))
        c.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
               with: .color(palette.light))
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
            Gradient(colors: [palette.skyBottom.opacity(0), palette.skyBottom.opacity(palette.isNight ? 0.12 : 0.35)]),
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
                let x = riderX + CGFloat(d - distance + (r - 0.5) * 6) * pxPerM
                let y = groundY(d) + 4
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
        c.fill(trees, with: .color(palette.ground))
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
            c.fill(post, with: .color(palette.ground))
            let label = c.resolve(Text("km \(Int(d / 1000))").font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.ground))
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
                c.fill(pole, with: .color(palette.ground))
                for row in 0..<3 {
                    for col in 0..<5 where (row + col).isMultiple(of: 2) {
                        c.fill(Path(CGRect(x: x + 1.5 + CGFloat(col) * 6, y: y - 64 + CGFloat(row) * 6, width: 6, height: 6)),
                               with: .color(.white))
                    }
                }
                c.stroke(Path(CGRect(x: x + 1.5, y: y - 64, width: 30, height: 18)), with: .color(palette.ground), lineWidth: 1)
            }
        }
    }

    /// El ciclista en silueta, de perfil: ruedas que giran con la distancia y piernas que
    /// pedalean a tu cadencia.
    private func drawRider(_ c: inout GraphicsContext, at p: CGPoint, angle: Double, scale: CGFloat) {
        var g = c
        g.translateBy(x: p.x, y: p.y)
        g.rotate(by: .radians(angle))
        g.scaleBy(x: scale, y: scale)
        let ink = palette.ground
        let wheelR: CGFloat = 16
        let rear = CGPoint(x: -24, y: -wheelR), front = CGPoint(x: 25, y: -wheelR)

        // Ruedas: llanta gruesa y buje; tres radios finos para que se note el giro.
        let turn = distance / 2.1 * 2 * .pi
        for w in [rear, front] {
            let rim = CGRect(x: w.x - wheelR, y: w.y - wheelR, width: wheelR * 2, height: wheelR * 2)
            g.stroke(Path(ellipseIn: rim), with: .color(ink), lineWidth: 3.2)
            var spokes = Path()
            for k in 0..<3 {
                let a = turn + Double(k) * .pi / 3
                spokes.move(to: CGPoint(x: w.x + CGFloat(cos(a)) * wheelR, y: w.y + CGFloat(sin(a)) * wheelR))
                spokes.addLine(to: CGPoint(x: w.x - CGFloat(cos(a)) * wheelR, y: w.y - CGFloat(sin(a)) * wheelR))
            }
            g.stroke(spokes, with: .color(ink.opacity(0.6)), lineWidth: 0.8)
        }

        // Cuadro de carretera.
        let bb = CGPoint(x: 0, y: -wheelR + 2)
        let seatTop = CGPoint(x: -7, y: -40), headTop = CGPoint(x: 17, y: -41), headBottom = CGPoint(x: 19, y: -33)
        var frame = Path()
        frame.move(to: rear); frame.addLine(to: bb); frame.addLine(to: seatTop); frame.addLine(to: rear)
        frame.move(to: bb); frame.addLine(to: headBottom); frame.addLine(to: headTop); frame.addLine(to: seatTop)
        frame.move(to: headBottom); frame.addLine(to: front)
        g.stroke(frame, with: .color(ink), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        // Sillín y manillar de bajada.
        var parts = Path()
        parts.move(to: CGPoint(x: -13, y: -43)); parts.addLine(to: CGPoint(x: -1, y: -43))
        parts.move(to: headTop); parts.addLine(to: CGPoint(x: 23, y: -42))
        parts.addQuadCurve(to: CGPoint(x: 22, y: -34), control: CGPoint(x: 28, y: -38))
        g.stroke(parts, with: .color(ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        // Piernas: pedal a la cadencia; rodilla por cinemática de dos tramos.
        let hip = CGPoint(x: -6, y: -47)
        let crankAngle = time * cadence / 60 * 2 * .pi
        for (k, side) in [0.0, Double.pi].enumerated() {
            let a = crankAngle + side
            let pedal = CGPoint(x: bb.x + CGFloat(cos(a)) * 8, y: bb.y + CGFloat(sin(a)) * 8)
            let knee = Self.knee(hip: hip, foot: pedal, thigh: 21, shin: 21)
            var leg = Path()
            leg.move(to: hip); leg.addLine(to: knee); leg.addLine(to: pedal)
            g.stroke(leg, with: .color(ink.opacity(k == 0 ? 1 : 0.75)),
                     style: StrokeStyle(lineWidth: k == 0 ? 7 : 6, lineCap: .round, lineJoin: .round))
        }

        // Tronco inclinado, brazos al manillar, cabeza y casco.
        let shoulder = CGPoint(x: 13, y: -63)
        var torso = Path()
        torso.move(to: hip); torso.addQuadCurve(to: shoulder, control: CGPoint(x: 0, y: -62))
        g.stroke(torso, with: .color(ink), style: StrokeStyle(lineWidth: 11, lineCap: .round))
        var arm = Path()
        arm.move(to: shoulder); arm.addLine(to: CGPoint(x: 20, y: -50)); arm.addLine(to: CGPoint(x: 24, y: -41))
        g.stroke(arm, with: .color(ink), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        g.fill(Path(ellipseIn: CGRect(x: 15, y: -78, width: 11, height: 11)), with: .color(ink))
        var helmet = Path()
        helmet.move(to: CGPoint(x: 12, y: -72))
        helmet.addQuadCurve(to: CGPoint(x: 27, y: -73), control: CGPoint(x: 18, y: -83))
        helmet.addLine(to: CGPoint(x: 12, y: -72))
        g.fill(helmet, with: .color(ink))
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

// MARK: - Datos y controles

/// Lo que se mira rodando: vatios, pulso, cadencia, velocidad, pendiente, marcha y la subida.
private struct SceneHUD: View {
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub

    var body: some View {
        let grade = ride.currentGrade
        let band = GradeBand(gradePercent: grade)
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                tile("POTENCIA", ride.power3s.map { "\($0)" } ?? "—", "W",
                     color: ride.power3s.map { PowerZone(fractionOfFTP: Double($0) / Double(max(ride.ftp, 1))).color })
                tile("PULSO", hub.heartRateBpm.map { "\($0)" } ?? "—", "ppm")
                tile("CADENCIA", hub.bikeData.cadenceRpm.map { "\(Int($0.rounded()))" } ?? "—", "rpm")
                tile("VELOCIDAD", ride.speedKmh.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", "km/h")
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(grade.formatted(.number.precision(.fractionLength(1)))) %")
                        .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(band.textColor)
                        .padding(.horizontal, Space.m)
                        .background(band.color, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                    Text("marcha \(ride.gearText)").font(Theme.font(.bodyMedium)).foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
            HStack(spacing: Space.m) {
                let km = ride.session.distanceMeters / 1000
                Text("\(ride.route.name) · km \(km.formatted(.number.precision(.fractionLength(1))))"
                     + (ride.route.isLoop ? "" : " de \((ride.route.lengthMeters / 1000).formatted(.number.precision(.fractionLength(1))))"))
                if let s = ride.climbStatus {
                    Text(s.isOnClimb
                         ? "⛰ Quedan \((s.remainingMeters / 1000).formatted(.number.precision(.fractionLength(1)))) km · +\(Int(s.remainingAscentMeters)) m"
                         : "⛰ Subida en \((s.distanceToStart / 1000).formatted(.number.precision(.fractionLength(1)))) km: \((s.climb.lengthMeters / 1000).formatted(.number.precision(.fractionLength(1)))) km al \(s.climb.averageGradePercent.formatted(.number.precision(.fractionLength(1)))) %")
                }
            }
            .font(Theme.font(.bodyLarge).weight(.semibold))
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func tile(_ title: String, _ value: String, _ unit: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.font(.labelSmall)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color ?? Color.primary)
                Text(unit).font(Theme.font(.bodyMedium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .frame(minWidth: 130, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
    }
}

private struct SceneControls: View {
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub

    var body: some View {
        HStack(spacing: Space.m) {
            Button("Salir", systemImage: "xmark") { ride.showScene = false }
                .keyboardShortcut(.cancelAction)
            #if os(macOS)
            Button("Pantalla completa", systemImage: "arrow.up.left.and.arrow.down.right") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            #endif
            Spacer()
            Button("Más blanda", systemImage: "minus") { ride.easier() }
            Button("Más dura", systemImage: "plus") { ride.harder() }
            if ride.isRunning {
                Button("Pausa", systemImage: "pause.fill") { ride.pause() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            } else {
                Button("Empezar", systemImage: "play.fill") { ride.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(ride.summary != nil || hub.trainerConnection != .connected)
            }
        }
        .buttonStyle(.bordered)
        .tint(.primary) // texto oscuro: se lee mejor que el naranja sobre el paisaje
        .controlSize(.large)
        .padding(Space.s)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
