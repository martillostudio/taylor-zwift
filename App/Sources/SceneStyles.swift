import CicloKit
import SwiftUI

/// Estilos del simulador 2D. Se elige en el propio simulador y se recuerda.
enum SceneStyle: String, CaseIterable, Identifiable {
    case silhouette = "siluetas"
    case pixel
    case print = "grabado"
    case clearLine = "lineaclara"
    /// Pixel art con fondos de packs (App/Escenarios), en SpriteKit.
    case pixelWorld = "escenarios"

    var id: String { rawValue }

    /// Los que se pueden elegir (los escenarios, solo si están instalados).
    static var selectable: [SceneStyle] { allCases.filter { $0 != .pixelWorld || !PixelZone.available.isEmpty } }

    var title: String {
        switch self {
        case .silhouette: "Siluetas"
        case .pixel: "Pixel art"
        case .print: "Grabado japonés"
        case .clearLine: "Línea clara"
        case .pixelWorld: "Escenarios (pixel art)"
        }
    }

    var systemImage: String {
        switch self {
        case .silhouette: "mountain.2"
        case .pixel: "square.grid.3x3.fill"
        case .print: "paintbrush.pointed"
        case .clearLine: "pencil.line"
        case .pixelWorld: "photo.stack"
        }
    }

    /// Fotogramas del cielo de cada estilo.
    var keys: ScenePalette.Keys {
        switch self {
        case .silhouette, .pixel, .pixelWorld: .silhouette
        case .print: .print
        case .clearLine: .clearLine
        }
    }
}

/// Dónde cae cada cosa en pantalla: lo comparten todos los estilos.
struct SceneCamera {
    let size: CGSize
    let distance: Double
    let table: RouteElevationTable
    let isLoop: Bool
    let pxPerM: CGFloat
    let riderX: CGFloat
    let yPerM: CGFloat
    let baseY: CGFloat
    private let camElevation: Double

    static let metersWide = 650.0

    init(size: CGSize, distance: Double, table: RouteElevationTable, isLoop: Bool) {
        self.size = size
        self.distance = distance
        self.table = table
        self.isLoop = isLoop
        pxPerM = size.width / Self.metersWide
        riderX = size.width * 0.3
        yPerM = pxPerM * 2.5
        baseY = size.height * 0.68
        func ele(_ d: Double) -> Double { table.elevation(atDistance: isLoop ? d : min(max(d, 0), table.lengthMeters)) }
        camElevation = (ele(distance) * 3 + ele(distance + 150)) / 4
    }

    func elevation(_ d: Double) -> Double {
        table.elevation(atDistance: isLoop ? d : min(max(d, 0), table.lengthMeters))
    }

    func world(_ x: CGFloat) -> Double { distance + Double(x - riderX) / pxPerM }
    func screenX(_ d: Double) -> CGFloat { riderX + CGFloat(d - distance) * pxPerM }
    func groundY(_ d: Double) -> CGFloat { baseY - CGFloat(elevation(d) - camElevation) * yPerM }

    var leftMeters: Double { world(0) }
    var rightMeters: Double { world(size.width) }

    /// Inclinación del terreno donde vas (radianes, en pantalla).
    var slope: Double { atan2(Double(groundY(distance + 3) - groundY(distance - 3)), 6 * Double(pxPerM)) }
    var riderPoint: CGPoint { CGPoint(x: riderX, y: groundY(distance) - 1) }
    var riderScale: CGFloat { max(size.height / 600, 0.8) }
}

func fract(_ x: Double) -> Double { x - x.rounded(.down) }
/// Número «aleatorio» fijo para cada valor (0…1).
func hash01(_ x: Double) -> Double { fract(sin(x * 12.9898 + 78.233) * 43_758.5453) }

/// Sierra de fondo: ruido suave con paralaje (0 = fija, 1 = a tu velocidad). Altura en fracción del alto.
func ridgeHeight(x: CGFloat, camera cam: SceneCamera, parallax: Double, seed: Double) -> Double {
    let shift = cam.distance * Double(cam.pxPerM) * parallax
    let u = (Double(x) + shift) / Double(cam.size.width)
    return 0.55 * sin(u * 2.3 + seed) + 0.28 * sin(u * 5.9 + seed * 1.7)
        + 0.12 * sin(u * 13.1 + seed * 2.9) + 0.05 * sin(u * 31.7 + seed * 4.3)
}

// MARK: - Pixel art

/// Pixel art: todo en una rejilla de píxeles gordos, con paleta por bandas, árboles como sprites y
/// el ciclista rasterizado con contorno de 1 píxel. El fondo se mueve de píxel en píxel.
struct PixelRenderer {
    let cam: SceneCamera
    let palette: ScenePalette
    let time: Double
    /// Ángulo de las bielas (radianes), acumulado con la cadencia suavizada.
    let crank: Double

    var pixel: CGFloat { max(2, (cam.size.height / 290).rounded()) }

    /// De día, colores vivos; de noche, apagados hacia el azul.
    private var shade: Double { min(palette.stars * 0.72 + (1 - luminance(palette.skyBottom)) * 0.25, 0.8) }
    private func lit(_ c: RGB) -> RGB { c.mix(palette.ground.mix(palette.skyTop, 0.3), shade) }
    private func luminance(_ c: RGB) -> Double { 0.3 * c.r + 0.59 * c.g + 0.11 * c.b }

    func draw(in c: inout GraphicsContext) {
        let P = pixel
        let size = cam.size
        func snap(_ v: CGFloat) -> CGFloat { (v / P).rounded(.down) * P }

        // Cielo en bandas, con una fila de tramado entre banda y banda.
        let bands = 9
        let skyBottomY = snap(size.height * 0.7)
        let bandH = snap(skyBottomY / CGFloat(bands)) + P
        for b in 0..<bands {
            let color = palette.skyTop.mix(palette.skyBottom, Double(b) / Double(bands - 1)).color
            c.fill(Path(CGRect(x: 0, y: CGFloat(b) * bandH, width: size.width, height: bandH + P)), with: .color(color))
            if b > 0 {
                let prev = palette.skyTop.mix(palette.skyBottom, Double(b - 1) / Double(bands - 1)).color
                var dither = Path()
                var x: CGFloat = 0
                while x < size.width { dither.addRect(CGRect(x: x, y: CGFloat(b) * bandH, width: P, height: P)); x += 2 * P }
                c.fill(dither, with: .color(prev))
            }
        }
        c.fill(Path(CGRect(x: 0, y: CGFloat(bands) * bandH, width: size.width, height: size.height)),
               with: .color(palette.skyBottom.color))

        // Estrellas.
        if palette.stars > 0 {
            var stars = Path()
            var bright = Path()
            for i in 0..<70 {
                let x = snap(CGFloat(hash01(Double(i))) * size.width), y = snap(CGFloat(hash01(Double(i) + 0.37)) * size.height * 0.5)
                stars.addRect(CGRect(x: x, y: y, width: P, height: P))
                if i % 9 == 0, sin(time * 1.3 + Double(i)) > 0.2 {
                    bright.addRect(CGRect(x: x - P, y: y, width: 3 * P, height: P))
                    bright.addRect(CGRect(x: x, y: y - P, width: P, height: 3 * P))
                }
            }
            c.fill(stars, with: .color(.white.opacity(0.7 * palette.stars)))
            c.fill(bright, with: .color(.white.opacity(0.5 * palette.stars)))
        }

        // Sol o luna: disco de píxeles con un halo de dos escalones.
        let center = CGPoint(x: snap(size.width * palette.lightX), y: snap(size.height * palette.lightY))
        let r = max(5, Int((size.height * 0.04 / P).rounded()))
        for (extra, alpha) in [(3, 0.12), (1, 0.22)] {
            pixelDisc(&c, center: center, radius: r + extra, color: palette.light.color.opacity(alpha))
        }
        pixelDisc(&c, center: center, radius: r, color: palette.light.color)
        if palette.isMoon {
            pixelDisc(&c, center: CGPoint(x: center.x + CGFloat(r) * 0.55 * P, y: center.y - CGFloat(r) * 0.25 * P),
                      radius: r, color: palette.skyTop.mix(palette.skyBottom, palette.lightY / 0.7).color)
        }

        // Nubes de píxeles (de día).
        if palette.stars < 0.9 {
            let cloud = RGB(1, 1, 1).mix(palette.skyBottom, 0.25).color.opacity(0.9 * (1 - palette.stars))
            for i in 0..<5 {
                let spacing = size.width / 2.4
                var x = CGFloat(Double(i) * Double(spacing)) - CGFloat(cam.distance * Double(cam.pxPerM) * 0.05 + time * 3)
                    .truncatingRemainder(dividingBy: spacing * 5)
                if x < -spacing { x += spacing * 5 }
                let y = size.height * (0.12 + 0.08 * CGFloat(i % 3))
                pixelCloud(&c, at: CGPoint(x: snap(x), y: snap(y)), width: Int(6 + hash01(Double(i)) * 8), color: cloud)
            }
        }

        // Sierras por columnas, con la cresta en un tono más claro.
        let layers: [(Double, CGFloat, CGFloat, Double)] = [(0.04, 0.38, 0.16, 1.3), (0.10, 0.46, 0.14, 2.7),
                                                             (0.20, 0.54, 0.12, 4.1), (0.38, 0.62, 0.10, 5.9)]
        for (i, l) in layers.enumerated() {
            var body = Path(), crest = Path()
            var x: CGFloat = 0
            while x < size.width {
                let n = ridgeHeight(x: x, camera: cam, parallax: l.0, seed: l.3)
                let top = snap(size.height * l.1 - CGFloat(n) * size.height * l.2)
                body.addRect(CGRect(x: x, y: top, width: P, height: size.height - top))
                crest.addRect(CGRect(x: x, y: top, width: P, height: P))
                x += P
            }
            let color = palette.ridges[i]
            c.fill(body, with: .color(color.color))
            c.fill(crest, with: .color(color.mix(palette.skyBottom, 0.35).color))
        }

        // Árboles (sprites) detrás de la carretera.
        drawTrees(&c)

        // Terreno: camino de tierra arriba, borde de hierba y el resto con motas.
        let road = lit(RGB(0.80, 0.70, 0.52)), roadDark = lit(RGB(0.66, 0.55, 0.40))
        let grassTop = lit(RGB(0.42, 0.62, 0.26)), grass = lit(RGB(0.30, 0.47, 0.20)), speck = lit(RGB(0.23, 0.38, 0.15))
        var roadPath = Path(), roadEdge = Path(), grassEdge = Path(), body = Path(), specks = Path()
        var x: CGFloat = 0
        while x < size.width {
            let d = cam.world(x + P / 2)
            let top = snap(cam.groundY(d))
            roadPath.addRect(CGRect(x: x, y: top, width: P, height: 2 * P))
            if hash01((d / 1.5).rounded()) > 0.7 { roadEdge.addRect(CGRect(x: x, y: top + P, width: P, height: P)) }
            grassEdge.addRect(CGRect(x: x, y: top + 2 * P, width: P, height: P))
            body.addRect(CGRect(x: x, y: top + 3 * P, width: P, height: size.height - top))
            let col = (d / Double(P / cam.pxPerM)).rounded()
            for k in 0..<3 where hash01(col * 3.1 + Double(k)) > 0.55 {
                let depth = CGFloat(Int(hash01(col + Double(k) * 7.7) * 30) + 4)
                specks.addRect(CGRect(x: x, y: top + depth * P, width: P, height: P))
            }
            x += P
        }
        c.fill(body, with: .color(grass.color))
        c.fill(specks, with: .color(speck.color))
        c.fill(grassEdge, with: .color(grassTop.color))
        c.fill(roadPath, with: .color(road.color))
        c.fill(roadEdge, with: .color(roadDark.color))

        drawMarkers(&c)
        drawRider(&c)
    }

    private func pixelDisc(_ c: inout GraphicsContext, center: CGPoint, radius r: Int, color: Color) {
        var p = Path()
        for j in -r...r {
            let half = Int((sqrt(Double(r * r - j * j)) + 0.3).rounded(.down))
            p.addRect(CGRect(x: center.x - CGFloat(half) * pixel, y: center.y + CGFloat(j) * pixel,
                             width: CGFloat(2 * half + 1) * pixel, height: pixel))
        }
        c.fill(p, with: .color(color))
    }

    private func pixelCloud(_ c: inout GraphicsContext, at o: CGPoint, width w: Int, color: Color) {
        let P = pixel
        var p = Path()
        p.addRect(CGRect(x: o.x, y: o.y, width: CGFloat(w) * P, height: 2 * P))
        p.addRect(CGRect(x: o.x + 2 * P, y: o.y - P, width: CGFloat(w - 4) * P, height: P))
        p.addRect(CGRect(x: o.x + 3 * P, y: o.y - 2 * P, width: CGFloat(max(w / 3, 2)) * P, height: P))
        p.addRect(CGRect(x: o.x - P, y: o.y + P, width: CGFloat(w + 2) * P, height: P))
        c.fill(p, with: .color(color))
    }

    /// Sprites: «L» hoja, «D» hoja oscura, «T» tronco.
    private static let pine = [
        "...L...", "..LLL..", "..LDL..", ".LLLLL.", ".LDLDL.", "LLLLLLL", ".LLDLL.", "LLLLLLL",
        "LDLLLDL", "...T...", "...T...",
    ]
    private static let round = [
        "..LLL..", ".LLLLL.", "LLDLLLL", "LLLLLDL", "LDLLLLL", ".LLLLL.", "..LTL..", "...T...", "...T...",
    ]

    private func drawTrees(_ c: inout GraphicsContext) {
        let P = pixel
        let leaf = lit(RGB(0.24, 0.48, 0.22)), dark = lit(RGB(0.16, 0.34, 0.16)), trunk = lit(RGB(0.40, 0.28, 0.18))
        var paths: [Character: Path] = [:]
        let every = 9.0
        var d = (cam.leftMeters / every).rounded(.down) * every - every
        while d < cam.rightMeters + every {
            let r = hash01(d)
            let grove = sin(d / 90 + 1.3) + 0.6 * sin(d / 37)
            if grove > 0.15, r > 0.3 {
                let sprite = r > 0.62 ? Self.pine : Self.round
                let scale = r > 0.85 ? 2 : 1
                let x0 = (cam.screenX(d) / P).rounded(.down) * P
                let y0 = (cam.groundY(d) / P).rounded(.down) * P + P
                for (j, row) in sprite.reversed().enumerated() {
                    for (i, ch) in row.enumerated() where ch != "." {
                        let rect = CGRect(x: x0 + CGFloat((i - 3) * scale) * P, y: y0 - CGFloat((j + 1) * scale) * P,
                                          width: CGFloat(scale) * P, height: CGFloat(scale) * P)
                        paths[ch, default: Path()].addRect(rect)
                    }
                }
            }
            d += every
        }
        if let p = paths["L"] { c.fill(p, with: .color(leaf.color)) }
        if let p = paths["D"] { c.fill(p, with: .color(dark.color)) }
        if let p = paths["T"] { c.fill(p, with: .color(trunk.color)) }
    }

    private func drawMarkers(_ c: inout GraphicsContext) {
        let P = pixel
        var d = max((cam.leftMeters / 1000).rounded(.up), 1) * 1000
        while d <= cam.rightMeters {
            let x = (cam.screenX(d) / P).rounded(.down) * P
            let y = (cam.groundY(d) / P).rounded(.down) * P
            c.fill(Path(CGRect(x: x, y: y - 9 * P, width: P, height: 9 * P)), with: .color(lit(RGB(0.45, 0.32, 0.20)).color))
            let box = CGRect(x: x - 6 * P, y: y - 15 * P, width: 13 * P, height: 6 * P)
            c.fill(Path(box), with: .color(lit(RGB(0.95, 0.92, 0.82)).color))
            c.stroke(Path(box.insetBy(dx: P / 2, dy: P / 2)), with: .color(lit(RGB(0.45, 0.32, 0.20)).color), lineWidth: P)
            let label = c.resolve(Text("\(Int(d / 1000)) km").font(.system(size: P * 3.2, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color(white: 0.15)))
            c.draw(label, at: CGPoint(x: box.midX, y: box.midY))
            d += 1000
        }
    }

    private func drawRider(_ c: inout GraphicsContext) {
        let parts = RiderModel.parts(crank: crank, distance: cam.distance)
        let origin = cam.riderPoint, angle = cam.slope, s = cam.riderScale
        let cosA = CGFloat(cos(-angle)), sinA = CGFloat(sin(-angle))
        let b = RiderModel.bounds
        let box = CGRect(x: origin.x + b.minX * s * 1.2, y: origin.y + b.minY * s * 1.15,
                         width: b.width * s * 1.25, height: b.height * s * 1.25)
        // Luz delantera de noche: un haz corto y suave por delante.
        if palette.stars > 0.3 {
            var beam = Path()
            let P = pixel
            let start = CGPoint(x: origin.x + 31 * s, y: origin.y - 36 * s)
            for k in 0..<28 {
                let x = start.x + CGFloat(k) * P
                let spread = CGFloat(k) * 0.22
                let yMid = start.y + CGFloat(k) * P * 0.32 + CGFloat(tan(angle)) * CGFloat(k) * P
                var j = -spread.rounded(.down)
                while j <= spread {
                    beam.addRect(CGRect(x: (x / P).rounded() * P, y: ((yMid + j * P) / P).rounded() * P, width: P, height: P))
                    j += 1
                }
            }
            c.fill(beam, with: .linearGradient(
                Gradient(colors: [RGB(1, 0.95, 0.75).color.opacity(0.28 * palette.stars), .clear]),
                startPoint: start, endPoint: CGPoint(x: start.x + 28 * P, y: start.y)))
        }
        RiderModel.drawPixels(&c, parts: parts, screenBox: box, pixel: pixel, toLocal: { p in
            let dx = (p.x - origin.x) / s, dy = (p.y - origin.y) / s
            return CGPoint(x: dx * cosA - dy * sinA, y: dx * sinA + dy * cosA)
        }, outline: Color(red: 0.06, green: 0.06, blue: 0.09), tint: { $0.mix(palette.skyTop, palette.stars * 0.1) })
    }
}

// MARK: - Grabado japonés

/// Inspirado en el grabado ukiyo-e clásico (sin copiar ninguna obra): papel con fibras, franja
/// de azul de Prusia arriba (bokashi), nubes de borde festoneado, montañas con trazos paralelos
/// de gubia, bruma en franjas, pinos retorcidos con copas de agujas, camino claro, cartela con el
/// nombre de la ruta y sello rojo. Todo con línea de tinta de grosor variable.
struct PrintRenderer {
    let cam: SceneCamera
    let palette: ScenePalette
    let time: Double
    /// Ángulo de las bielas (radianes), acumulado con la cadencia suavizada.
    let crank: Double
    let routeName: String

    private let ink = RGB(0.09, 0.09, 0.13)
    private var paper: RGB { RGB(0.94, 0.89, 0.77).mix(palette.skyBottom, 0.25 + 0.5 * palette.stars) }
    private var inkColor: Color { ink.color }

    func draw(in c: inout GraphicsContext) {
        let size = cam.size
        drawSky(&c, size)
        drawMoon(&c, size)
        drawClouds(&c, size, row: 0)

        // Cordillera lejana, colinas medias con arboledas, bruma y colinas cercanas.
        let layers: [(Double, CGFloat, CGFloat, Double)] = [(0.04, 0.40, 0.19, 1.3), (0.12, 0.52, 0.12, 3.3), (0.26, 0.61, 0.09, 5.9)]
        for (i, l) in layers.enumerated() {
            drawRange(&c, size, parallax: l.0, top: l.1, height: l.2, seed: l.3, color: palette.ridges[i], index: i)
            if i == 0 { drawMist(&c, y: size.height * 0.47) }
        }
        drawClouds(&c, size, row: 1)
        drawPines(&c)
        drawGround(&c, size)
        drawMarkers(&c)
        drawRider(&c)
        drawCartouche(&c, size)
        drawPaper(&c, size)
    }

    // MARK: Cielo, luna y nubes

    private func drawSky(_ c: inout GraphicsContext, _ size: CGSize) {
        c.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(colors: [palette.skyTop.color, palette.skyBottom.mix(paper, 0.35).color]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.6)))
        // Franja de azul de Prusia arriba, con el borde inferior difuminado (bokashi).
        let prussian = RGB(0.07, 0.16, 0.34).mix(palette.skyTop, 0.35)
        c.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.3)), with: .linearGradient(
            Gradient(stops: [.init(color: prussian.color, location: 0), .init(color: prussian.color.opacity(0.85), location: 0.45),
                             .init(color: prussian.color.opacity(0), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.3)))
        if palette.stars > 0 {
            var stars = Path()
            for i in 0..<45 {
                let x = CGFloat(hash01(Double(i))) * size.width, y = CGFloat(hash01(Double(i) + 0.5)) * size.height * 0.4
                stars.addEllipse(in: CGRect(x: x, y: y, width: 2.2, height: 2.2))
            }
            c.fill(stars, with: .color(paper.mix(RGB(1, 1, 1), 0.5).color.opacity(0.75 * palette.stars)))
        }
    }

    private func drawMoon(_ c: inout GraphicsContext, _ size: CGSize) {
        let r = size.height * 0.08
        let center = CGPoint(x: size.width * palette.lightX, y: size.height * palette.lightY)
        let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        c.fill(disc, with: .color(palette.light.color))
        c.stroke(disc, with: .color(inkColor.opacity(0.8)), lineWidth: 1.6)
    }

    /// Nube de grabado: base recta con dos líneas de tinta y la parte de arriba festoneada.
    private func cloud(at o: CGPoint, width w: CGFloat, seed: Double) -> (Path, Path) {
        var p = Path()
        var lines = Path()
        let lobes = 4 + Int(hash01(seed) * 3)
        let base = o.y
        p.move(to: CGPoint(x: o.x, y: base))
        var x = o.x
        let step = w / CGFloat(lobes)
        for k in 0..<lobes {
            let rr = step * (0.55 + 0.25 * CGFloat(hash01(seed + Double(k))))
            let lift = rr * (k == 0 || k == lobes - 1 ? 0.7 : 1.15)
            p.addCurve(to: CGPoint(x: x + step, y: base),
                       control1: CGPoint(x: x - step * 0.1, y: base - lift * 1.6),
                       control2: CGPoint(x: x + step * 1.1, y: base - lift * 1.6))
            x += step
        }
        p.closeSubpath()
        lines.move(to: CGPoint(x: o.x + step * 0.4, y: base - 4))
        lines.addLine(to: CGPoint(x: o.x + w - step * 0.3, y: base - 4))
        lines.move(to: CGPoint(x: o.x + step * 0.9, y: base - 8))
        lines.addLine(to: CGPoint(x: o.x + w - step * 0.8, y: base - 8))
        return (p, lines)
    }

    private func drawClouds(_ c: inout GraphicsContext, _ size: CGSize, row: Int) {
        let fill = paper.mix(RGB(1, 1, 1), 0.3).mix(palette.skyTop, 0.15 + 0.45 * palette.stars)
        let drift = CGFloat(cam.distance * Double(cam.pxPerM) * (row == 0 ? 0.03 : 0.07) + time * (row == 0 ? 2 : 3.5))
        let count = row == 0 ? 3 : 2
        for k in 0..<count {
            let span = size.width / CGFloat(count) * 1.3
            var x = CGFloat(k) * span - drift.truncatingRemainder(dividingBy: span * CGFloat(count))
            if x < -span * 0.8 { x += span * CGFloat(count) }
            let y = size.height * (row == 0 ? 0.27 + 0.05 * CGFloat(k % 2) : 0.50 + 0.03 * CGFloat(k))
            let (shape, lines) = cloud(at: CGPoint(x: x, y: y), width: size.width * (row == 0 ? 0.22 : 0.3),
                                       seed: Double(k + row * 10))
            c.fill(shape, with: .color(fill.color.opacity(row == 0 ? 1 : 0.92)))
            c.stroke(shape, with: .color(inkColor), lineWidth: 1.5)
            c.stroke(lines, with: .color(inkColor.opacity(0.55)), lineWidth: 1)
        }
    }

    // MARK: Montañas

    private func drawRange(_ c: inout GraphicsContext, _ size: CGSize, parallax: Double, top: CGFloat, height: CGFloat,
                           seed: Double, color: RGB, index: Int) {
        func y(_ x: CGFloat) -> CGFloat {
            // Picos más marcados que en las siluetas: el ruido se eleva al cuadrado en las cimas.
            let n = ridgeHeight(x: x, camera: cam, parallax: parallax, seed: seed)
            return size.height * top - CGFloat(n > 0 ? n * (0.6 + n * 0.6) : n * 0.6) * size.height * height
        }
        var body = Path(), crest = Path()
        body.move(to: CGPoint(x: 0, y: size.height))
        var x: CGFloat = 0
        while x <= size.width + 5 {
            let p = CGPoint(x: x, y: y(x))
            body.addLine(to: p)
            if x == 0 { crest.move(to: p) } else { crest.addLine(to: p) }
            x += 5
        }
        body.addLine(to: CGPoint(x: size.width + 5, y: size.height))
        body.closeSubpath()
        c.fill(body, with: .color(color.color))

        // Bokashi: la cima más oscura, fundiéndose hacia abajo.
        var inside = c
        inside.clip(to: body)
        let peak = size.height * (top - height)
        inside.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(colors: [color.mix(ink, 0.5).color, color.color.opacity(0)]),
            startPoint: CGPoint(x: 0, y: peak), endPoint: CGPoint(x: 0, y: size.height * top + 10)))
        // Trazos de gubia: líneas paralelas a la cresta, cada vez más débiles.
        var hatch = Path()
        for k in 1...(index == 0 ? 6 : 4) {
            let off = CGFloat(k) * (index == 0 ? 7 : 6)
            var first = true
            var xx: CGFloat = 0
            while xx <= size.width + 8 {
                // Las líneas se cortan a trozos, como talladas a mano.
                let on = hash01(Double(Int(xx / 40)) * 3.7 + Double(k) * 11 + seed) > 0.3
                let p = CGPoint(x: xx, y: y(xx) + off)
                if on { if first { hatch.move(to: p); first = false } else { hatch.addLine(to: p) } } else { first = true }
                xx += 8
            }
        }
        inside.stroke(hatch, with: .color(inkColor.opacity(0.22 - Double(index) * 0.04)), lineWidth: 0.9)
        // Arboledas en la cresta de las colinas: puntos de tinta en grupos.
        if index > 0 {
            var dots = Path()
            var xx: CGFloat = 0
            let shift = CGFloat(cam.distance * Double(cam.pxPerM) * parallax)
            while xx < size.width {
                let k = Double(Int((xx + shift) / 22))
                if hash01(k + seed) > 0.45 {
                    let px = CGFloat(k) * 22 - shift + 11
                    let py = y(px) + 1
                    for m in 0..<3 {
                        let r: CGFloat = index == 1 ? 3.2 : 4
                        dots.addEllipse(in: CGRect(x: px + CGFloat(m - 1) * r * 1.4 - r, y: py - r * 1.6 - CGFloat(m % 2) * r, width: r * 2, height: r * 2))
                    }
                }
                xx += 22
            }
            c.fill(dots, with: .color(color.mix(ink, 0.55).color))
        }
        c.stroke(crest, with: .color(inkColor), style: StrokeStyle(lineWidth: index == 0 ? 1.8 : 2.2, lineJoin: .round))
    }

    /// Bruma en franjas (kasumi): bandas claras con borde de tinta fino.
    private func drawMist(_ c: inout GraphicsContext, y: CGFloat) {
        let size = cam.size
        let mist = paper.mix(RGB(1, 1, 1), 0.25).color.opacity(0.82 - 0.35 * palette.stars)
        let drift = CGFloat(cam.distance * Double(cam.pxPerM) * 0.09 + time * 3)
        for k in 0..<3 {
            let span = size.width * 0.8
            var x = CGFloat(k) * span * 0.95 - drift.truncatingRemainder(dividingBy: span * 2.85)
            if x < -span { x += span * 2.85 }
            let w = span * CGFloat(0.55 + hash01(Double(k) + 4) * 0.35)
            let band = Path(roundedRect: CGRect(x: x, y: y + CGFloat(k % 2) * 16, width: w, height: 13), cornerRadius: 6.5)
            c.fill(band, with: .color(mist))
            c.stroke(band, with: .color(inkColor.opacity(0.45)), lineWidth: 1)
        }
    }

    // MARK: Pinos y suelo

    /// Pino retorcido: tronco con dos curvas, ramas horizontales y copas de agujas festoneadas
    /// con trazos finos.
    private func drawPines(_ c: inout GraphicsContext) {
        let leaf = palette.ground.mix(RGB(0.16, 0.32, 0.22), 0.7 - 0.45 * palette.stars)
        let bark = palette.ground.mix(RGB(0.38, 0.25, 0.16), 0.7 - 0.45 * palette.stars)
        let every = 52.0
        var d = (cam.leftMeters / every).rounded(.down) * every - every
        while d < cam.rightMeters + every {
            let r = hash01(d)
            if r > 0.3 {
                let wd = d + r * 24
                let base = CGPoint(x: cam.screenX(wd), y: cam.groundY(wd) + 4)
                let h = CGFloat(70 + r * 60) * cam.size.height / 900
                let lean = CGFloat(r - 0.45) * h * 0.7
                let topPt = CGPoint(x: base.x + lean, y: base.y - h)
                var trunk = Path()
                trunk.move(to: base)
                trunk.addCurve(to: topPt, control1: CGPoint(x: base.x - lean * 0.8, y: base.y - h * 0.35),
                               control2: CGPoint(x: base.x + lean * 1.4, y: base.y - h * 0.7))
                c.stroke(trunk, with: .color(inkColor), style: StrokeStyle(lineWidth: h * 0.085 + 2.6, lineCap: .round))
                c.stroke(trunk, with: .color(bark.color), style: StrokeStyle(lineWidth: h * 0.085, lineCap: .round))
                let pads = r > 0.7 ? 4 : 3
                for k in 0..<pads {
                    let t = 1 - CGFloat(k) * 0.2
                    let side: CGFloat = k % 2 == 0 ? 1 : -1
                    let anchor = CGPoint(x: base.x + lean * t, y: base.y - h * t)
                    let reach = h * (0.32 - CGFloat(k) * 0.03) * side
                    let center = CGPoint(x: anchor.x + reach, y: anchor.y + h * 0.02)
                    var branch = Path()
                    branch.move(to: anchor)
                    branch.addQuadCurve(to: center, control: CGPoint(x: anchor.x + reach * 0.5, y: anchor.y - h * 0.06))
                    c.stroke(branch, with: .color(inkColor), lineWidth: 2.2)
                    // Copa de agujas: borde de arriba festoneado y base plana.
                    let w = h * (0.5 - CGFloat(k) * 0.05), hh = h * 0.13
                    var pad = Path()
                    pad.move(to: CGPoint(x: center.x - w / 2, y: center.y + hh / 2))
                    let lobes = 5
                    for m in 0..<lobes {
                        let x0 = center.x - w / 2 + w * CGFloat(m) / CGFloat(lobes)
                        let x1 = center.x - w / 2 + w * CGFloat(m + 1) / CGFloat(lobes)
                        pad.addQuadCurve(to: CGPoint(x: x1, y: center.y + hh / 2 - (m == lobes - 1 ? 0 : hh * 0.3)),
                                         control: CGPoint(x: (x0 + x1) / 2, y: center.y - hh * 0.9))
                    }
                    pad.addLine(to: CGPoint(x: center.x + w / 2, y: center.y + hh / 2))
                    pad.closeSubpath()
                    c.fill(pad, with: .color(leaf.color))
                    var needles = Path()
                    for m in 0..<9 {
                        let nx = center.x - w * 0.4 + w * 0.8 * CGFloat(m) / 8
                        needles.move(to: CGPoint(x: nx, y: center.y + hh * 0.35))
                        needles.addLine(to: CGPoint(x: nx + 2, y: center.y - hh * 0.15))
                    }
                    c.stroke(needles, with: .color(inkColor.opacity(0.45)), lineWidth: 0.8)
                    c.stroke(pad, with: .color(inkColor), lineWidth: 1.7)
                }
            }
            d += every
        }
    }

    private func drawGround(_ c: inout GraphicsContext, _ size: CGSize) {
        var ground = Path(), edge = Path(), roadLow = Path()
        ground.move(to: CGPoint(x: 0, y: size.height))
        var x: CGFloat = 0
        while x <= size.width + 4 {
            let p = CGPoint(x: x, y: cam.groundY(cam.world(x)))
            ground.addLine(to: p)
            if x == 0 { edge.move(to: p); roadLow.move(to: CGPoint(x: p.x, y: p.y + 7)) } else {
                edge.addLine(to: p); roadLow.addLine(to: CGPoint(x: p.x, y: p.y + 7))
            }
            x += 4
        }
        ground.addLine(to: CGPoint(x: size.width + 4, y: size.height))
        ground.closeSubpath()
        c.fill(ground, with: .color(palette.ground.color))
        c.fill(ground, with: .linearGradient(
            Gradient(colors: [palette.ground.color.opacity(0), palette.ground.mix(ink, 0.45).color]),
            startPoint: CGPoint(x: 0, y: cam.baseY), endPoint: CGPoint(x: 0, y: size.height)))
        // Camino claro entre dos líneas de tinta.
        c.stroke(edge, with: .color(paper.mix(palette.ground, 0.35).color), lineWidth: 12)
        c.stroke(edge, with: .color(inkColor), lineWidth: 2.2)
        c.stroke(roadLow, with: .color(inkColor.opacity(0.7)), lineWidth: 1.2)
        // Matas de hierba: abanicos de tres trazos.
        var tufts = Path()
        var d = (cam.leftMeters / 6).rounded(.down) * 6
        while d < cam.rightMeters {
            if hash01(d) > 0.5 {
                let px = cam.screenX(d), py = cam.groundY(d) + 16 + CGFloat(hash01(d + 1)) * 26
                for k in -1...1 {
                    tufts.move(to: CGPoint(x: px, y: py))
                    tufts.addQuadCurve(to: CGPoint(x: px + CGFloat(k) * 5, y: py - 9), control: CGPoint(x: px + CGFloat(k) * 1.5, y: py - 6))
                }
            }
            d += 6
        }
        c.stroke(tufts, with: .color(inkColor.opacity(0.4)), lineWidth: 1.1)
    }

    private func drawMarkers(_ c: inout GraphicsContext) {
        var d = max((cam.leftMeters / 1000).rounded(.up), 1) * 1000
        while d <= cam.rightMeters {
            let x = cam.screenX(d), y = cam.groundY(d)
            let post = Path(roundedRect: CGRect(x: x - 8, y: y - 48, width: 16, height: 48), cornerRadius: 4)
            c.fill(post, with: .color(paper.color))
            c.stroke(post, with: .color(inkColor), lineWidth: 1.8)
            let label = c.resolve(Text("\(Int(d / 1000))").font(.system(size: 15, weight: .bold, design: .serif)).foregroundStyle(inkColor))
            c.draw(label, at: CGPoint(x: x, y: y - 33))
            let km = c.resolve(Text("km").font(.system(size: 8, weight: .semibold, design: .serif)).foregroundStyle(inkColor))
            c.draw(km, at: CGPoint(x: x, y: y - 17))
            d += 1000
        }
    }

    // MARK: Ciclista, cartela y papel

    private func drawRider(_ c: inout GraphicsContext) {
        var g = c
        g.translateBy(x: cam.riderPoint.x, y: cam.riderPoint.y)
        g.rotate(by: .radians(cam.slope))
        g.scaleBy(x: cam.riderScale, y: cam.riderScale)
        if palette.stars > 0.3 {
            var beam = Path()
            beam.move(to: CGPoint(x: 31, y: -37))
            beam.addLine(to: CGPoint(x: 120, y: -10))
            beam.addLine(to: CGPoint(x: 120, y: 2))
            beam.closeSubpath()
            g.fill(beam, with: .linearGradient(Gradient(colors: [RGB(1, 0.95, 0.75).color.opacity(0.3 * palette.stars), .clear]),
                                               startPoint: CGPoint(x: 31, y: -37), endPoint: CGPoint(x: 120, y: 0)))
        }
        let parts = RiderModel.parts(crank: crank, distance: cam.distance)
        RiderModel.drawVector(&g, parts: parts, ink: inkColor, outline: 1.2, tint: { $0.mix(paper, 0.08).mix(palette.skyTop, palette.stars * 0.15) })
    }

    /// Cartela con el nombre de la ruta y sello rojo, como en las estampas.
    private func drawCartouche(_ c: inout GraphicsContext, _ size: CGSize) {
        let name = routeName.components(separatedBy: ",").first ?? routeName
        let title = c.resolve(Text(name).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(inkColor))
        let textSize = title.measure(in: CGSize(width: 400, height: 40))
        let box = CGRect(x: size.width * 0.04, y: size.height * 0.27, width: textSize.width + 26, height: textSize.height + 16)
        c.fill(Path(box), with: .color(paper.mix(RGB(1, 1, 1), 0.3).color))
        c.stroke(Path(box), with: .color(inkColor), lineWidth: 1.6)
        c.stroke(Path(box.insetBy(dx: 3, dy: 3)), with: .color(inkColor), lineWidth: 0.7)
        c.draw(title, at: CGPoint(x: box.midX, y: box.midY))
        let seal = CGRect(x: box.maxX + 8, y: box.minY + 2, width: 24, height: 24)
        c.fill(Path(roundedRect: seal, cornerRadius: 3), with: .color(RGB(0.75, 0.16, 0.12).color))
        let tz = c.resolve(Text("TZ").font(.system(size: 10, weight: .heavy, design: .serif)).foregroundStyle(paper.color))
        c.draw(tz, at: CGPoint(x: seal.midX, y: seal.midY))
    }

    /// Papel: fibras y motas fijas, y los bordes algo más oscuros.
    private func drawPaper(_ c: inout GraphicsContext, _ size: CGSize) {
        var fibers = Path(), specks = Path()
        for i in 0..<120 {
            let x = CGFloat(hash01(Double(i) * 1.7)) * size.width, y = CGFloat(hash01(Double(i) * 2.3 + 5)) * size.height
            let l = CGFloat(6 + hash01(Double(i)) * 14)
            fibers.move(to: CGPoint(x: x, y: y))
            fibers.addQuadCurve(to: CGPoint(x: x + l, y: y + CGFloat(hash01(Double(i) + 9) - 0.5) * 6),
                                control: CGPoint(x: x + l / 2, y: y - 3))
        }
        for i in 0..<300 {
            let x = CGFloat(hash01(Double(i) * 3.1 + 1)) * size.width, y = CGFloat(hash01(Double(i) * 1.3 + 7)) * size.height
            specks.addRect(CGRect(x: x, y: y, width: 1.5, height: 1.5))
        }
        c.stroke(fibers, with: .color(paper.mix(RGB(1, 1, 1), 0.4).color.opacity(0.18)), lineWidth: 0.8)
        c.fill(specks, with: .color(ink.color.opacity(0.07)))
        c.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(colors: [.clear, ink.color.opacity(0.22)]),
            center: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: size.width * 0.35, endRadius: size.width * 0.75))
    }
}
