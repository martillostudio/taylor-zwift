import SwiftUI

/// El ciclista y su bici (la Grizl) como lista de formas de color, en coordenadas locales:
/// origen en el suelo bajo el eje del pedalier, x hacia delante, y hacia abajo, 1 m ≈ 48 px.
/// El pixel art lo rasteriza (con contorno de 1 píxel).
struct RiderModel {
    enum Shape {
        /// Segmento con extremos redondos (miembros, tubos).
        case capsule(CGPoint, CGPoint, CGFloat)
        case disc(CGPoint, CGFloat)
        /// Aro: radio y grosor (cubiertas, llantas).
        case ring(CGPoint, CGFloat, CGFloat)
    }

    struct Part {
        var shape: Shape
        var color: RGB
        /// Los radios y detalles finos no llevan contorno.
        var outlined = true
    }

    /// Equipación y bici. La Grizl CF: cuadro color arena, tija, sillín y cinta negros, cubiertas
    /// anchas de gravel. Equipación como en tu foto: maillot claro de manga corta, culotte negro,
    /// calcetines blancos altos, zapatillas blancas, casco negro y gafas oscuras.
    struct Kit {
        var jersey = RGB(0.92, 0.92, 0.91)
        var jerseyDark = RGB(0.70, 0.72, 0.76)
        var shorts = RGB(0.10, 0.10, 0.12)
        var skin = RGB(0.86, 0.66, 0.52)
        var skinDark = RGB(0.70, 0.50, 0.38)
        var helmet = RGB(0.11, 0.11, 0.13)
        var socks = RGB(0.96, 0.96, 0.94)
        var shoes = RGB(0.95, 0.95, 0.94)
        var soles = RGB(0.12, 0.12, 0.14)
        var frame = RGB(0.80, 0.77, 0.69)
        var frameShade = RGB(0.64, 0.61, 0.54)
        var black = RGB(0.10, 0.10, 0.11)
        var tyre = RGB(0.13, 0.12, 0.12)
        var tyreWall = RGB(0.22, 0.21, 0.20)
        var metal = RGB(0.55, 0.56, 0.58)
        var glasses = RGB(0.08, 0.09, 0.12)
    }

    static func parts(crank crankAngle: Double, distance: Double, kit k: Kit = Kit()) -> [Part] {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        var parts: [Part] = []
        func cap(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat, _ c: RGB, outline: Bool = true) {
            parts.append(Part(shape: .capsule(a, b, w / 2), color: c, outlined: outline))
        }

        // Grizl (talla M): ruedas 700×45, batalla 1,03 m, tirantes bajos, tubo superior inclinado.
        let tyreR: CGFloat = 17, rimR: CGFloat = 14.2
        let rear = pt(-20.6, -tyreR), front = pt(28.8, -tyreR), bb = pt(0, -13.4)
        let seatCluster = pt(-6.8, -36.4), stayJoint = pt(-5.6, -31.5)
        let headTop = pt(19.2, -41.7), headBottom = pt(21.5, -33.6)
        let saddle = pt(-10.3, -47.2), stemEnd = pt(25.5, -43.6)
        let crank: CGFloat = 8.3
        func pedal(_ side: Double) -> CGPoint {
            pt(bb.x + CGFloat(cos(crankAngle + side)) * crank, bb.y + CGFloat(sin(crankAngle + side)) * crank)
        }

        // Ciclista de 1,75 m en postura de gravel (algo más erguido que en carretera).
        let hip = pt(-11.5, -48)
        let shoulder = pt(-11.5 + 19.2, -48 - 16.6)
        let hands = pt(27, -42.8)
        let head = pt(shoulder.x + 7, shoulder.y - 6)

        // 1. Lado de lejos: brazo y pierna, en tonos más oscuros.
        let farHip = pt(hip.x + 1, hip.y + 0.5)
        let farPedal = pedal(.pi)
        let farKnee = SceneIK.joint(from: farHip, to: farPedal, a: 20.6, b: 21.8, bendForward: true)
        let farAnkle = pt(farPedal.x - 1.2, farPedal.y - 3.2)
        cap(farHip, farKnee, 8.6, k.shorts.mix(RGB(0, 0, 0), 0.3))
        let farSock = pt(farKnee.x + (farAnkle.x - farKnee.x) * 0.55, farKnee.y + (farAnkle.y - farKnee.y) * 0.55)
        cap(farKnee, farSock, 6, k.skinDark)
        cap(farSock, pt(farAnkle.x, farAnkle.y + 1.2), 5.2, k.socks.mix(RGB(0, 0, 0), 0.22))
        cap(pt(farPedal.x - 2.5, farPedal.y - 0.5), pt(farPedal.x + 3.5, farPedal.y + 0.3), 3.6, k.shoes.mix(RGB(0, 0, 0), 0.22))
        cap(pt(farPedal.x - 2.5, farPedal.y + 1.2), pt(farPedal.x + 3.5, farPedal.y + 1.6), 1.2, k.soles, outline: false)
        let farShoulder = pt(shoulder.x - 1.5, shoulder.y + 1.5)
        let farHands = pt(hands.x - 1, hands.y + 0.5)
        let farElbow = SceneIK.joint(from: farShoulder, to: farHands, a: 14.4, b: 13.4, bendForward: false)
        cap(farShoulder, farElbow, 5.2, k.skinDark)
        cap(farElbow, farHands, 4.4, k.skinDark)

        // 2. Ruedas: cubierta con flanco claro, llanta y radios que giran.
        let turn = distance / 2.2 * 2 * .pi
        for w in [rear, front] {
            parts.append(Part(shape: .ring(w, tyreR - 1.6, 3.4), color: k.tyre))
            parts.append(Part(shape: .ring(w, rimR + 0.6, 1.0), color: k.tyreWall, outlined: false))
            parts.append(Part(shape: .ring(w, rimR - 0.8, 1.8), color: k.black, outlined: false))
            for s in 0..<6 {
                let a = turn + Double(s) * .pi / 6
                let dx = CGFloat(cos(a)) * (rimR - 1.5), dy = CGFloat(sin(a)) * (rimR - 1.5)
                cap(pt(w.x - dx, w.y - dy), pt(w.x + dx, w.y + dy), 0.5, k.metal, outline: false)
            }
            parts.append(Part(shape: .disc(w, 2.2), color: k.black, outlined: false))
        }
        // Disco de freno delantero.
        parts.append(Part(shape: .ring(front, 6.2, 1.2), color: k.metal, outlined: false))

        // 3. Cuadro, horquilla, tija, sillín, potencia y manillar.
        cap(rear, bb, 2.6, k.frameShade)
        cap(rear, stayJoint, 2.2, k.frameShade)
        cap(bb, seatCluster, 3.4, k.frame)
        cap(bb, headBottom, 4.2, k.frame)
        cap(seatCluster, headTop, 3.2, k.frame)
        cap(headBottom, headTop, 4.2, k.frame)
        cap(headBottom, front, 3.0, k.frame)
        cap(seatCluster, pt(saddle.x + 1.6, saddle.y + 1.4), 2.2, k.black)
        cap(pt(saddle.x - 5.5, saddle.y), pt(saddle.x + 5.5, saddle.y + 0.6), 2.8, k.black)
        cap(headTop, stemEnd, 2.4, k.black)
        cap(stemEnd, pt(stemEnd.x + 4.6, stemEnd.y + 3.2), 2.4, k.black)
        cap(pt(stemEnd.x + 4.6, stemEnd.y + 3.2), pt(stemEnd.x + 2.2, stemEnd.y + 8.4), 2.4, k.black)
        cap(pt(stemEnd.x + 1, stemEnd.y), pt(hands.x + 0.5, hands.y + 0.4), 3.2, k.black) // maneta

        // 4. Monoplato y biela de este lado.
        parts.append(Part(shape: .ring(bb, 4.6, 1.6), color: k.black))
        parts.append(Part(shape: .disc(bb, 2.4), color: k.metal, outlined: false))
        let nearPedal = pedal(0)
        cap(bb, nearPedal, 2.6, k.black)

        // 5. Cuerpo: culotte, maillot, pierna y brazo de este lado, cabeza y casco.
        parts.append(Part(shape: .disc(pt(hip.x - 0.5, hip.y + 0.5), 5.6), color: k.shorts))
        cap(hip, shoulder, 12.5, k.jersey)
        cap(pt(hip.x + 2, hip.y - 1.5), pt(shoulder.x - 1, shoulder.y + 4.5), 4, k.jerseyDark, outline: false) // costado
        let nearKnee = SceneIK.joint(from: hip, to: nearPedal, a: 20.6, b: 21.8, bendForward: true)
        let ankle = pt(nearPedal.x - 1.2, nearPedal.y - 3.2)
        cap(hip, nearKnee, 9.2, k.shorts)
        let kneeSkin = pt(nearKnee.x + (hip.x - nearKnee.x) * 0.18, nearKnee.y + (hip.y - nearKnee.y) * 0.18)
        cap(kneeSkin, nearKnee, 7.4, k.skin)
        let sock = pt(nearKnee.x + (ankle.x - nearKnee.x) * 0.55, nearKnee.y + (ankle.y - nearKnee.y) * 0.55)
        cap(nearKnee, sock, 6.4, k.skin)
        cap(sock, pt(ankle.x, ankle.y + 1.4), 5.6, k.socks)
        cap(pt(nearPedal.x - 2.8, nearPedal.y - 0.6), pt(nearPedal.x + 3.8, nearPedal.y + 0.3), 4, k.shoes)
        cap(pt(nearPedal.x - 2.8, nearPedal.y + 1.4), pt(nearPedal.x + 3.8, nearPedal.y + 1.8), 1.3, k.soles, outline: false)
        let elbow = SceneIK.joint(from: shoulder, to: hands, a: 14.4, b: 13.4, bendForward: false)
        let sleeveEnd = pt(shoulder.x + (elbow.x - shoulder.x) * 0.55, shoulder.y + (elbow.y - shoulder.y) * 0.55)
        cap(shoulder, sleeveEnd, 6.4, k.jersey)
        cap(sleeveEnd, elbow, 5.2, k.skin)
        cap(elbow, hands, 4.6, k.skin)
        parts.append(Part(shape: .disc(hands, 2.6), color: k.black))
        cap(shoulder, pt(head.x - 3, head.y + 3), 5, k.skin) // cuello
        parts.append(Part(shape: .disc(head, 5.4), color: k.skin))
        cap(pt(head.x + 1.5, head.y - 0.6), pt(head.x + 5.2, head.y - 0.2), 2.2, k.glasses, outline: false)
        // Casco: alargado hacia atrás, por encima de la cabeza.
        cap(pt(head.x - 6.5, head.y - 3.6), pt(head.x + 3.5, head.y - 4.8), 6.6, k.helmet)
        cap(pt(head.x - 3, head.y - 6.6), pt(head.x + 1, head.y - 7.2), 1.2, k.helmet.mix(RGB(1, 1, 1), 0.3), outline: false) // rejilla
        return parts
    }

    /// Caja que lo contiene todo (para rasterizar).
    static let bounds = CGRect(x: -40, y: -86, width: 82, height: 90)
}

enum SceneIK {
    /// Articulación (rodilla o codo) de dos tramos `a` y `b` entre dos puntos. Siempre al mismo
    /// lado de la línea que los une (la rodilla, delante; el codo, abajo y atrás): así no «salta»
    /// de un lado a otro cuando la pierna pasa por la vertical.
    static func joint(from p: CGPoint, to q: CGPoint, a: CGFloat, b: CGFloat, bendForward: Bool) -> CGPoint {
        let dx = q.x - p.x, dy = q.y - p.y
        let dist = min(max(sqrt(dx * dx + dy * dy), 1), a + b - 0.01)
        let along = (a * a - b * b + dist * dist) / (2 * dist)
        let h = sqrt(max(a * a - along * along, 0))
        let ux = dx / dist, uy = dy / dist
        let mid = CGPoint(x: p.x + ux * along, y: p.y + uy * along)
        let k1 = CGPoint(x: mid.x - uy * h, y: mid.y + ux * h)
        let k2 = CGPoint(x: mid.x + uy * h, y: mid.y - ux * h)
        return bendForward ? k2 : k1
    }
}

extension RiderModel.Shape {
    /// ¿Cubre este punto (coordenadas locales)? Para rasterizar en píxeles.
    func contains(_ p: CGPoint) -> Bool {
        switch self {
        case .capsule(let a, let b, let r):
            let abx = b.x - a.x, aby = b.y - a.y
            let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / max(abx * abx + aby * aby, 0.0001)))
            let cx = a.x + abx * t - p.x, cy = a.y + aby * t - p.y
            return cx * cx + cy * cy <= r * r
        case .disc(let c, let r):
            let dx = p.x - c.x, dy = p.y - c.y
            return dx * dx + dy * dy <= r * r
        case .ring(let c, let r, let w):
            let d = sqrt((p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y))
            return abs(d - r) <= w / 2
        }
    }
}

extension RiderModel {
    /// Rasteriza el ciclista en la rejilla de píxeles de la escena: `toLocal` pasa del centro de
    /// una celda de pantalla a coordenadas del ciclista. Añade un contorno de 1 píxel.
    static func drawPixels(_ c: inout GraphicsContext, parts: [Part], screenBox: CGRect, pixel: CGFloat,
                           toLocal: (CGPoint) -> CGPoint, outline: Color, tint: (RGB) -> RGB) {
        let x0 = Int((screenBox.minX / pixel).rounded(.down)) - 1, x1 = Int((screenBox.maxX / pixel).rounded(.up)) + 1
        let y0 = Int((screenBox.minY / pixel).rounded(.down)) - 1, y1 = Int((screenBox.maxY / pixel).rounded(.up)) + 1
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        guard w > 0, h > 0, w * h < 40_000 else { return }
        var cells = [Int](repeating: -1, count: w * h)
        for j in 0..<h {
            for i in 0..<w {
                let center = CGPoint(x: (CGFloat(x0 + i) + 0.5) * pixel, y: (CGFloat(y0 + j) + 0.5) * pixel)
                let local = toLocal(center)
                guard RiderModel.bounds.contains(local) else { continue }
                // La de encima gana: se busca de la última a la primera.
                if let k = parts.lastIndex(where: { $0.shape.contains(local) }) { cells[j * w + i] = k }
            }
        }
        var byColor: [Int: Path] = [:]
        var edge = Path()
        for j in 0..<h {
            for i in 0..<w {
                let rect = CGRect(x: CGFloat(x0 + i) * pixel, y: CGFloat(y0 + j) * pixel, width: pixel, height: pixel)
                let k = cells[j * w + i]
                if k >= 0 {
                    byColor[k, default: Path()].addRect(rect)
                } else {
                    let filled = (i > 0 && cells[j * w + i - 1] >= 0) || (i < w - 1 && cells[j * w + i + 1] >= 0)
                        || (j > 0 && cells[(j - 1) * w + i] >= 0) || (j < h - 1 && cells[(j + 1) * w + i] >= 0)
                    if filled { edge.addRect(rect) }
                }
            }
        }
        c.fill(edge, with: .color(outline))
        for (k, path) in byColor { c.fill(path, with: .color(tint(parts[k].color).color)) }
    }
}
