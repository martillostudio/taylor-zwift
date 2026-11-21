import CicloKit
import SwiftUI

/// «Línea clara»: cómic de ciencia ficción moderno, de trazo fino y colores planos con sombras
/// duras. Un mundo mediterráneo inventado: mar con islas, acantilados con pueblos blancos,
/// tejados rojos y cúpulas, antenas parabólicas y torres altas con carteles, pinos piñoneros,
/// postes con cables junto al camino y tierra clara con rayado. La sombra cae al lado contrario
/// del sol (o de la luna); de noche se encienden las ventanas.
struct ClearLineRenderer {
    let cam: SceneCamera
    let palette: ScenePalette
    let time: Double
    /// Ángulo de las bielas (radianes), acumulado con la cadencia suavizada.
    let crank: Double

    private let ink = RGB(0.10, 0.12, 0.16)
    private var inkColor: Color { ink.color }
    /// El sol (o la luna) a la izquierda: sombras a la derecha.
    private var shadowRight: Bool { palette.lightX < 0.5 }
    private func shade(_ c: RGB) -> RGB { c.mix(RGB(0.18, 0.24, 0.36), 0.38) }
    private var islands: RGB { palette.ridges[0] }
    private var sea: RGB { palette.ridges[1] }
    private var cliff: RGB { palette.ridges[2] }
    private var hills: RGB { palette.ridges[3] }
    private var scale: CGFloat { cam.size.height / 900 }

    func draw(in c: inout GraphicsContext) {
        let size = cam.size
        let seaY = size.height * 0.5
        drawSky(&c, size)
        drawClouds(&c, size)
        drawSea(&c, size, seaY: seaY)
        drawCoast(&c, size, seaY: seaY)
        drawHills(&c, size)
        drawGround(&c, size)
        drawPoles(&c, size)
        drawMarkers(&c)
        drawRider(&c)
    }

    // MARK: Cielo, nubes y mar

    private func drawSky(_ c: inout GraphicsContext, _ size: CGSize) {
        c.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(stops: [.init(color: palette.skyTop.color, location: 0), .init(color: palette.skyTop.color, location: 0.25),
                             .init(color: palette.skyBottom.color, location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.5)))
        if palette.stars > 0 {
            var stars = Path()
            for i in 0..<60 {
                let x = CGFloat(hash01(Double(i))) * size.width, y = CGFloat(hash01(Double(i) + 0.5)) * size.height * 0.42
                stars.addEllipse(in: CGRect(x: x, y: y, width: 1.8, height: 1.8))
            }
            c.fill(stars, with: .color(.white.opacity(0.75 * palette.stars)))
        }
        let r = size.height * 0.05
        let center = CGPoint(x: size.width * palette.lightX, y: size.height * palette.lightY)
        let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        c.fill(disc, with: .color(palette.light.color))
        c.stroke(disc, with: .color(inkColor.opacity(0.6)), lineWidth: 1.2)
    }

    /// Cúmulos: círculos unidos con un solo contorno y la parte de abajo en sombra.
    private func drawClouds(_ c: inout GraphicsContext, _ size: CGSize) {
        let light = RGB(0.99, 0.97, 0.92).mix(palette.skyBottom, 0.2).mix(palette.skyTop, 0.55 * palette.stars)
        let dark = shade(light).mix(palette.skyBottom, 0.2)
        let drift = CGFloat(cam.distance * Double(cam.pxPerM) * 0.04 + time * 2.5)
        for k in 0..<3 {
            let span = size.width * 0.55
            var x = CGFloat(k) * span - drift.truncatingRemainder(dividingBy: span * 3)
            if x < -span * 0.6 { x += span * 3 }
            let base = CGPoint(x: x, y: size.height * (0.36 + 0.06 * CGFloat(k % 2)))
            var puffs: [CGRect] = []
            let n = 6 + Int(hash01(Double(k)) * 3)
            let w = size.width * 0.2
            for m in 0..<n {
                let t = CGFloat(m) / CGFloat(n - 1)
                let r = w * (0.12 + 0.14 * CGFloat(sin(Double(t) * .pi))) * CGFloat(0.8 + hash01(Double(k * 10 + m)) * 0.4)
                let cx = base.x + t * w, cy = base.y - r * 0.6 - CGFloat(sin(Double(t) * .pi)) * w * 0.08
                puffs.append(CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
            var union = Path()
            for p in puffs { union.addEllipse(in: p) }
            union.addRect(CGRect(x: base.x, y: base.y - w * 0.08, width: w, height: w * 0.08))
            for p in puffs { c.stroke(Path(ellipseIn: p), with: .color(inkColor), lineWidth: 2.4) }
            c.stroke(Path(CGRect(x: base.x, y: base.y - w * 0.08, width: w, height: w * 0.08)), with: .color(inkColor), lineWidth: 2.4)
            c.fill(union, with: .color(light.color))
            var lower = c
            lower.clip(to: union)
            lower.fill(Path(CGRect(x: base.x - w, y: base.y - w * 0.12, width: w * 3, height: w)), with: .color(dark.color))
        }
    }

    private func drawSea(_ c: inout GraphicsContext, _ size: CGSize, seaY: CGFloat) {
        c.fill(Path(CGRect(x: 0, y: seaY, width: size.width, height: size.height - seaY)), with: .color(sea.color))
        var horizon = Path()
        horizon.move(to: CGPoint(x: 0, y: seaY))
        horizon.addLine(to: CGPoint(x: size.width, y: seaY))
        c.stroke(horizon, with: .color(inkColor.opacity(0.6)), lineWidth: 1)
        // Islas lejanas: planas, con contorno.
        let shift = CGFloat(cam.distance * Double(cam.pxPerM) * 0.02)
        for k in 0..<4 {
            let span = size.width * 0.6
            var x = CGFloat(k) * span * 0.8 - shift.truncatingRemainder(dividingBy: span * 3.2)
            if x < -span { x += span * 3.2 }
            let w = size.width * CGFloat(0.12 + hash01(Double(k) + 3) * 0.18), h = size.height * CGFloat(0.012 + hash01(Double(k)) * 0.02)
            var island = Path()
            island.move(to: CGPoint(x: x, y: seaY))
            island.addCurve(to: CGPoint(x: x + w, y: seaY), control1: CGPoint(x: x + w * 0.25, y: seaY - h * 2),
                            control2: CGPoint(x: x + w * 0.6, y: seaY - h * 1.4))
            island.closeSubpath()
            c.fill(island, with: .color(islands.color))
            c.stroke(island, with: .color(inkColor.opacity(0.7)), lineWidth: 1)
        }
        // Brillos en el agua (de día) o el reflejo de la luna (de noche).
        var glints = Path()
        if palette.stars > 0.5 {
            let mx = size.width * palette.lightX
            for k in 0..<12 {
                let y = seaY + 6 + CGFloat(k) * 7
                let w = CGFloat(30 - k * 2) * CGFloat(0.6 + hash01(Double(k) + floor(time * 2)) * 0.6)
                glints.move(to: CGPoint(x: mx - w / 2, y: y))
                glints.addLine(to: CGPoint(x: mx + w / 2, y: y))
            }
            c.stroke(glints, with: .color(palette.light.color.opacity(0.6)), lineWidth: 1.5)
        } else {
            for k in 0..<26 {
                let x = CGFloat(hash01(Double(k) * 2.1 + floor(time / 3))) * size.width
                let y = seaY + 5 + CGFloat(hash01(Double(k) + 7)) * size.height * 0.12
                glints.move(to: CGPoint(x: x, y: y))
                glints.addLine(to: CGPoint(x: x + 10, y: y))
            }
            c.stroke(glints, with: .color(.white.opacity(0.5)), lineWidth: 1.2)
        }
    }

    // MARK: Costa: acantilados, pueblo y torres

    private func cliffTop(_ u: CGFloat, _ size: CGSize) -> CGFloat {
        let v = Double(u)
        return size.height * (0.5 - 0.035 - 0.05 * CGFloat(0.5 + 0.5 * sin(v / 330 + 1)) - 0.02 * CGFloat(sin(v / 97 + 2)))
    }

    private func drawCoast(_ c: inout GraphicsContext, _ size: CGSize, seaY: CGFloat) {
        let parallax = 0.16
        let shift = CGFloat(cam.distance * Double(cam.pxPerM) * parallax)
        let base = size.height * 0.62
        // Acantilado.
        var rock = Path(), top = Path(), hatch = Path()
        rock.move(to: CGPoint(x: 0, y: base))
        var x: CGFloat = 0
        while x <= size.width + 6 {
            let y = cliffTop(x + shift, size)
            rock.addLine(to: CGPoint(x: x, y: y))
            if x == 0 { top.move(to: CGPoint(x: x, y: y)) } else { top.addLine(to: CGPoint(x: x, y: y)) }
            // Rayado vertical en la cara en sombra.
            let next = cliffTop(x + 6 + shift, size)
            let inShadow = shadowRight ? next > y : next < y
            if inShadow || hash01(Double(Int((x + shift) / 6))) > 0.8 {
                hatch.move(to: CGPoint(x: x, y: y + 6))
                hatch.addLine(to: CGPoint(x: x, y: y + (base - y) * CGFloat(0.4 + hash01(Double(Int((x + shift) / 6)) + 3) * 0.5)))
            }
            x += 6
        }
        rock.addLine(to: CGPoint(x: size.width + 6, y: base))
        rock.closeSubpath()
        c.fill(rock, with: .color(cliff.color))
        c.stroke(hatch, with: .color(inkColor.opacity(0.28)), lineWidth: 0.9)

        // Pueblo en lo alto: bloques fijos en el espacio de esta capa.
        let block: CGFloat = 30 * max(scale, 0.8)
        var i = Int(((-shift) / block).rounded(.down)) - 2
        let last = Int(((size.width + shift) / block).rounded(.up)) + 1
        i = Int((shift / block).rounded(.down)) - 2
        while i <= last + Int(shift / block) {
            let u = CGFloat(i) * block
            let sx = u - shift
            if sx > -120, sx < size.width + 60 {
                let r = hash01(Double(i) * 1.3)
                let groundY = cliffTop(u + block / 2, size) + 3
                if r > 0.93 { drawTower(&c, x: sx, groundY: groundY, seed: Double(i)) }
                else if r > 0.12 { drawHouse(&c, x: sx, width: block * CGFloat(0.75 + hash01(Double(i) + 2) * 0.5), groundY: groundY, seed: Double(i)) }
            }
            i += 1
        }
        c.stroke(top, with: .color(inkColor), lineWidth: 1.4)
    }

    private func drawHouse(_ c: inout GraphicsContext, x: CGFloat, width w: CGFloat, groundY: CGFloat, seed: Double) {
        let wall = RGB(0.96, 0.93, 0.86).mix(cliff, 0.25)
        let roofRed = RGB(0.86, 0.40, 0.30)
        let h = CGFloat(16 + hash01(seed + 5) * 26) * max(scale, 0.8)
        let body = CGRect(x: x, y: groundY - h, width: w, height: h)
        c.fill(Path(body), with: .color(wall.color))
        // Cara en sombra.
        let sw = w * 0.3
        c.fill(Path(CGRect(x: shadowRight ? body.maxX - sw : body.minX, y: body.minY, width: sw, height: h)), with: .color(shade(wall).color))
        // Ventanas (de noche, algunas encendidas).
        var dark = Path(), lit = Path()
        let cols = max(Int(w / 9), 1), rows = max(Int(h / 11), 1)
        for row in 0..<rows {
            for col in 0..<cols where hash01(seed * 7 + Double(row * 5 + col)) > 0.35 {
                let rect = CGRect(x: body.minX + 4 + CGFloat(col) * 9, y: body.minY + 5 + CGFloat(row) * 11, width: 3.5, height: 5)
                if palette.stars > 0.3, hash01(seed + Double(row * 3 + col) + 0.5) > 0.55 { lit.addRect(rect) } else { dark.addRect(rect) }
            }
        }
        c.fill(dark, with: .color(inkColor.opacity(0.75)))
        c.fill(lit, with: .color(RGB(1, 0.82, 0.45).color.opacity(0.5 + 0.5 * palette.stars)))
        c.stroke(Path(body), with: .color(inkColor), lineWidth: 1.1)
        // Tejado: rojo a dos aguas, cúpula o terraza con antena.
        let kind = hash01(seed + 9)
        if kind < 0.45 {
            var roof = Path()
            roof.move(to: CGPoint(x: body.minX - 2, y: body.minY))
            roof.addLine(to: CGPoint(x: body.minX + w * 0.2, y: body.minY - h * 0.28))
            roof.addLine(to: CGPoint(x: body.maxX - w * 0.2, y: body.minY - h * 0.28))
            roof.addLine(to: CGPoint(x: body.maxX + 2, y: body.minY))
            roof.closeSubpath()
            c.fill(roof, with: .color(roofRed.color))
            c.stroke(roof, with: .color(inkColor), lineWidth: 1.1)
        } else if kind < 0.6 {
            let d = w * 0.6
            let dome = Path { p in
                p.addArc(center: CGPoint(x: body.midX, y: body.minY), radius: d / 2, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                p.closeSubpath()
            }
            c.fill(dome, with: .color(roofRed.mix(RGB(1, 1, 1), 0.15).color))
            c.stroke(dome, with: .color(inkColor), lineWidth: 1.1)
            var spire = Path()
            spire.move(to: CGPoint(x: body.midX, y: body.minY - d / 2))
            spire.addLine(to: CGPoint(x: body.midX, y: body.minY - d / 2 - 7))
            c.stroke(spire, with: .color(inkColor), lineWidth: 1.2)
        } else {
            var parapet = Path()
            parapet.addRect(CGRect(x: body.minX - 1, y: body.minY - 2.5, width: w + 2, height: 2.5))
            c.fill(parapet, with: .color(wall.color))
            c.stroke(parapet, with: .color(inkColor), lineWidth: 1)
            if kind > 0.8 { drawDish(&c, at: CGPoint(x: body.minX + w * 0.65, y: body.minY - 2), size: 9, seed: seed) }
            else if kind > 0.7 {
                var antenna = Path()
                antenna.move(to: CGPoint(x: body.minX + w * 0.3, y: body.minY))
                antenna.addLine(to: CGPoint(x: body.minX + w * 0.3, y: body.minY - 16))
                antenna.move(to: CGPoint(x: body.minX + w * 0.3 - 5, y: body.minY - 12))
                antenna.addLine(to: CGPoint(x: body.minX + w * 0.3 + 5, y: body.minY - 12))
                c.stroke(antenna, with: .color(inkColor), lineWidth: 1)
            }
        }
    }

    /// Antena parabólica inclinada.
    private func drawDish(_ c: inout GraphicsContext, at p: CGPoint, size s: CGFloat, seed: Double) {
        var g = c
        g.translateBy(x: p.x, y: p.y - s * 0.7)
        g.rotate(by: .degrees(-35 + hash01(seed) * 20))
        let dish = Path(ellipseIn: CGRect(x: -s * 0.35, y: -s, width: s * 0.7, height: s * 2))
        g.fill(dish, with: .color(RGB(0.95, 0.94, 0.90).color))
        g.stroke(dish, with: .color(inkColor), lineWidth: 1)
        var stick = Path()
        stick.move(to: CGPoint(x: 0, y: 0))
        stick.addLine(to: CGPoint(x: s * 0.9, y: 0))
        g.stroke(stick, with: .color(inkColor), lineWidth: 1)
        var mast = Path()
        mast.move(to: p)
        mast.addLine(to: CGPoint(x: p.x, y: p.y - s * 0.7))
        c.stroke(mast, with: .color(inkColor), lineWidth: 1.2)
    }

    /// Torre alta con cartel rojo de signos inventados y antenas arriba.
    private func drawTower(_ c: inout GraphicsContext, x: CGFloat, groundY: CGFloat, seed: Double) {
        let wall = RGB(0.95, 0.91, 0.82).mix(cliff, 0.15)
        let w = CGFloat(30 + hash01(seed + 1) * 18) * max(scale, 0.8)
        let h = cam.size.height * CGFloat(0.2 + hash01(seed + 2) * 0.14)
        let body = CGRect(x: x, y: groundY - h, width: w, height: h)
        c.fill(Path(body), with: .color(wall.color))
        let sw = w * 0.32
        c.fill(Path(CGRect(x: shadowRight ? body.maxX - sw : body.minX, y: body.minY, width: sw, height: h)), with: .color(shade(wall).color))
        // Bandas y ventanas en hilera.
        var bands = Path()
        var y = body.minY + 14
        while y < body.maxY - 6 {
            bands.move(to: CGPoint(x: body.minX, y: y))
            bands.addLine(to: CGPoint(x: body.maxX, y: y))
            y += 22
        }
        c.stroke(bands, with: .color(inkColor.opacity(0.35)), lineWidth: 0.8)
        // Cartel.
        let panel = CGRect(x: body.minX + w * 0.18, y: body.minY + h * 0.18, width: w * 0.5, height: h * 0.32)
        c.fill(Path(panel), with: .color(RGB(0.84, 0.28, 0.22).color))
        var glyphs = Path()
        var gy = panel.minY + 5
        var k = 0
        while gy < panel.maxY - 8 {
            let gw = panel.width - 8
            let a = hash01(seed * 3 + Double(k))
            glyphs.addRect(CGRect(x: panel.minX + 4, y: gy, width: gw * CGFloat(0.4 + a * 0.6), height: 2.5))
            glyphs.addRect(CGRect(x: panel.minX + 4 + gw * CGFloat(a * 0.5), y: gy, width: 2.5, height: 9))
            gy += 14
            k += 1
        }
        c.fill(glyphs, with: .color(RGB(0.98, 0.94, 0.86).color))
        c.stroke(Path(panel), with: .color(inkColor), lineWidth: 1)
        c.stroke(Path(body), with: .color(inkColor), lineWidth: 1.3)
        // Remate: cornisa, antenas y parabólicas.
        let cap = CGRect(x: body.minX - 3, y: body.minY - 5, width: w + 6, height: 5)
        c.fill(Path(cap), with: .color(wall.color))
        c.stroke(Path(cap), with: .color(inkColor), lineWidth: 1)
        drawDish(&c, at: CGPoint(x: body.minX + w * 0.25, y: body.minY - 5), size: 11, seed: seed + 1)
        drawDish(&c, at: CGPoint(x: body.minX + w * 0.8, y: body.minY - 5), size: 8, seed: seed + 2)
        var mast = Path()
        mast.move(to: CGPoint(x: body.midX, y: body.minY - 5))
        mast.addLine(to: CGPoint(x: body.midX, y: body.minY - 32))
        c.stroke(mast, with: .color(inkColor), lineWidth: 1.3)
    }

    // MARK: Colinas, suelo y postes

    private func hillTop(_ u: CGFloat, _ size: CGSize) -> CGFloat {
        let v = Double(u)
        return size.height * (0.635 - 0.025 * CGFloat(0.5 + 0.5 * sin(v / 190 + 2)) - 0.012 * CGFloat(sin(v / 61)))
    }

    private func drawHills(_ c: inout GraphicsContext, _ size: CGSize) {
        let shift = CGFloat(cam.distance * Double(cam.pxPerM) * 0.42)
        var hill = Path(), edge = Path()
        hill.move(to: CGPoint(x: 0, y: size.height))
        var x: CGFloat = 0
        while x <= size.width + 6 {
            let p = CGPoint(x: x, y: hillTop(x + shift, size))
            hill.addLine(to: p)
            if x == 0 { edge.move(to: p) } else { edge.addLine(to: p) }
            x += 6
        }
        hill.addLine(to: CGPoint(x: size.width + 6, y: size.height))
        hill.closeSubpath()
        c.fill(hill, with: .color(hills.color))
        // Pinos piñoneros: copa plana, con su sombra.
        let every: CGFloat = 64
        var k = Int((shift / every).rounded(.down)) - 1
        while CGFloat(k) * every - shift < size.width + every {
            let r = hash01(Double(k) * 2.7)
            if r > 0.35 {
                let px = CGFloat(k) * every - shift + every * CGFloat(r)
                let py = hillTop(px + shift, size) + 2
                let h = CGFloat(26 + r * 16) * max(scale, 0.8), w = h * 1.5
                var trunk = Path()
                trunk.move(to: CGPoint(x: px, y: py))
                trunk.addQuadCurve(to: CGPoint(x: px + w * 0.08, y: py - h), control: CGPoint(x: px - w * 0.1, y: py - h * 0.5))
                c.stroke(trunk, with: .color(inkColor), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                let canopy = CGRect(x: px + w * 0.08 - w / 2, y: py - h - h * 0.32, width: w, height: h * 0.4)
                let leaf = RGB(0.30, 0.44, 0.26).mix(hills, 0.35)
                c.fill(Path(ellipseIn: canopy), with: .color(leaf.color))
                var under = c
                under.clip(to: Path(ellipseIn: canopy))
                under.fill(Path(CGRect(x: canopy.minX, y: canopy.midY + 1, width: canopy.width, height: canopy.height)), with: .color(shade(leaf).color))
                c.stroke(Path(ellipseIn: canopy), with: .color(inkColor), lineWidth: 1.2)
            }
            k += 1
        }
        c.stroke(edge, with: .color(inkColor), lineWidth: 1.3)
    }

    private func drawGround(_ c: inout GraphicsContext, _ size: CGSize) {
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
        // Rayado horizontal (tierra seca), a trozos, siguiendo el terreno.
        var hatch = Path()
        for k in 1...5 {
            let off = CGFloat(k * k) * 6 + 10
            var on = false
            var xx: CGFloat = 0
            while xx <= size.width + 6 {
                let seg = hash01(Double(Int((cam.world(xx)) / 9)) * 1.9 + Double(k) * 5) > 0.45
                let p = CGPoint(x: xx, y: cam.groundY(cam.world(xx)) + off)
                if seg { if on { hatch.addLine(to: p) } else { hatch.move(to: p); on = true } } else { on = false }
                xx += 6
            }
        }
        c.stroke(hatch, with: .color(inkColor.opacity(0.22)), lineWidth: 0.9)
        // Matas secas.
        var tufts = Path()
        var d = (cam.leftMeters / 5).rounded(.down) * 5
        while d < cam.rightMeters {
            if hash01(d * 1.3) > 0.62 {
                let px = cam.screenX(d), py = cam.groundY(d) + 3 + CGFloat(hash01(d + 2)) * 4
                for k in -2...2 {
                    tufts.move(to: CGPoint(x: px, y: py))
                    tufts.addLine(to: CGPoint(x: px + CGFloat(k) * 2.2, y: py - 7 + abs(CGFloat(k))))
                }
            }
            d += 5
        }
        c.stroke(tufts, with: .color(inkColor.opacity(0.6)), lineWidth: 0.9)
        c.stroke(edge, with: .color(inkColor), lineWidth: 1.6)
    }

    /// Postes de madera con dos cables que cuelgan entre ellos, junto al camino.
    private func drawPoles(_ c: inout GraphicsContext, _ size: CGSize) {
        let every = 55.0
        var tops: [CGPoint] = []
        var d = (cam.leftMeters / every).rounded(.down) * every - every
        var poles = Path()
        while d < cam.rightMeters + every * 2 {
            let x = cam.screenX(d), y = cam.groundY(d) + 2
            let h = size.height * 0.15
            poles.move(to: CGPoint(x: x, y: y))
            poles.addLine(to: CGPoint(x: x, y: y - h))
            poles.move(to: CGPoint(x: x - 9, y: y - h + 6))
            poles.addLine(to: CGPoint(x: x + 9, y: y - h + 6))
            tops.append(CGPoint(x: x, y: y - h + 6))
            d += every
        }
        var cables = Path()
        for (a, b) in zip(tops, tops.dropFirst()) {
            for side: CGFloat in [-8, 8] {
                let p0 = CGPoint(x: a.x + side, y: a.y), p1 = CGPoint(x: b.x + side, y: b.y)
                cables.move(to: p0)
                cables.addQuadCurve(to: p1, control: CGPoint(x: (p0.x + p1.x) / 2, y: max(p0.y, p1.y) + 26))
            }
        }
        c.stroke(cables, with: .color(inkColor.opacity(0.75)), lineWidth: 0.9)
        c.stroke(poles, with: .color(inkColor), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        // Sombra de cada poste en el suelo.
        var shadows = Path()
        for t in tops {
            let y = t.y + size.height * 0.15 - 4
            shadows.move(to: CGPoint(x: t.x, y: y))
            shadows.addLine(to: CGPoint(x: t.x + (shadowRight ? 34 : -34), y: y + 3))
        }
        c.stroke(shadows, with: .color(shade(palette.ground).color.opacity(0.6)), lineWidth: 2.4)
    }

    private func drawMarkers(_ c: inout GraphicsContext) {
        var d = max((cam.leftMeters / 1000).rounded(.up), 1) * 1000
        while d <= cam.rightMeters {
            let x = cam.screenX(d), y = cam.groundY(d)
            var post = Path()
            post.move(to: CGPoint(x: x, y: y))
            post.addLine(to: CGPoint(x: x, y: y - 30))
            c.stroke(post, with: .color(inkColor), lineWidth: 2)
            let sign = CGRect(x: x - 20, y: y - 50, width: 40, height: 20)
            c.fill(Path(sign), with: .color(RGB(0.84, 0.28, 0.22).color))
            c.stroke(Path(sign), with: .color(inkColor), lineWidth: 1.2)
            let label = c.resolve(Text("\(Int(d / 1000)) km").font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(RGB(0.98, 0.94, 0.86).color))
            c.draw(label, at: CGPoint(x: sign.midX, y: sign.midY))
            d += 1000
        }
    }

    private func drawRider(_ c: inout GraphicsContext) {
        // Sombra dura en el suelo, hacia el lado contrario del sol.
        let p = cam.riderPoint, s = cam.riderScale
        var g0 = c
        g0.translateBy(x: p.x, y: p.y + 1)
        g0.rotate(by: .radians(cam.slope))
        let shadow = Path(ellipseIn: CGRect(x: (shadowRight ? -28 : -62) * s, y: -3 * s, width: 90 * s, height: 7 * s))
        g0.fill(shadow, with: .color(shade(palette.ground).color.opacity(0.7)))

        var g = c
        g.translateBy(x: p.x, y: p.y)
        g.rotate(by: .radians(cam.slope))
        g.scaleBy(x: s, y: s)
        if palette.stars > 0.3 {
            var beam = Path()
            beam.move(to: CGPoint(x: 31, y: -37))
            beam.addLine(to: CGPoint(x: 120, y: -10))
            beam.addLine(to: CGPoint(x: 120, y: 2))
            beam.closeSubpath()
            g.fill(beam, with: .linearGradient(Gradient(colors: [RGB(1, 0.95, 0.75).color.opacity(0.32 * palette.stars), .clear]),
                                               startPoint: CGPoint(x: 31, y: -37), endPoint: CGPoint(x: 120, y: 0)))
        }
        let parts = RiderModel.parts(crank: crank, distance: cam.distance)
        RiderModel.drawVector(&g, parts: parts, ink: inkColor, outline: 0.9, tint: { $0.mix(palette.skyTop, palette.stars * 0.15) })
    }
}

extension ScenePalette.Keys {
    /// Línea clara: azul verdoso de cómic de día, salmón al atardecer y azul petróleo de noche.
    /// `ridges` = islas, mar, acantilados, colinas.
    static let clearLine = ScenePalette.Keys(
        night: ScenePalette(skyTop: RGB(0.04, 0.11, 0.18), skyBottom: RGB(0.10, 0.22, 0.30), light: RGB(0.96, 0.95, 0.86),
                            ridges: [RGB(0.14, 0.24, 0.30), RGB(0.07, 0.17, 0.24), RGB(0.32, 0.36, 0.40), RGB(0.12, 0.18, 0.18)],
                            ground: RGB(0.26, 0.27, 0.28)),
        blueHour: ScenePalette(skyTop: RGB(0.10, 0.20, 0.36), skyBottom: RGB(0.34, 0.46, 0.58), light: RGB(0.96, 0.95, 0.86),
                               ridges: [RGB(0.28, 0.38, 0.46), RGB(0.16, 0.30, 0.40), RGB(0.52, 0.55, 0.58), RGB(0.22, 0.30, 0.27)],
                               ground: RGB(0.44, 0.43, 0.42)),
        dawn: ScenePalette(skyTop: RGB(0.38, 0.48, 0.70), skyBottom: RGB(0.98, 0.80, 0.68), light: RGB(1.0, 0.88, 0.70),
                           ridges: [RGB(0.70, 0.64, 0.70), RGB(0.45, 0.52, 0.68), RGB(0.94, 0.82, 0.74), RGB(0.50, 0.53, 0.44)],
                           ground: RGB(0.88, 0.75, 0.62)),
        dusk: ScenePalette(skyTop: RGB(0.30, 0.36, 0.58), skyBottom: RGB(0.98, 0.66, 0.52), light: RGB(1.0, 0.72, 0.50),
                           ridges: [RGB(0.62, 0.52, 0.60), RGB(0.40, 0.42, 0.60), RGB(0.92, 0.70, 0.62), RGB(0.46, 0.43, 0.40)],
                           ground: RGB(0.86, 0.64, 0.53)),
        golden: ScenePalette(skyTop: RGB(0.33, 0.52, 0.70), skyBottom: RGB(0.95, 0.82, 0.66), light: RGB(1.0, 0.90, 0.68),
                             ridges: [RGB(0.66, 0.68, 0.68), RGB(0.36, 0.56, 0.66), RGB(0.95, 0.83, 0.68), RGB(0.55, 0.57, 0.38)],
                             ground: RGB(0.92, 0.78, 0.59)),
        day: ScenePalette(skyTop: RGB(0.29, 0.56, 0.72), skyBottom: RGB(0.64, 0.80, 0.86), light: RGB(1.0, 0.97, 0.88),
                          ridges: [RGB(0.58, 0.72, 0.73), RGB(0.28, 0.58, 0.70), RGB(0.91, 0.87, 0.77), RGB(0.52, 0.62, 0.41)],
                          ground: RGB(0.90, 0.81, 0.65)),
        moon: RGB(0.96, 0.95, 0.86))
}
