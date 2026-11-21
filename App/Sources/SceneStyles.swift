import CicloKit
import SwiftUI

/// Estilos del simulador 2D. Se elige en el propio simulador y se recuerda.
enum SceneStyle: String, CaseIterable, Identifiable {
    case silhouette = "siluetas"
    case pixel
    case print = "grabado"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silhouette: "Siluetas"
        case .pixel: "Pixel art"
        case .print: "Grabado japonés"
        }
    }

    var systemImage: String {
        switch self {
        case .silhouette: "mountain.2"
        case .pixel: "square.grid.3x3.fill"
        case .print: "paintbrush.pointed"
        }
    }

    /// Fotogramas del cielo de cada estilo.
    var keys: ScenePalette.Keys {
        switch self {
        case .silhouette, .pixel: .silhouette
        case .print: .print
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
    let cadence: Double

    var pixel: CGFloat { max(3, (cam.size.height / 210).rounded()) }

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
        let parts = RiderModel.parts(time: time, cadence: cadence, distance: cam.distance)
        let origin = cam.riderPoint, angle = cam.slope, s = cam.riderScale
        let cosA = CGFloat(cos(-angle)), sinA = CGFloat(sin(-angle))
        let b = RiderModel.bounds
        let box = CGRect(x: origin.x + b.minX * s * 1.2, y: origin.y + b.minY * s * 1.15,
                         width: b.width * s * 1.25, height: b.height * s * 1.25)
        // Luz delantera de noche: un haz tramado por delante.
        if palette.stars > 0.3 {
            var beam = Path()
            let P = pixel
            let start = CGPoint(x: origin.x + 30 * s, y: origin.y - 38 * s)
            var k: CGFloat = 0
            while k < 46 {
                let x = start.x + k * P
                let spread = k * 0.45
                let yMid = start.y + k * P * 0.55 + CGFloat(tan(angle)) * k * P
                var j = -spread
                while j <= spread {
                    if (Int(k) + Int(j.rounded())) % 2 == 0 {
                        beam.addRect(CGRect(x: (x / P).rounded() * P, y: ((yMid + j * P) / P).rounded() * P, width: P, height: P))
                    }
                    j += 1
                }
                k += 1
            }
            c.fill(beam, with: .color(RGB(1, 0.95, 0.75).color.opacity(0.18 * palette.stars)))
        }
        RiderModel.drawPixels(&c, parts: parts, screenBox: box, pixel: pixel, toLocal: { p in
            let dx = (p.x - origin.x) / s, dy = (p.y - origin.y) / s
            return CGPoint(x: dx * cosA - dy * sinA, y: dx * sinA + dy * cosA)
        }, outline: Color(red: 0.06, green: 0.06, blue: 0.09), tint: { $0.mix(palette.skyTop, palette.stars * 0.18) })
    }
}

// MARK: - Grabado japonés

/// Inspirado en el grabado ukiyo-e: colores planos con contorno de tinta, degradados (bokashi)
/// en el cielo y en las cimas, bandas de bruma, papel con grano, pinos de copa plana y una luna
/// (o un sol) grande. El ciclista, en colores planos con contorno.
struct PrintRenderer {
    let cam: SceneCamera
    let palette: ScenePalette
    let time: Double
    let cadence: Double

    private let ink = RGB(0.10, 0.10, 0.15)

    func draw(in c: inout GraphicsContext) {
        let size = cam.size
        let inkColor = ink.color

        // Cielo de papel con la franja oscura arriba (bokashi).
        c.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(colors: [palette.skyTop.color, palette.skyBottom.color]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height * 0.65)))
        c.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.2)), with: .linearGradient(
            Gradient(colors: [palette.skyTop.mix(ink, 0.35).color, palette.skyTop.color.opacity(0)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.2)))

        // Estrellas discretas.
        if palette.stars > 0 {
            var stars = Path()
            for i in 0..<50 {
                let x = CGFloat(hash01(Double(i))) * size.width, y = CGFloat(hash01(Double(i) + 0.5)) * size.height * 0.45
                stars.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
            }
            c.fill(stars, with: .color(RGB(0.98, 0.95, 0.85).color.opacity(0.7 * palette.stars)))
        }

        // Luna o sol grande con contorno.
        let r = size.height * 0.085
        let center = CGPoint(x: size.width * palette.lightX, y: size.height * palette.lightY)
        let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        c.fill(disc, with: .color(palette.light.color))
        c.stroke(disc, with: .color(inkColor.opacity(0.7)), lineWidth: 1.5)

        // Sierras planas con contorno y bokashi en la cima.
        let layers: [(Double, CGFloat, CGFloat, Double)] = [(0.05, 0.42, 0.17, 1.3), (0.14, 0.52, 0.13, 3.3), (0.30, 0.61, 0.10, 5.9)]
        for (i, l) in layers.enumerated() {
            var top = Path()
            var ridge = Path()
            ridge.move(to: CGPoint(x: 0, y: size.height))
            var x: CGFloat = 0
            var first = true
            while x <= size.width + 6 {
                let y = size.height * l.1 - CGFloat(ridgeHeight(x: x, camera: cam, parallax: l.0, seed: l.3)) * size.height * l.2
                ridge.addLine(to: CGPoint(x: x, y: y))
                if first { top.move(to: CGPoint(x: x, y: y)); first = false } else { top.addLine(to: CGPoint(x: x, y: y)) }
                x += 6
            }
            ridge.addLine(to: CGPoint(x: size.width + 6, y: size.height))
            ridge.closeSubpath()
            let color = palette.ridges[i]
            c.fill(ridge, with: .color(color.color))
            var shaded = c
            shaded.clip(to: ridge)
            let peak = size.height * (l.1 - l.2)
            shaded.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [color.mix(ink, 0.45).color, color.color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: peak), endPoint: CGPoint(x: 0, y: peak + size.height * l.2 * 1.6)))
            c.stroke(top, with: .color(inkColor.opacity(0.8)), lineWidth: 1.6)
            // Bandas de bruma delante de las sierras lejanas.
            if i < 2 { drawMist(&c, y: size.height * (l.1 + 0.03), index: i) }
        }

        drawPines(&c)

        // Terreno plano con contorno y trazos de hierba.
        var ground = Path(), edge = Path()
        ground.move(to: CGPoint(x: 0, y: size.height))
        var x: CGFloat = 0
        while x <= size.width + 4 {
            let p = CGPoint(x: x, y: cam.groundY(cam.world(x)))
            ground.addLine(to: p)
            if x == 0 { edge.move(to: p) } else { edge.addLine(to: p) }
            x += 4
        }
        ground.addLine(to: CGPoint(x: size.width + 4, y: size.height))
        ground.closeSubpath()
        c.fill(ground, with: .color(palette.ground.color))
        c.fill(ground, with: .linearGradient(
            Gradient(colors: [palette.ground.mix(RGB(1, 1, 1), 0.12).color, palette.ground.mix(ink, 0.4).color]),
            startPoint: CGPoint(x: 0, y: cam.baseY - 40), endPoint: CGPoint(x: 0, y: size.height)))
        c.stroke(edge, with: .color(inkColor), lineWidth: 2.2)
        var tufts = Path()
        var d = (cam.leftMeters / 7).rounded(.down) * 7
        while d < cam.rightMeters {
            if hash01(d) > 0.45 {
                let px = cam.screenX(d), py = cam.groundY(d) + 7 + CGFloat(hash01(d + 1)) * 16
                tufts.move(to: CGPoint(x: px - 5, y: py + 3))
                tufts.addQuadCurve(to: CGPoint(x: px + 5, y: py + 3), control: CGPoint(x: px, y: py - 3))
            }
            d += 7
        }
        c.stroke(tufts, with: .color(inkColor.opacity(0.35)), lineWidth: 1.2)

        drawMarkers(&c)
        drawPaperGrain(&c)
        drawRider(&c)
    }

    private func drawMist(_ c: inout GraphicsContext, y: CGFloat, index: Int) {
        let size = cam.size
        let mist = RGB(0.97, 0.94, 0.86).mix(palette.skyBottom, 0.3).color.opacity(0.75 - 0.4 * palette.stars)
        let drift = CGFloat(cam.distance * Double(cam.pxPerM) * (0.08 + 0.06 * Double(index)) + time * 4)
        for k in 0..<4 {
            let span = size.width * 0.75
            var x = CGFloat(k) * span * 0.9 - drift.truncatingRemainder(dividingBy: span * 3.6)
            if x < -span { x += span * 3.6 }
            let w = span * CGFloat(0.5 + hash01(Double(k + index * 10)) * 0.4)
            let band = Path(roundedRect: CGRect(x: x, y: y + CGFloat(k % 2) * 14, width: w, height: 16), cornerRadius: 8)
            c.fill(band, with: .color(mist))
            c.stroke(band, with: .color(ink.color.opacity(0.35)), lineWidth: 1)
        }
    }

    /// Pinos de copa plana: tronco inclinado y tres o cuatro «nubes» de hojas con contorno.
    private func drawPines(_ c: inout GraphicsContext) {
        let leaf = palette.ground.mix(RGB(0.20, 0.36, 0.22), 0.6 - 0.45 * palette.stars)
        let trunk = palette.ground.mix(RGB(0.36, 0.24, 0.16), 0.6 - 0.4 * palette.stars)
        let every = 46.0
        var d = (cam.leftMeters / every).rounded(.down) * every - every
        while d < cam.rightMeters + every {
            let r = hash01(d)
            if r > 0.35 {
                let base = CGPoint(x: cam.screenX(d + r * 20), y: cam.groundY(d + r * 20) + 3)
                let h = CGFloat(55 + r * 45) * cam.size.height / 900
                let lean = CGFloat(r - 0.5) * h * 0.5
                let topPt = CGPoint(x: base.x + lean, y: base.y - h)
                var stem = Path()
                stem.move(to: base)
                stem.addQuadCurve(to: topPt, control: CGPoint(x: base.x - lean * 0.6, y: base.y - h * 0.5))
                c.stroke(stem, with: .color(ink.color), style: StrokeStyle(lineWidth: h * 0.09 + 2.4, lineCap: .round))
                c.stroke(stem, with: .color(trunk.color), style: StrokeStyle(lineWidth: h * 0.09, lineCap: .round))
                for k in 0..<(r > 0.7 ? 4 : 3) {
                    let t = 1 - CGFloat(k) * 0.24
                    let px = base.x + lean * t + CGFloat(hash01(d + Double(k)) - 0.5) * h * 0.5
                    let py = base.y - h * t
                    let w = h * (0.55 - CGFloat(k) * 0.07), hh = h * 0.16
                    let pad = Path(roundedRect: CGRect(x: px - w / 2, y: py - hh / 2, width: w, height: hh), cornerRadius: hh / 2)
                    c.fill(pad, with: .color(leaf.color))
                    c.stroke(pad, with: .color(ink.color), lineWidth: 1.6)
                }
            }
            d += every
        }
    }

    private func drawMarkers(_ c: inout GraphicsContext) {
        var d = max((cam.leftMeters / 1000).rounded(.up), 1) * 1000
        while d <= cam.rightMeters {
            let x = cam.screenX(d), y = cam.groundY(d)
            let post = Path(roundedRect: CGRect(x: x - 7, y: y - 44, width: 14, height: 44), cornerRadius: 3)
            c.fill(post, with: .color(RGB(0.90, 0.85, 0.74).mix(palette.ground, palette.stars * 0.4).color))
            c.stroke(post, with: .color(ink.color), lineWidth: 1.6)
            let label = c.resolve(Text("\(Int(d / 1000))").font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(ink.color))
            c.draw(label, at: CGPoint(x: x, y: y - 30))
            let km = c.resolve(Text("km").font(.system(size: 8, weight: .semibold, design: .serif)).foregroundStyle(ink.color))
            c.draw(km, at: CGPoint(x: x, y: y - 15))
            d += 1000
        }
    }

    /// Grano de papel: motas fijas muy suaves por toda la imagen.
    private func drawPaperGrain(_ c: inout GraphicsContext) {
        var light = Path(), dark = Path()
        for i in 0..<260 {
            let x = CGFloat(hash01(Double(i) * 1.7)) * cam.size.width, y = CGFloat(hash01(Double(i) * 2.3 + 5)) * cam.size.height
            let w = CGFloat(1 + hash01(Double(i)) * 3)
            if i % 2 == 0 { light.addRect(CGRect(x: x, y: y, width: w, height: 1)) } else { dark.addRect(CGRect(x: x, y: y, width: w, height: 1)) }
        }
        c.fill(light, with: .color(.white.opacity(0.06)))
        c.fill(dark, with: .color(.black.opacity(0.06)))
    }

    private func drawRider(_ c: inout GraphicsContext) {
        var g = c
        g.translateBy(x: cam.riderPoint.x, y: cam.riderPoint.y)
        g.rotate(by: .radians(cam.slope))
        g.scaleBy(x: cam.riderScale, y: cam.riderScale)
        if palette.stars > 0.3 {
            // Luz delantera: un cono suave.
            var beam = Path()
            beam.move(to: CGPoint(x: 30, y: -38))
            beam.addLine(to: CGPoint(x: 150, y: -6))
            beam.addLine(to: CGPoint(x: 150, y: 6))
            beam.closeSubpath()
            g.fill(beam, with: .linearGradient(Gradient(colors: [RGB(1, 0.95, 0.75).color.opacity(0.35 * palette.stars), .clear]),
                                               startPoint: CGPoint(x: 30, y: -38), endPoint: CGPoint(x: 150, y: 0)))
        }
        let parts = RiderModel.parts(time: time, cadence: cadence, distance: cam.distance)
        RiderModel.drawVector(&g, parts: parts, ink: ink.color, outline: 1.1,
                              tint: { $0.mix(palette.skyTop, palette.stars * 0.2) })
    }
}
