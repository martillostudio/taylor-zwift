/// Junta los botones que llegan de varios mandos en un solo estado, sin contar dos veces.
///
/// Con los dos Click V2 conectados, el izquierdo reenvía los botones del derecho:
/// la misma pulsación llega por los dos mandos con 30–150 ms de diferencia, a veces
/// primero por uno y a veces por el otro. Si el reenvío llega cuando ya has soltado
/// el botón, comparar solo «pulsado/suelto» no basta para detectar el eco.
///
/// Regla: cada botón tiene un mando «dueño». Lo que manda el dueño siempre cuenta.
/// Lo que manda otro mando es un eco si el dueño ha contado ese botón hace menos de
/// `echoWindow` segundos; si no, cuenta y ese mando pasa a ser el dueño.
public struct ZwiftButtonAggregator<Source: Hashable & Sendable>: Sendable {
    /// Retraso máximo que aceptamos entre una pulsación y su eco por el otro mando.
    public var echoWindow: Double

    private var pressedBySource: [Source: ZwiftButton] = [:]
    private var owner: [ZwiftButton: Source] = [:]
    private var lastCounted: [ZwiftButton: Double] = [:]

    public init(echoWindow: Double = 0.4) {
        self.echoWindow = echoWindow
    }

    /// Botones pulsados ahora mismo en cualquiera de los mandos.
    public var pressed: ZwiftButton {
        pressedBySource.values.reduce(into: ZwiftButton()) { $0.formUnion($1) }
    }

    /// Registra el estado que manda `source` en el instante `time` (en segundos).
    /// Devuelve los botones que cuentan como pulsación nueva (vacío si es un eco o una suelta).
    @discardableResult
    public mutating func update(source: Source, pressed newState: ZwiftButton, at time: Double) -> ZwiftButton {
        let newForSource = newState.subtracting(pressedBySource[source] ?? [])
        pressedBySource[source] = newState

        var counted: ZwiftButton = []
        for bit in 0..<32 {
            let button = ZwiftButton(rawValue: 1 << bit)
            guard newForSource.contains(button) else { continue }

            if let current = owner[button], current != source,
               let last = lastCounted[button], time - last < echoWindow {
                continue // eco de una pulsación que ya contó el dueño
            }
            owner[button] = source
            lastCounted[button] = time
            counted.insert(button)
        }
        return counted
    }

    /// Olvida un mando (p. ej. al desconectarse), para que no se quede un botón «atascado».
    public mutating func remove(source: Source) {
        pressedBySource[source] = nil
        for (button, s) in owner where s == source { owner[button] = nil }
    }
}
