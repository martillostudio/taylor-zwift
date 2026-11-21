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

    /// El escenario que pega con un tipo de paisaje; si no está instalado, el más parecido.
    static func matching(_ scenery: Scenery) -> PixelZone? {
        let preference: [String] = switch scenery {
        case .snow: ["invierno", "montana", "bosque"]
        case .mountain: ["montana", "bosque", "pradera"]
        case .forest: ["bosque", "pradera", "prados"]
        case .rolling: ["pradera", "prados", "bosque"]
        case .meadow: ["prados", "pradera", "bosque"]
        }
        let available = Self.available
        return preference.lazy.compactMap { id in available.first { $0.id == id } }.first ?? available.first
    }

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
    /// Tamaño de la capa delantera: el suelo (shader) la pinta columna a columna, subiendo y
    /// bajando con el relieve de la ruta (así conserva la hierba, flores y árboles del pack).
    private var front: (w: Int, h: Int)?
    private var riderCache: [String: SKTexture] = [:]

    // MARK: Suelo en la tarjeta gráfica

    /// El suelo se pinta en la GPU: cada fotograma solo se manda la altura de cada columna
    /// (`u_offsets`, una fila de píxeles); el shader coloca la capa delantera del pack a esa altura,
    /// rellena por debajo con la hierba y sus motas, pinta el camino (solo sobre hierba, no sobre
    /// arbustos ni rocas del pack) y suma la luz del faro de noche.
    private static let groundShaderSource = """
    void main() {
        vec2 p = floor(v_tex_coord * u_size);
        vec4 o = texture2D(u_offsets, vec2((p.x + 0.5) / u_size.x, 0.5));
        float off = floor(o.r * 255.0 + 0.5) + floor(o.g * 255.0 + 0.5) * 256.0 - 1024.0;
        float gy = u_base + off;
        float src = p.y - off;
        float sx = mod(p.x + u_shift, u_front_size.x);
        vec4 c = vec4(0.0);
        if (src >= 0.0 && src < u_front_size.y) {
            c = texture2D(u_front, vec2((sx + 0.5) / u_front_size.x, (src + 0.5) / u_front_size.y));
        } else if (src < 0.0) {
            float h = fract(sin((p.x + u_shift) * 3.1 + p.y * 7.7) * 43758.5453);
            c = h > 0.93 ? u_speck : u_body;
        }
        if (p.y < gy && p.y >= gy - 2.0 && c.a > 0.9 && distance(c.rgb, u_grass.rgb) < 0.32) {
            float h = fract(sin((p.x + u_shift) * 1.7) * 43758.5453);
            c = (p.y >= gy - 1.0 && h > 0.8) ? u_path_dark : u_path;
        }
        c.rgb = c.rgb * mix(vec3(1.0), u_tint.rgb, u_tint.a);
        vec2 d = (p - u_light.xy) / vec2(u_light.z, u_light.z * 0.45);
        float glow = max(0.0, 1.0 - dot(d, d)) * u_light.w;
        c.rgb += vec3(1.0, 0.93, 0.7) * glow * c.a;
        gl_FragColor = c;
    }
    """
    private lazy var groundShader: SKShader = {
        let shader = SKShader(source: Self.groundShaderSource)
        shader.uniforms = [
            SKUniform(name: "u_front", texture: frontTexture),
            SKUniform(name: "u_offsets", texture: SKTexture()),
            SKUniform(name: "u_size", vectorFloat2: .zero),
            SKUniform(name: "u_front_size", vectorFloat2: .zero),
            SKUniform(name: "u_shift", float: 0),
            SKUniform(name: "u_base", float: 0),
            SKUniform(name: "u_body", vectorFloat4: .zero),
            SKUniform(name: "u_speck", vectorFloat4: .zero),
            SKUniform(name: "u_grass", vectorFloat4: .zero),
            SKUniform(name: "u_path", vectorFloat4: .zero),
            SKUniform(name: "u_path_dark", vectorFloat4: .zero),
            SKUniform(name: "u_tint", vectorFloat4: .zero),
            SKUniform(name: "u_light", vectorFloat4: .zero),
        ]
        return shader
    }()
    private var frontTexture = SKTexture()

    private func setUniform(_ name: String, _ v: SIMD4<Float>) { groundShader.uniformNamed(name)?.vectorFloat4Value = v }
    private func setUniform(_ name: String, _ v: SIMD2<Float>) { groundShader.uniformNamed(name)?.vectorFloat2Value = v }
    private func setUniform(_ name: String, _ v: Float) { groundShader.uniformNamed(name)?.floatValue = v }
    private static func vec(_ c: RGB, _ a: Float = 1) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), a) }
    /// Pedalada dibujada a mano (App/Escenarios/ciclista/pedalada.png: fotogramas cuadrados en
    /// fila, el primero con la biela de este lado hacia delante; el suelo bajo el pedalier en
    /// (37, 64) de cada fotograma de 76×72, como la plantilla de docs/plantilla-ciclista.png).
    private lazy var handFrames: [SKTexture]? = {
        guard let url = PixelZone.folder?.appendingPathComponent("ciclista/pedalada.png"),
              let image = Self.cgImage(url) else { return nil }
        let frameW = image.height * 76 / 72
        let n = max(image.width / max(frameW, 1), 1)
        let sheet = SKTexture(cgImage: image)
        sheet.filteringMode = .nearest
        return (0..<n).map { k in
            let t = SKTexture(rect: CGRect(x: CGFloat(k) / CGFloat(n), y: 0, width: 1 / CGFloat(n), height: 1), in: sheet)
            t.filteringMode = .nearest
            return t
        }
    }()
    private var built = false
    /// Todo va dentro de un nodo de efectos: de noche, un resplandor suave (luna, estrellas, faro).
    private let post = SKEffectNode()
    private let bloom = CIFilter(name: "CIBloom")
    /// Rocas, vallas y postes de km a lo largo del camino (se reutilizan los nodos).
    private var propPool: [SKSpriteNode] = []
    private lazy var propTextures = PixelProps(snow: zone.snow)

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
        addChild(post)
        post.shouldRasterize = false
        post.filter = bloom
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
            post.addChild(node)
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
                front = (image.width, image.height)
                frontTexture = texture
                node.isHidden = true // la pinta el suelo (shader), con el relieve
            }
        }
        size = nativeSize

        nightSky.anchorPoint = .zero
        nightSky.zPosition = 0.5
        post.addChild(nightSky)
        stars.zPosition = 0.6
        post.addChild(stars)
        for i in 0..<60 {
            let star = SKSpriteNode(color: .white, size: CGSize(width: 1, height: 1))
            star.position = CGPoint(x: hash01(Double(i)) * 2000, y: 0)
            star.userData = ["y": 0.45 + 0.55 * hash01(Double(i) + 0.4)]
            stars.addChild(star)
        }
        moon.zPosition = 0.7
        post.addChild(moon)

        terrain.anchorPoint = .zero
        terrain.zPosition = 50
        post.addChild(terrain)
        rider.zPosition = 60
        post.addChild(rider)
        beam.zPosition = 59
        beam.blendMode = .add
        beam.texture = Self.beamTexture()
        beam.anchorPoint = CGPoint(x: 0, y: 0.5)
        post.addChild(beam)

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
            post.addChild(e)
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
        // Camino: la hierba de arriba tirando a tierra, sin pasarse (en zonas oscuras cantaba mucho).
        groundColors = (top, body, top.mix(RGB(0.78, 0.69, 0.52), zone.snow ? 0.12 : 0.4))
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

    /// Para desarrollar: `--args -exportarCiclista YES` guarda la pedalada actual (12 fotogramas de
    /// 76×72 en fila, en llano) como plantilla-ciclista.png en la carpeta temporal de la app.
    private var exported = false
    private func exportRiderIfAsked() {
        guard !exported, UserDefaults.standard.bool(forKey: "exportarCiclista") else { return }
        exported = true
        let n = 12
        let w = 76, h = 72
        guard let ctx = CGContext(data: nil, width: w * n, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        for k in 0..<n {
            let (t, _) = riderTexture(crank: Double(k) / Double(n) * 2 * .pi, distance: 0, slope: 0)
            ctx.draw(t.cgImage(), in: CGRect(x: k * w, y: 0, width: w, height: h))
        }
        guard let image = ctx.makeImage() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plantilla-ciclista.png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        exportRiderIfAsked()
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
        updateGround(groundY: groundY, world: world, pxPerM: pxPerM, distance: feed.distance, tint: tint,
                     factor: Float(factor), night: Float(night), riderX: riderX, riderY: groundY(feed.distance))

        // Ciclista.
        let slope = atan2(Double(groundY(feed.distance + 3) - groundY(feed.distance - 3)), 6 * Double(pxPerM))
        let texture: SKTexture, anchor: CGPoint
        if let frames = handFrames {
            // Fotogramas a mano: el que toca según la biela, girado con la pendiente.
            let k = ((Int((feed.crank / (2 * .pi) * Double(frames.count)).rounded()) % frames.count) + frames.count) % frames.count
            texture = frames[k]
            anchor = CGPoint(x: 37.0 / 76, y: 1 - 64.0 / 72)
            rider.zRotation = CGFloat(slope)
        } else {
            (texture, anchor) = riderTexture(crank: feed.crank, distance: feed.distance, slope: slope)
            rider.zRotation = 0
        }
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

        // Resplandor de noche (Core Image en la GPU).
        post.shouldEnableEffects = night > 0.3
        bloom?.setValue(2.5, forKey: kCIInputRadiusKey)
        bloom?.setValue(0.45 * night, forKey: kCIInputIntensityKey)

        placeProps(distance: feed.distance, pxPerM: pxPerM, riderX: riderX, groundY: groundY, tint: tint, factor: factor)
    }

    /// Manda al shader del suelo la altura de cada columna y los colores de este fotograma.
    private func updateGround(groundY: (Double) -> CGFloat, world: (CGFloat) -> Double, pxPerM: CGFloat,
                              distance: Double, tint: RGB, factor: Float, night: Float, riderX: CGFloat, riderY: CGFloat) {
        let w = Int(size.width)
        guard w > 0, let f = front else { return }
        let base = Int(packGroundFromBottom)
        var bytes = [UInt8](repeating: 0, count: w * 4)
        for x in 0..<w {
            let gy = Int(groundY(world(CGFloat(x) + 0.5)).rounded())
            let v = min(max(gy - base + 1024, 0), 65_535)
            bytes[x * 4] = UInt8(v & 0xFF)
            bytes[x * 4 + 1] = UInt8(v >> 8)
            bytes[x * 4 + 3] = 255
        }
        let offsets = SKTexture(data: Data(bytes), size: CGSize(width: w, height: 1))
        offsets.filteringMode = .nearest
        groundShader.uniformNamed("u_offsets")?.textureValue = offsets
        if terrain.shader == nil {
            terrain.texture = SKTexture(cgImage: Self.image([0xFFFF_FFFF], 1, 1))
            terrain.shader = groundShader
        }
        terrain.size = size
        terrain.position = .zero
        setUniform("u_size", SIMD2(Float(size.width), Float(size.height)))
        setUniform("u_front_size", SIMD2(Float(f.w), Float(f.h)))
        setUniform("u_shift", Float((CGFloat(distance) * pxPerM).rounded()))
        setUniform("u_base", Float(base))
        setUniform("u_body", Self.vec(groundColors.body))
        setUniform("u_speck", Self.vec(groundColors.body.mix(RGB(0, 0, 0), 0.18)))
        setUniform("u_grass", Self.vec(groundColors.top))
        setUniform("u_path", Self.vec(groundColors.path))
        setUniform("u_path_dark", Self.vec(groundColors.path.mix(RGB(0, 0, 0), 0.22)))
        setUniform("u_tint", Self.vec(tint, factor))
        // Faro: un óvalo de luz en el suelo, por delante de la rueda.
        setUniform("u_light", SIMD4(Float(riderX + 46), Float(riderY), 40, night * 0.22))
    }

    // MARK: Elementos del camino

    /// Postes de km en cada kilómetro, vallas a tramos y rocas sueltas, siempre en los mismos sitios
    /// de la ruta. Van delante del suelo y detrás del ciclista.
    private func placeProps(distance: Double, pxPerM: CGFloat, riderX: CGFloat, groundY: (Double) -> CGFloat,
                            tint: RGB, factor: CGFloat) {
        var items: [(SKTexture, Double)] = []
        let left = distance - Double(riderX / pxPerM) - 20
        let right = distance + Double((size.width - riderX) / pxPerM) + 20
        // Km.
        var d = max((left / 1000).rounded(.up), 1) * 1000
        while d <= right { items.append((propTextures.kmSign(Int(d / 1000)), d)); d += 1000 }
        // Vallas: tramos donde una onda lenta lo permite, un trozo cada «largo de valla».
        let fenceMeters = Double(propTextures.fence.size().width / pxPerM)
        d = (left / fenceMeters).rounded(.down) * fenceMeters
        while d <= right {
            if sin(d / 140 + 0.7) + 0.5 * sin(d / 47) > 0.85 { items.append((propTextures.fence, d)) }
            d += fenceMeters
        }
        // Rocas.
        d = (left / 13).rounded(.down) * 13
        while d <= right {
            let r = hash01(d * 0.37 + 5)
            if r > 0.86 { items.append((r > 0.95 ? propTextures.bigRock : propTextures.rock, d + r * 6)) }
            d += 13
        }
        while propPool.count < items.count {
            let node = SKSpriteNode()
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            node.zPosition = 51
            post.addChild(node)
            propPool.append(node)
        }
        for (i, node) in propPool.enumerated() {
            guard i < items.count else { node.isHidden = true; continue }
            let (texture, at) = items[i]
            node.isHidden = false
            node.texture = texture
            node.size = texture.size()
            node.color = tint.skColor
            node.colorBlendFactor = factor
            node.position = CGPoint(x: (riderX + CGFloat(at - distance) * pxPerM).rounded(), y: groundY(at).rounded() - 2)
        }
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
        func cell(_ i: Int, _ j: Int) -> Int { i >= 0 && i < w && j >= 0 && j < h ? cells[j * w + i] : -1 }
        for j in 0..<h {
            for i in 0..<w {
                let k = cells[j * w + i]
                if k >= 0 {
                    // Sombreado de pixel art con la luz arriba a la izquierda: borde de arriba más
                    // claro, borde de abajo y de la derecha más oscuro (solo en las piezas grandes).
                    var col = parts[k].color
                    if parts[k].outlined {
                        if cell(i, j + 1) != k || cell(i + 1, j) != k { col = col.mix(RGB(0.05, 0.05, 0.12), 0.28) }
                        else if cell(i, j - 1) != k || cell(i - 1, j) != k { col = col.mix(RGB(1, 1, 0.95), 0.22) }
                    }
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
