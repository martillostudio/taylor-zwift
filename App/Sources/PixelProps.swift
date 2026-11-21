import SpriteKit

/// Elementos del camino en pixel art, dibujados por código con tres tonos (luz arriba a la
/// izquierda) y contorno de 1 píxel: rocas, un trozo de valla y el poste de km con números de
/// píxeles. En Invierno, con nieve encima.
struct PixelProps {
    let snow: Bool
    let rock: SKTexture
    let bigRock: SKTexture
    let fence: SKTexture
    private var kmCache: [Int: SKTexture] = [:]

    init(snow: Bool) {
        self.snow = snow
        rock = Self.rock(width: 9, height: 5, snow: snow)
        bigRock = Self.rock(width: 15, height: 9, snow: snow)
        fence = Self.fence(snow: snow)
    }

    mutating func kmSign(_ km: Int) -> SKTexture {
        if let t = kmCache[km] { return t }
        let t = Self.sign(km, snow: snow)
        kmCache[km] = t
        return t
    }

    // MARK: Dibujo en una rejilla

    private struct Grid {
        let w: Int, h: Int
        var px: [UInt32]
        init(_ w: Int, _ h: Int) { self.w = w; self.h = h; px = [UInt32](repeating: 0, count: w * h) }
        subscript(x x: Int, y y: Int) -> UInt32 {
            get { x >= 0 && x < w && y >= 0 && y < h ? px[y * w + x] : 0 }
            set { if x >= 0 && x < w && y >= 0 && y < h { px[y * w + x] = newValue } }
        }
        /// Contorno de 1 píxel alrededor de lo pintado.
        mutating func outline(_ c: UInt32) {
            var out = px
            for y in 0..<h { for x in 0..<w where self[x: x, y: y] == 0 {
                if self[x: x - 1, y: y] != 0 || self[x: x + 1, y: y] != 0 || self[x: x, y: y - 1] != 0 || self[x: x, y: y + 1] != 0 {
                    out[y * w + x] = c
                }
            } }
            px = out
        }
        var texture: SKTexture {
            let t = SKTexture(cgImage: PixelWorldScene.image(px, w, h))
            t.filteringMode = .nearest
            return t
        }
    }

    private static func c(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        0xFF00_0000 | UInt32(b * 255) << 16 | UInt32(g * 255) << 8 | UInt32(r * 255)
    }
    private static let ink = c(0.10, 0.09, 0.10)
    private static let snowWhite = c(0.95, 0.97, 1.0), snowShade = c(0.78, 0.84, 0.94)

    /// Roca: media elipse con luz, tono medio y sombra.
    private static func rock(width: Int, height: Int, snow: Bool) -> SKTexture {
        var g = Grid(width + 2, height + 2)
        let light = c(0.72, 0.70, 0.66), mid = c(0.54, 0.52, 0.50), dark = c(0.36, 0.35, 0.35)
        let cx = Double(width) / 2 + 1, ry = Double(height)
        for y in 0..<height { for x in 0..<width {
            let dx = (Double(x) + 1.5 - cx) / (Double(width) / 2), dy = (Double(height - y)) / ry
            guard dx * dx + dy * dy * 0.9 <= 1 else { continue }
            let shade = dx * 0.6 - dy * 0.8
            g[x: x + 1, y: y + 1] = shade < -0.35 ? light : (shade > 0.25 ? dark : mid)
        } }
        if snow { for x in 0..<(width + 2) { if let y = (0..<(height + 2)).first(where: { g[x: x, y: $0] != 0 }) {
            g[x: x, y: y] = snowWhite; g[x: x, y: y + 1] = x > width / 2 ? snowShade : snowWhite
        } } }
        g.outline(ink)
        return g.texture
    }

    /// Trozo de valla de madera: dos postes y dos travesaños (24 px de largo).
    private static func fence(snow: Bool) -> SKTexture {
        var g = Grid(26, 12)
        let wood = c(0.58, 0.42, 0.27), woodLight = c(0.72, 0.55, 0.36), woodDark = c(0.40, 0.28, 0.18)
        for post in [2, 14] { for y in 2..<12 {
            g[x: post, y: y] = woodLight; g[x: post + 1, y: y] = wood; g[x: post + 2, y: y] = woodDark
        } }
        for rail in [4, 8] { for x in 0..<26 where g[x: x, y: rail] == 0 {
            g[x: x, y: rail] = wood; g[x: x, y: rail + 1] = woodDark
        } }
        if snow { for post in [2, 14] { for k in 0..<3 { g[x: post + k, y: 1] = snowWhite } } ; for x in 0..<26 { g[x: x, y: 3] = g[x: x, y: 4] == 0 ? 0 : snowWhite } }
        g.outline(ink)
        return g.texture
    }

    /// Dígitos de 3×5.
    private static let digits: [[String]] = [
        ["###", "#.#", "#.#", "#.#", "###"], [".#.", "##.", ".#.", ".#.", "###"], ["###", "..#", "###", "#..", "###"],
        ["###", "..#", "###", "..#", "###"], ["#.#", "#.#", "###", "..#", "..#"], ["###", "#..", "###", "..#", "###"],
        ["###", "#..", "###", "#.#", "###"], ["###", "..#", "..#", ".#.", ".#."], ["###", "#.#", "###", "#.#", "###"],
        ["###", "#.#", "###", "..#", "###"],
    ]

    /// Poste con un cartel blanco y el número de km.
    private static func sign(_ km: Int, snow: Bool) -> SKTexture {
        let text = String(km)
        let plateW = max(text.count * 4 + 4, 11), plateH = 9
        var g = Grid(plateW + 2, 22)
        let wood = c(0.50, 0.36, 0.24), plate = c(0.96, 0.94, 0.86), plateDark = c(0.80, 0.77, 0.68), red = c(0.80, 0.22, 0.18)
        let postX = (plateW + 2) / 2
        for y in plateH..<22 { g[x: postX, y: y] = wood; g[x: postX - 1, y: y] = wood }
        for y in 1...plateH { for x in 1...plateW { g[x: x, y: y] = y == plateH ? plateDark : plate } }
        for x in 1...plateW { g[x: x, y: 1] = red }
        for (k, ch) in text.enumerated() {
            guard let n = Int(String(ch)) else { continue }
            for (row, line) in digits[n].enumerated() { for (col, p) in line.enumerated() where p == "#" {
                g[x: 3 + k * 4 + col, y: 3 + row] = ink
            } }
        }
        if snow { for x in 1...plateW { g[x: x, y: 0] = snowWhite } }
        g.outline(ink)
        return g.texture
    }
}
