/// Qué hace cada botón de los Zwift Click V2 cuando los usamos como mando de otra app
/// (p. ej. MyWhoosh).
public enum BridgeAction: String, CaseIterable, Sendable {
    case shiftUp
    case shiftDown
    case up
    case down
    case left
    case right
    case select
    case back

    public var label: String {
        switch self {
        case .shiftUp: "Subir marcha"
        case .shiftDown: "Bajar marcha"
        case .up: "Arriba"
        case .down: "Abajo"
        case .left: "Izquierda"
        case .right: "Derecha"
        case .select: "Aceptar"
        case .back: "Atrás"
        }
    }

    /// Acción equivalente en OpenBikeControl.
    public var openBikeControl: OpenBikeControl.Action {
        switch self {
        case .shiftUp: .shiftUp
        case .shiftDown: .shiftDown
        case .up: .navUp
        case .down: .navDown
        case .left: .navLeft
        case .right: .navRight
        case .select: .select
        case .back: .back
        }
    }

    /// Tecla del Mac que hace lo mismo en MyWhoosh (código de tecla virtual de macOS).
    /// MyWhoosh: K = subir marcha, I = bajar marcha (como en el mapa de teclas de BikeControl).
    public var macKeyCode: UInt16 {
        switch self {
        case .shiftUp: 40 // K
        case .shiftDown: 34 // I
        case .up: 126 // ↑
        case .down: 125 // ↓
        case .left: 123 // ←
        case .right: 124 // →
        case .select: 36 // Intro
        case .back: 53 // Esc
        }
    }

    public var keyLabel: String {
        switch self {
        case .shiftUp: "K"
        case .shiftDown: "I"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .select: "Intro"
        case .back: "Esc"
        }
    }
}

public enum BridgeMapping {
    /// Botón del Click V2 → acción, en el orden en que se muestran.
    ///
    /// - El «−» del mando izquierdo es el bit `shiftUpLeft` y el «+» del derecho, `shiftUpRight`.
    /// - Y y Z (mando derecho) repiten bajar/subir marcha: si el izquierdo se bloquea
    ///   (ver guía §5.1), se puede seguir cambiando solo con el derecho.
    public static let clickV2: [(button: ZwiftButton, action: BridgeAction)] = [
        (.shiftUpRight, .shiftUp),
        (.shiftUpLeft, .shiftDown),
        (.z, .shiftUp),
        (.y, .shiftDown),
        (.up, .up),
        (.down, .down),
        (.left, .left),
        (.right, .right),
        (.a, .select),
        (.b, .back),
    ]

    /// Nombre del botón físico, para la tabla de la pantalla.
    public static func buttonLabel(_ button: ZwiftButton) -> String {
        switch button {
        case .shiftUpRight: "+ (dcha)"
        case .shiftUpLeft: "− (izq)"
        case .up: "↑ (izq)"
        case .down: "↓ (izq)"
        case .left: "← (izq)"
        case .right: "→ (izq)"
        default: "\(button.names.joined()) (dcha)"
        }
    }

    /// Acciones que disparan los botones recién pulsados, sin repetir.
    public static func actions(for pressed: ZwiftButton) -> [BridgeAction] {
        var result: [BridgeAction] = []
        for (button, action) in clickV2 where pressed.contains(button) && !result.contains(action) {
            result.append(action)
        }
        return result
    }
}
