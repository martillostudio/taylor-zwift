import CicloBluetooth
import CicloKit
import SwiftUI

/// Simulador 2D: tú de perfil sobre el relieve real de la ruta, con el paisaje desplazándose a tu
/// velocidad. Ocupa toda la ventana (con «Pantalla completa», toda la pantalla); los datos clave
/// van encima. Esc o «Salir» para volver.
struct RideScene: View {
    @Environment(RideController.self) private var ride
    @Environment(BluetoothHub.self) private var hub
    @Environment(\.colorScheme) private var scheme
    @State private var motion = SceneMotion()

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let d = motion.distance(at: now, recorded: ride.session.distanceMeters,
                                            speedKmh: ride.isRunning ? ride.speedKmh ?? 0 : 0)
                    SceneRenderer(route: ride.route, table: motion.table(for: ride.route), distance: d, time: now,
                                  cadence: ride.isRunning ? hub.bikeData.cadenceRpm ?? 0 : 0,
                                  dark: scheme == .dark)
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

private struct SceneRenderer {
    let route: Route
    let table: RouteElevationTable
    let distance: Double
    let time: Double
    let cadence: Double
    let dark: Bool

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
        let baseY = size.height * 0.62

        func world(_ x: CGFloat) -> Double { distance + Double(x - riderX) / pxPerM }
        func groundY(_ d: Double) -> CGFloat { baseY - CGFloat((elevation(d) - camElevation)) * yPerM }

        drawSky(&c, size)
        drawMountains(&c, size, parallax: 0.06, height: 0.30, base: 0.50, seed: 1,
                      color: dark ? Color(red: 0.20, green: 0.24, blue: 0.34) : Color(red: 0.62, green: 0.70, blue: 0.82))
        drawMountains(&c, size, parallax: 0.18, height: 0.20, base: 0.60, seed: 2,
                      color: dark ? Color(red: 0.14, green: 0.24, blue: 0.20) : Color(red: 0.45, green: 0.62, blue: 0.48))

        // Terreno.
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
        c.fill(ground, with: .linearGradient(
            Gradient(colors: dark ? [Color(red: 0.16, green: 0.30, blue: 0.16), Color(red: 0.08, green: 0.14, blue: 0.08)]
                                  : [Color(red: 0.42, green: 0.66, blue: 0.32), Color(red: 0.30, green: 0.46, blue: 0.22)]),
            startPoint: CGPoint(x: 0, y: baseY - 100), endPoint: CGPoint(x: 0, y: size.height)))

        drawTrees(&c, size, pxPerM: pxPerM, riderX: riderX, groundY: groundY)

        // Carretera con el color de la pendiente (como el perfil).
        x = 0
        let chunk: CGFloat = 12
        while x <= size.width {
            let d0 = world(x), d1 = world(x + chunk)
            var p = Path()
            p.move(to: CGPoint(x: x, y: groundY(d0)))
            p.addLine(to: CGPoint(x: x + chunk, y: groundY(d1)))
            let color = d0 < 0 || (!route.isLoop && d0 > length)
                ? Color.gray : GradeBand(gradePercent: table.grade(atDistance: (d0 + d1) / 2)).color
            c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            x += chunk
        }

        drawPosts(&c, size, pxPerM: pxPerM, riderX: riderX, groundY: groundY)

        // Tú.
        let slope = atan2(Double(groundY(distance + 3) - groundY(distance - 3)), 6 * Double(pxPerM))
        drawRider(&c, at: CGPoint(x: riderX, y: groundY(distance)), angle: slope, scale: max(size.height / 700, 0.7))
    }

    private func elevation(_ d: Double) -> Double {
        table.elevation(atDistance: route.isLoop ? d : min(max(d, 0), length))
    }

    private func drawSky(_ c: inout GraphicsContext, _ size: CGSize) {
        let colors = dark ? [Color(red: 0.05, green: 0.07, blue: 0.16), Color(red: 0.16, green: 0.20, blue: 0.34)]
                          : [Color(red: 0.42, green: 0.66, blue: 0.95), Color(red: 0.82, green: 0.91, blue: 0.99)]
        c.fill(Path(CGRect(origin: .zero, size: size)),
               with: .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.7)))
        // Sol (o luna) y nubes que se mueven muy despacio.
        let r = size.height * 0.05
        c.fill(Path(ellipseIn: CGRect(x: size.width * 0.82, y: size.height * 0.08, width: r * 2, height: r * 2)),
               with: .color(dark ? Color(white: 0.92) : Color(red: 1, green: 0.93, blue: 0.62)))
        let cloudColor = Color.white.opacity(dark ? 0.12 : 0.85)
        let drift = distance * 0.03 + time * 2
        for i in 0..<6 {
            let spacing = size.width / 3
            var cx = CGFloat(Double(i) * Double(spacing) - drift.truncatingRemainder(dividingBy: Double(spacing * 6)))
            if cx < -spacing { cx += spacing * 6 }
            let cy = size.height * (0.10 + 0.07 * CGFloat(i % 3))
            let w = size.width * 0.09
            for (dx, dy, k) in [(0.0, 0.0, 1.0), (0.35, -0.18, 0.75), (0.7, 0.02, 0.85)] {
                c.fill(Path(ellipseIn: CGRect(x: cx + w * dx, y: cy + w * dy * 0.5, width: w * k, height: w * k * 0.55)),
                       with: .color(cloudColor))
            }
        }
    }

    /// Montañas de fondo: suma de senos (siempre las mismas para el mismo sitio), con paralaje.
    private func drawMountains(_ c: inout GraphicsContext, _ size: CGSize, parallax: Double, height: CGFloat,
                               base: CGFloat, seed: Double, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height))
        var x: CGFloat = 0
        while x <= size.width + 8 {
            let u = (Double(x) + distance * Double(size.width / Self.metersWide) * parallax) / Double(size.width)
            let n = 0.5 * sin(u * 3.1 + seed) + 0.3 * sin(u * 7.3 + seed * 2) + 0.2 * sin(u * 15.7 + seed * 3)
            p.addLine(to: CGPoint(x: x, y: size.height * base - CGFloat(n + 1) / 2 * size.height * height))
            x += 8
        }
        p.addLine(to: CGPoint(x: size.width + 8, y: size.height))
        p.closeSubpath()
        c.fill(p, with: .color(color))
    }

    /// Árboles a los lados (siempre en los mismos metros de la ruta).
    private func drawTrees(_ c: inout GraphicsContext, _ size: CGSize, pxPerM: CGFloat, riderX: CGFloat,
                           groundY: (Double) -> CGFloat) {
        let every = 35.0
        let first = ((distance - Double(riderX / pxPerM)) / every).rounded(.down) * every
        var d = first
        while d < distance + Double((size.width - riderX) / pxPerM) + every {
            let h = sin(d * 12.9898) * 43_758.5453
            let r = h - h.rounded(.down) // 0…1, fijo para cada sitio
            if r > 0.45 {
                let x = riderX + CGFloat(d - distance) * pxPerM
                let y = groundY(d) + 2
                let s = CGFloat(14 + r * 16) * pxPerM / 1.6
                var trunk = Path()
                trunk.addRect(CGRect(x: x - s * 0.08, y: y - s * 0.5, width: s * 0.16, height: s * 0.5))
                c.fill(trunk, with: .color(Color(red: 0.36, green: 0.25, blue: 0.16)))
                var crown = Path()
                crown.move(to: CGPoint(x: x, y: y - s * 1.9))
                crown.addLine(to: CGPoint(x: x - s * 0.55, y: y - s * 0.4))
                crown.addLine(to: CGPoint(x: x + s * 0.55, y: y - s * 0.4))
                crown.closeSubpath()
                c.fill(crown, with: .color(dark ? Color(red: 0.10, green: 0.28, blue: 0.16) : Color(red: 0.16, green: 0.45, blue: 0.22)))
            }
            d += every
        }
    }

    /// Postes cada 100 m y cartel en cada km; bandera a cuadros en la meta.
    private func drawPosts(_ c: inout GraphicsContext, _ size: CGSize, pxPerM: CGFloat, riderX: CGFloat,
                           groundY: (Double) -> CGFloat) {
        let left = distance - Double(riderX / pxPerM)
        let right = distance + Double((size.width - riderX) / pxPerM)
        var d = (left / 100).rounded(.up) * 100
        while d <= right {
            let x = riderX + CGFloat(d - distance) * pxPerM
            let y = groundY(d)
            let isKm = Int(d.rounded()) % 1000 == 0
            var post = Path()
            post.addRect(CGRect(x: x - 1, y: y - (isKm ? 34 : 12), width: 2, height: isKm ? 34 : 12))
            c.fill(post, with: .color(.white.opacity(0.85)))
            if isKm, d > 0 {
                let label = c.resolve(Text("km \(Int(d / 1000))").font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black))
                let box = CGRect(x: x - 24, y: y - 58, width: 48, height: 22)
                c.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(.white))
                c.draw(label, at: CGPoint(x: box.midX, y: box.midY))
            }
            d += 100
        }
        if !route.isLoop {
            let end = length
            let x = riderX + CGFloat(end - distance) * pxPerM
            if x > -20, x < size.width + 20 {
                let y = groundY(end)
                for row in 0..<3 {
                    for col in 0..<4 {
                        let r = CGRect(x: x + CGFloat(col) * 6, y: y - 60 + CGFloat(row) * 6, width: 6, height: 6)
                        c.fill(Path(r), with: .color((row + col).isMultiple(of: 2) ? .black : .white))
                    }
                }
                var pole = Path()
                pole.addRect(CGRect(x: x - 2, y: y - 60, width: 2, height: 60))
                c.fill(pole, with: .color(.white))
            }
        }
    }

    /// El ciclista: ruedas que giran con la distancia y piernas que pedalean a tu cadencia.
    private func drawRider(_ c: inout GraphicsContext, at p: CGPoint, angle: Double, scale: CGFloat) {
        var g = c
        g.translateBy(x: p.x, y: p.y)
        g.rotate(by: .radians(angle))
        g.scaleBy(x: scale, y: scale)

        let wheelR: CGFloat = 15
        let rear = CGPoint(x: -22, y: -wheelR), front = CGPoint(x: 24, y: -wheelR)
        let ink = dark ? Color(white: 0.92) : Color(white: 0.12)
        let accent = Theme.accent

        // Ruedas y radios.
        let wheelTurn = distance / 2.1 * 2 * .pi
        for center in [rear, front] {
            g.stroke(Path(ellipseIn: CGRect(x: center.x - wheelR, y: center.y - wheelR, width: wheelR * 2, height: wheelR * 2)),
                     with: .color(ink), lineWidth: 2.5)
            var spokes = Path()
            for k in 0..<3 {
                let a = wheelTurn + Double(k) * .pi / 3
                spokes.move(to: CGPoint(x: center.x + CGFloat(cos(a)) * wheelR, y: center.y + CGFloat(sin(a)) * wheelR))
                spokes.addLine(to: CGPoint(x: center.x - CGFloat(cos(a)) * wheelR, y: center.y - CGFloat(sin(a)) * wheelR))
            }
            g.stroke(spokes, with: .color(ink.opacity(0.5)), lineWidth: 0.8)
        }

        // Cuadro.
        let crank = CGPoint(x: 0, y: -wheelR + 1)
        let seat = CGPoint(x: -6, y: -40), bars = CGPoint(x: 18, y: -42)
        var frame = Path()
        frame.move(to: rear); frame.addLine(to: crank); frame.addLine(to: seat); frame.addLine(to: rear)
        frame.move(to: crank); frame.addLine(to: CGPoint(x: 16, y: -38)); frame.addLine(to: seat)
        frame.move(to: CGPoint(x: 16, y: -38)); frame.addLine(to: front)
        frame.move(to: CGPoint(x: 16, y: -38)); frame.addLine(to: bars)
        g.stroke(frame, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        // Piernas: pedales a la cadencia.
        let crankAngle = time * cadence / 60 * 2 * .pi
        let hip = CGPoint(x: -4, y: -46)
        for side in [0.0, .pi] {
            let a = crankAngle + side
            let pedal = CGPoint(x: crank.x + CGFloat(cos(a)) * 7, y: crank.y + CGFloat(sin(a)) * 7)
            // Rodilla: punto entre cadera y pedal, empujado hacia delante (piernas de 2 tramos de 24).
            let dx = pedal.x - hip.x, dy = pedal.y - hip.y
            let len = max(sqrt(dx * dx + dy * dy), 1)
            let half = min(len / 2, 23.5)
            let up = sqrt(max(24 * 24 - half * half, 0))
            let mid = CGPoint(x: hip.x + dx / 2, y: hip.y + dy / 2)
            let knee = CGPoint(x: mid.x + dy / len * up, y: mid.y - dx / len * up)
            var leg = Path()
            leg.move(to: hip); leg.addLine(to: knee); leg.addLine(to: pedal)
            g.stroke(leg, with: .color(ink.opacity(side == 0 ? 1 : 0.55)),
                     style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        }

        // Cuerpo, brazos y cabeza.
        let shoulder = CGPoint(x: 12, y: -64)
        var body = Path()
        body.move(to: hip); body.addLine(to: shoulder)
        g.stroke(body, with: .color(accent), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        var arm = Path()
        arm.move(to: shoulder); arm.addLine(to: CGPoint(x: 18, y: -52)); arm.addLine(to: bars)
        g.stroke(arm, with: .color(ink), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        g.fill(Path(ellipseIn: CGRect(x: 14, y: -80, width: 12, height: 12)), with: .color(ink))
        // Casco.
        var helmet = Path()
        helmet.addArc(center: CGPoint(x: 20, y: -74), radius: 7.5, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        g.fill(helmet, with: .color(accent))
    }
}

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
            } else {
                Button("Empezar", systemImage: "play.fill") { ride.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(ride.summary != nil || hub.trainerConnection != .connected)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(Space.s)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
