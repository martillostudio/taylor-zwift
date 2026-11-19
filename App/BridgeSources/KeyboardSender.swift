#if os(macOS)
import ApplicationServices
import CoreGraphics
import Observation

/// Simula pulsaciones de teclado en el Mac (van a la app que esté en primer plano).
/// macOS solo lo permite si la app tiene el permiso de **Accesibilidad**.
@MainActor
@Observable
final class KeyboardSender {
    private(set) var isTrusted = AXIsProcessTrusted()

    /// Comprueba el permiso y, si falta, abre el aviso de macOS para darlo.
    func requestPermissionIfNeeded() {
        // "AXTrustedCheckOptionPrompt" = kAXTrustedCheckOptionPrompt (la constante no es apta para Swift 6).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    func tap(_ keyCode: UInt16) {
        refresh()
        guard isTrusted else { return }
        post(keyCode, down: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            post(keyCode, down: false)
        }
    }

    private func post(_ keyCode: UInt16, down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)?
            .post(tap: .cghidEventTap)
    }
}
#endif
