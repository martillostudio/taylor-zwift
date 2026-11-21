import CicloKit
import SpriteKit
import SwiftUI

/// Un escenario de pixel art hecho con capas de un pack (App/Escenarios/<id>/1.png…, de atrás
/// hacia delante; ver tools/instalar-escenarios.sh).
struct PixelZone: Identifiable, Hashable {
    let id: String
    let title: String
    /// Cuánto se mueve cada capa respecto a ti (0 = fija, 1 = a tu velocidad).
    let parallax: [Double]
    var snow = false
    var fireflies = false
    /// El cielo del pack ya trae luna o sol: no se pinta el nuestro.
    var ownLight = false

    static let all = [
        PixelZone(id: "prados", title: "Prados", parallax: [0, 0.03, 0.18, 0.45], fireflies: true),
        PixelZone(id: "pradera", title: "Pradera", parallax: [0, 0.04, 0.15, 0.4], fireflies: true),
        PixelZone(id: "bosque", title: "Bosque", parallax: [0, 0.04, 0.2, 0.5], fireflies: true),
        PixelZone(id: "montana", title: "Montaña", parallax: [0.01, 0.06, 0.4]),
        PixelZone(id: "invierno", title: "Invierno", parallax: [0, 0.02, 0.06, 0.12, 0.2, 0.3, 0.42, 0.55, 0.7], snow: true, ownLight: true),
    ]

    static var folder: URL? { Bundle.main.url(forResource: "Escenarios", withExtension: nil) }

    /// Los que están instalados.
    static var available: [PixelZone] {
        guard let folder else { return [] }
        return all.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0.id)/1.png").path) }
    }

    var layerURLs: [URL] {
        guard let folder = Self.folder else { return [] }
        return (1...parallax.count).map { folder.appendingPathComponent("\(id)/\($0).png") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Lo que la escena necesita en cada fotograma.
struct PixelWorldFeed {
    var distance: Double
    var crank: Double
    var palette: ScenePalette
    var table: RouteElevationTable
    var isLoop: Bool
}

/// Escena de SpriteKit a la resolución nativa del pack (p. ej. 576×324), ampliada sin suavizar:
/// las capas del pack con paralaje, el relieve de tu ruta en primer plano (con los colores de la
/// hierba del pack), el ciclista rasterizado con contorno, y el cielo según el sol: tinte de noche
/// o de atardecer, estrellas, luna, faro y partículas (nieve o luciérnagas).
final class PixelWorldScene: SKScene {
    let zone: PixelZone
    var feed: (() -> PixelWorldFeed)?

    private var layers: [(node: SKNode, sprites: [SKSpriteNode], parallax: Double, width: CGFloat)] = []
    private let terrain = SKSpriteNode()
    private let rider = SKSpriteNode()
    private let nightSky = SKSpriteNode()
    private let stars = SKNode()
    private let moon = SKSpriteNode()
    private let beam = SKSpriteNode()
    private var particles: SKEmitterNode?
    private var nativeSize = CGSize(width: 576, height: 324)
    private var groundColors = (top: RGB(0.45, 0.65, 0.3), body: RGB(0.3, 0.5, 0.22), path: RGB(0.75, 0.66, 0.5))
    /// Fila (desde abajo) donde empieza el suelo de la capa delantera del pack.
    private var packGroundFromBottom: CGFloat = 40
    /// Píxeles de la capa delantera: el suelo se pinta con ella, columna a columna, subiendo y
    /// bajando con el relieve de la ruta (así conserva la hierba, flores y árboles del pack).
    private var front: (pixels: [UInt32], w: Int, h: Int)?
    private var riderCache: [String: SKTexture] = [:]
    private var built = false

    /// Metros a lo ancho y exageración del relieve.
    private let metersWide = 380.0
    private let exaggeration = 2.0

    init(zone: PixelZone) {
        self.zone = zone
        super.init(size: CGSize(width: 576, height: 324))
        scaleMode = .aspectFill
        anchorPoint = .zero
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    override func didMove(to view: SKView) {
        view.preferredFramesPerSecond = 30
        view.ignoresSiblingOrder = true
        if !built { build() }
        fitToView(view.bounds.size)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
    }

    /// La altura es la del pack; el ancho, el de la ventana a esa escala.
    private func fitToView(_ viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let w = (nativeSize.height * viewSize.width / viewSize.height).rounded()
        if abs(size.width - w) > 1 || size.height != nativeSize.height {
            size = CGSize(width: w, height: nativeSize.height)
            layoutLayers()
        }
    }

    // MARK: Montaje

    private func build() {
        built = true
        let images = zone.layerURLs.compactMap(Self.cgImage)
        // El «suelo» es la capa más cercana con una fila entera de terreno; las que van delante
        // (un árbol suelto, por ejemplo) se pintan por encima del suelo.
        let groundIndex = images.indices.last { Self.groundRow(images[$0]) != nil } ?? images.count - 1
        for (i, image) in images.enumerated() {
            if i == 0 { nativeSize = CGSize(width: image.width, height: image.height) }
            let texture = SKTexture(cgImage: image)
            texture.filteringMode = .nearest
            let node = SKNode()
            node.zPosition = i > groundIndex ? 52 + CGFloat(i) : CGFloat(i)
            addChild(node)
            var sprites: [SKSpriteNode] = []
            for _ in 0..<4 {
                let s = SKSpriteNode(texture: texture)
                s.anchorPoint = .zero
                node.addChild(s)
                sprites.append(s)
            }
            layers.append((node, sprites, zone.parallax[min(i, zone.parallax.count - 1)], CGFloat(image.width)))
            if i == groundIndex {
                analyzeFrontLayer(image)
                if let px = Self.pixels(image) {
                    front = (px, image.width, image.height)
                    node.isHidden = true // la pinta el suelo, con el relieve
                }
            }
        }
        size = nativeSize

        nightSky.anchorPoint = .zero
        nightSky.zPosition = 0.5
        addChild(nightSky)
        stars.zPosition = 0.6
        addChild(stars)
        for i in 0..<60 {
            let star = SKSpriteNode(color: .white, size: CGSize(width: 1, height: 1))
            star.position = CGPoint(x: hash01(Double(i)) * 2000, y: 0)
            star.userData = ["y": 0.45 + 0.55 * hash01(Double(i) + 0.4)]
            stars.addChild(star)
        }
        moon.zPosition = 0.7
        addChild(moon)

        terrain.anchorPoint = .zero
        terrain.zPosition = 50
        addChild(terrain)
        rider.zPosition = 60
        addChild(rider)
        beam.zPosition = 59
        beam.blendMode = .add
        beam.texture = Self.beamTexture()
        beam.anchorPoint = CGPoint(x: 0, y: 0.5)
        addChild(beam)

        if zone.snow || zone.fireflies {
            let e = SKEmitterNode()
            let dot = SKTexture(cgImage: Self.dotImage())
            dot.filteringMode = .nearest
            e.particleTexture = dot
            e.zPosition = 55
            if zone.snow {
                e.particleBirthRate = 40
                e.particleLifetime = 9
                e.particleSpeed = 22
                e.particleSpeedRange = 10
                e.emissionAngle = -.pi / 2 - 0.3
                e.emissionAngleRange = 0.4
                e.particleAlpha = 0.9
                e.particleColor = .white
                e.particleColorBlendFactor = 1
                e.xAcceleration = -4
            } else {
                e.particleBirthRate = 3
                e.particleLifetime = 6
                e.particleSpeed = 4
                e.particleSpeedRange = 4
                e.emissionAngleRange = .pi * 2
                e.particleAlpha = 0
                e.particleAlphaSequence = SKKeyframeSequence(keyframeValues: [0, 1, 0.2, 1, 0], times: [0, 0.2, 0.5, 0.8, 1])
                e.particleColor = SKColor(red: 1, green: 0.95, blue: 0.5, alpha: 1)
                e.particleColorBlendFactor = 1
                e.particleBlendMode = .add
            }
            addChild(e)
            particles = e
        }
        layoutLayers()
    }

    private func layoutLayers() {
        for l in layers {
            for (k, s) in l.sprites.enumerated() { s.position = CGPoint(x: CGFloat(k) * l.width, y: 0) }
        }
        nightSky.size = size
        if let p = particles {
            if zone.snow {
                p.position = CGPoint(x: size.width * 0.6, y: size.height + 4)
                p.particlePositionRange = CGVector(dx: size.width * 1.4, dy: 0)
            } else {
                p.position = CGPoint(x: size.width / 2, y: size.height * 0.4)
                p.particlePositionRange = CGVector(dx: size.width, dy: size.height * 0.2)
            }
        }
    }

    /// Primera fila (desde arriba) con al menos el 90 % de píxeles opacos; `nil` si no hay.
    static func groundRow(_ image: CGImage) -> Int? {
        guard let px = pixels(image) else { return nil }
        let w = image.width
        for y in 0..<image.height {
            var opaque = 0
            for x in stride(from: 0, to: w, by: 4) where px[y * w + x] >> 24 > 230 { opaque += 1 }
            if opaque * 4 >= w * 9 / 10 { return y }
        }
        return nil
    }

    /// De la capa delantera saca dónde empieza el suelo y sus colores (hierba de arriba y de abajo).
    private func analyzeFrontLayer(_ image: CGImage) {
        guard let px = Self.pixels(image) else { return }
        let w = image.width, h = image.height
        func color(_ x: Int, _ y: Int) -> (RGB, Double) {
            let v = px[y * w + x]
            let a = Double((v >> 24) & 0xFF) / 255
            guard a > 0 else { return (RGB(0, 0, 0), 0) }
            return (RGB(Double(v & 0xFF) / 255 / a, Double((v >> 8) & 0xFF) / 255 / a, Double((v >> 16) & 0xFF) / 255 / a), a)
        }
        var groundRow = h - 40
        for y in 0..<h {
            let opaque = stride(from: 0, to: w, by: 4).filter { color($0, y).1 > 0.9 }.count
            if opaque * 4 >= w * 9 / 10 { groundRow = y; break }
        }
        packGroundFromBottom = CGFloat(h - groundRow)
        func average(rows: Range<Int>) -> RGB {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in rows where y < h {
                for x in stride(from: 0, to: w, by: 3) {
                    let (c, a) = color(x, y)
                    if a > 0.9 { r += c.r; g += c.g; b += c.b; n += 1 }
                }
            }
            return n > 0 ? RGB(r / n, g / n, b / n) : RGB(0.3, 0.5, 0.25)
        }
        let top = average(rows: groundRow..<(groundRow + 3))
        let body = average(rows: (h - 12)..<h)
        groundColors = (top, body, top.mix(RGB(0.85, 0.76, 0.58), zone.snow ? 0.15 : 0.6))
    }

    // MARK: Cada fotograma

    /// Para desarrollar: `--args -capturaSimulador 6` guarda a los 6 s una imagen de la escena en
    /// la carpeta temporal de la app (escena-<zona>.png), para revisarla sin mirar la pantalla.
    private var captureAt: TimeInterval?
    private func captureIfAsked(_ currentTime: TimeInterval) {
        let delay = UserDefaults.standard.double(forKey: "capturaSimulador")
        guard delay > 0, let view else { return }
        if captureAt == nil { captureAt = currentTime + delay }
        guard let at = captureAt, currentTime >= at, at > 0 else { return }
        captureAt = -1
        guard let image = view.texture(from: self)?.cgImage() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("escena-\(zone.id).png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        captureIfAsked(currentTime)
        guard let feed = MainActor.assumeIsolated({ self.feed?() }) else { return }
        if let view { fitToView(view.bounds.size) }
        let pxPerM = size.width / metersWide
        let yPerM = pxPerM * exaggeration
        let riderX = (size.width * 0.32).rounded()
        // El suelo del pack coincide con tu carretera en llano.
        let roadBase = (size.height * 0.27).rounded()
        func elevation(_ d: Double) -> Double {
            feed.table.elevation(atDistance: feed.isLoop ? d : min(max(d, 0), feed.table.lengthMeters))
        }
        let camElevation = (elevation(feed.distance) * 3 + elevation(feed.distance + 120)) / 4
        func groundY(_ d: Double) -> CGFloat { roadBase + CGFloat(elevation(d) - camElevation) * yPerM }
        func world(_ x: CGFloat) -> Double { feed.distance + Double(x - riderX) / pxPerM }

        // Capas del pack, ajustadas para que su suelo quede en la carretera.
        let packY = (roadBase - packGroundFromBottom).rounded()
        for l in layers {
            let shift = (CGFloat(feed.distance) * pxPerM * CGFloat(l.parallax)).truncatingRemainder(dividingBy: l.width)
            l.node.position = CGPoint(x: -shift.rounded(), y: l.parallax == 0 && l.node.zPosition == 0 ? max(packY, size.height - nativeSize.height) : packY)
        }

        // Tinte según el sol: noche azul, atardecer cálido.
        let p = feed.palette
        let night = p.stars
        let warm = max(0, min(1, (p.skyBottom.r - p.skyBottom.b) * 2.2)) * (1 - night)
        let tint = night > 0.05 ? RGB(0.32, 0.38, 0.66) : RGB(1, 0.72, 0.55)
        let factor = CGFloat(night * 0.72 + warm * 0.35)
        for l in layers { for s in l.sprites { s.color = tint.skColor; s.colorBlendFactor = factor } }
        nightSky.texture = Self.gradientTexture(top: p.skyTop, bottom: p.skyBottom)
        nightSky.alpha = CGFloat(night * 0.85)
        stars.alpha = CGFloat(night)
        for case let s as SKSpriteNode in stars.children {
            let baseX = s.position.x.truncatingRemainder(dividingBy: max(size.width, 1))
            s.position = CGPoint(x: baseX, y: size.height * CGFloat((s.userData?["y"] as? Double) ?? 0.8))
        }
        moon.texture = Self.discTexture(radius: 6, color: p.light, crescent: p.isMoon)
        moon.size = CGSize(width: 13, height: 13)
        moon.position = CGPoint(x: (size.width * CGFloat(p.lightX)).rounded(), y: (size.height * (1 - CGFloat(p.lightY))).rounded())
        moon.alpha = zone.ownLight ? 0 : (p.isMoon ? CGFloat(night) : 0.9)

        // Primer plano: el relieve de tu ruta con la hierba del pack.
        terrain.texture = drawGround(groundY: groundY, world: world, pxPerM: pxPerM, distance: feed.distance)
        terrain.size = size
        terrain.position = .zero
        terrain.color = tint.skColor
        terrain.colorBlendFactor = factor

        // Ciclista.
        let slope = atan2(Double(groundY(feed.distance + 3) - groundY(feed.distance - 3)), 6 * Double(pxPerM))
        let (texture, anchor) = riderTexture(crank: feed.crank, distance: feed.distance, slope: slope)
        rider.color = tint.skColor
        rider.colorBlendFactor = factor * 0.4
        rider.texture = texture
        rider.size = texture.size()
        rider.anchorPoint = anchor
        rider.position = CGPoint(x: riderX, y: groundY(feed.distance).rounded() - 1)

        beam.alpha = CGFloat(night)
        beam.size = CGSize(width: 70, height: 22)
        beam.zRotation = CGFloat(slope) - 0.25
        beam.position = CGPoint(x: riderX + 17 * CGFloat(cos(slope)), y: rider.position.y + 22)

        particles?.particleBirthRate = zone.snow ? 40 : (night > 0.5 ? 3 : 0)
    }

    /// El suelo: la capa delantera del pack desplazada, columna a columna, a la altura de la ruta;
    /// debajo, el color de su hierba con motas; arriba, un camino de dos píxeles.
    private func drawGround(groundY: (Double) -> CGFloat, world: (CGFloat) -> Double, pxPerM: CGFloat, distance: Double) -> SKTexture {
        let w = Int(size.width), h = Int(size.height)
        var buffer = [UInt32](repeating: 0, count: w * h)
        func pack(_ c: RGB) -> UInt32 {
            0xFF00_0000 | UInt32(min(max(c.b, 0), 1) * 255) << 16 | UInt32(min(max(c.g, 0), 1) * 255) << 8 | UInt32(min(max(c.r, 0), 1) * 255)
        }
        let body = pack(groundColors.body), speck = pack(groundColors.body.mix(RGB(0, 0, 0), 0.18))
        let path = pack(groundColors.path), pathDark = pack(groundColors.path.mix(RGB(0, 0, 0), 0.22))
        let base = Int(packGroundFromBottom)
        let frontShift = Int((CGFloat(distance) * pxPerM).rounded())
        buffer.withUnsafeMutableBufferPointer { out in
            for x in 0..<w {
                let d = world(CGFloat(x) + 0.5)
                let gy = Int(groundY(d).rounded())          // fila del suelo, desde abajo
                let off = gy - base                          // cuánto sube o baja la columna del pack
                if let f = front {
                    let sx = ((x + frontShift) % f.w + f.w) % f.w
                    f.pixels.withUnsafeBufferPointer { src in
                        for r in 0..<f.h {
                            let v = src[r * f.w + sx]
                            guard v >> 24 != 0 else { continue }
                            let y = (f.h - 1 - r) + off      // desde abajo
                            if y >= 0, y < h { out[(h - 1 - y) * w + x] = v }
                        }
                    }
                }
                // Debajo de la capa (si la columna ha subido): hierba con motas.
                if off > 0 {
                    let col = Double(x + frontShift)
                    for y in 0..<min(off, h) {
                        out[(h - 1 - y) * w + x] = hash01(col * 3.1 + Double(y) * 7.7) > 0.93 ? speck : body
                    }
                }
                // Camino.
                for k in 1...2 {
                    let y = gy - k
                    if y >= 0, y < h { out[(h - 1 - y) * w + x] = k == 1 && hash01(Double(x + frontShift) * 1.7) > 0.8 ? pathDark : path }
                }
            }
        }
        let texture = SKTexture(cgImage: Self.image(buffer, w, h))
        texture.filteringMode = .nearest
        return texture
    }

    // MARK: Texturas

    /// El ciclista rasterizado a la resolución de la escena (≈ 55 px de alto), con contorno.
    /// Se guardan los fotogramas (24 posiciones de biela × inclinación × giro de rueda).
    private func riderTexture(crank: Double, distance: Double, slope: Double) -> (SKTexture, CGPoint) {
        let s: CGFloat = 0.62
        let w = 76, h = 72
        let ox = 37.0, oy = 64.0   // dónde cae el origen (suelo bajo el pedalier) en la imagen
        let anchor = CGPoint(x: ox / Double(w), y: 1 - oy / Double(h))
        let frames = 24
        let crankIdx = ((Int((crank / (2 * .pi) * Double(frames)).rounded()) % frames) + frames) % frames
        let slopeIdx = Int((slope * 180 / .pi).rounded())
        // Los 6 radios se repiten cada 30°: 3 pasos de 10°.
        let wheelIdx = Int((distance / 2.2 * 36).rounded(.down)) % 3
        let key = "\(crankIdx)/\(slopeIdx)/\(wheelIdx)"
        if let t = riderCache[key] { return (t, anchor) }

        let parts = RiderModel.parts(crank: Double(crankIdx) / Double(frames) * 2 * .pi,
                                     distance: Double(wheelIdx) * 2.2 / 36)
        let a = Double(slopeIdx) * .pi / 180
        let c = cos(a), sn = sin(a)
        var cells = [Int](repeating: -1, count: w * h)
        for j in 0..<h {
            for i in 0..<w {
                // Pantalla (y hacia abajo en la imagen) → coordenadas del ciclista (girado con la pendiente).
                let dx = (Double(i) + 0.5 - ox) / Double(s), dy = (Double(j) + 0.5 - oy) / Double(s)
                // En la imagen la y va hacia abajo: subir es girar al revés que en la escena.
                let local = CGPoint(x: dx * c - dy * sn, y: dx * sn + dy * c)
                guard RiderModel.bounds.contains(local) else { continue }
                if let k = parts.lastIndex(where: { $0.shape.contains(local) }) { cells[j * w + i] = k }
            }
        }
        var buffer = [UInt32](repeating: 0, count: w * h)
        let outline: UInt32 = 0xFF18_1010
        for j in 0..<h {
            for i in 0..<w {
                let k = cells[j * w + i]
                if k >= 0 {
                    let col = parts[k].color
                    buffer[j * w + i] = 0xFF00_0000 | UInt32(col.b * 255) << 16 | UInt32(col.g * 255) << 8 | UInt32(col.r * 255)
                } else if (i > 0 && cells[j * w + i - 1] >= 0) || (i < w - 1 && cells[j * w + i + 1] >= 0)
                            || (j > 0 && cells[(j - 1) * w + i] >= 0) || (j < h - 1 && cells[(j + 1) * w + i] >= 0) {
                    buffer[j * w + i] = outline
                }
            }
        }
        let texture = SKTexture(cgImage: Self.image(buffer, w, h))
        texture.filteringMode = .nearest
        if riderCache.count > 800 { riderCache.removeAll() }
        riderCache[key] = texture
        return (texture, anchor)
    }

    private static var gradientCache: (key: String, texture: SKTexture)?
    private static func gradientTexture(top: RGB, bottom: RGB) -> SKTexture {
        let key = "\(top)\(bottom)"
        if let c = gradientCache, c.key == key { return c.texture }
        let h = 64
        var buffer = [UInt32](repeating: 0, count: h)
        for y in 0..<h {
            let c = top.mix(bottom, Double(y) / Double(h - 1))
            buffer[y] = 0xFF00_0000 | UInt32(c.b * 255) << 16 | UInt32(c.g * 255) << 8 | UInt32(c.r * 255)
        }
        let t = SKTexture(cgImage: image(buffer, 1, h))
        gradientCache = (key, t)
        return t
    }

    private static var discCache: [String: SKTexture] = [:]
    private static func discTexture(radius r: Int, color: RGB, crescent: Bool) -> SKTexture {
        let key = "\(r)\(color)\(crescent)"
        if let t = discCache[key] { return t }
        let n = 2 * r + 1
        var buffer = [UInt32](repeating: 0, count: n * n)
        let v = 0xFF00_0000 | UInt32(color.b * 255) << 16 | UInt32(color.g * 255) << 8 | UInt32(color.r * 255)
        for y in 0..<n {
            for x in 0..<n {
                let dx = x - r, dy = y - r
                guard dx * dx + dy * dy <= r * r else { continue }
                if crescent { let ex = dx - r / 2, ey = dy + r / 3; if ex * ex + ey * ey <= r * r { continue } }
                buffer[y * n + x] = v
            }
        }
        let t = SKTexture(cgImage: image(buffer, n, n))
        t.filteringMode = .nearest
        if discCache.count > 20 { discCache.removeAll() }
        discCache[key] = t
        return t
    }

    private static func beamTexture() -> SKTexture {
        let w = 70, h = 22
        var buffer = [UInt32](repeating: 0, count: w * h)
        for x in 0..<w {
            let spread = 1 + Double(x) * 0.15
            let a = (1 - Double(x) / Double(w)) * 0.35
            for y in 0..<h where abs(Double(y) - Double(h) / 2) <= spread {
                let alpha = UInt32(a * 255)
                buffer[y * w + x] = alpha << 24 | UInt32(Double(alpha) * 0.75) << 16 | UInt32(Double(alpha) * 0.95) << 8 | alpha
            }
        }
        let t = SKTexture(cgImage: image(buffer, w, h))
        t.filteringMode = .nearest
        return t
    }

    private static func dotImage() -> CGImage { image([0xFFFF_FFFF], 1, 1) }

    // MARK: Píxeles

    /// RGBA premultiplicado en memoria (en el UInt32: rojo en el byte bajo, alfa en el alto).
    static func image(_ buffer: [UInt32], _ w: Int, _ h: Int) -> CGImage {
        let data = buffer.withUnsafeBufferPointer { Data(buffer: $0) }
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func pixels(_ image: CGImage) -> [UInt32]? {
        let w = image.width, h = image.height
        var buffer = [UInt32](repeating: 0, count: w * h)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buffer : nil
    }

    static func cgImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

extension RGB {
    var skColor: SKColor { SKColor(red: r, green: g, blue: b, alpha: 1) }
}
