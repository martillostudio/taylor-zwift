import CicloKit
import SwiftUI

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

// MARK: - Pixel art hecho por código

/// Plan B si no están instalados los fondos (App/Escenarios). Pixel art: todo en una rejilla de píxeles gordos, con paleta por bandas, árboles como sprites y
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
