import CicloBluetooth
import CicloKit
import CicloNetwork
import Foundation
import Observation

#if os(iOS)
import UIKit
#endif

/// Une los mandos (Bluetooth) con las salidas hacia MyWhoosh (red y/o teclado).
@MainActor
@Observable
final class BridgeModel {
    let hub = BluetoothHub()
    let server: OpenBikeControlServer

    /// Salida por red (OpenBikeControl). Recomendada: no necesita permisos ni que MyWhoosh esté delante.
    var networkEnabled: Bool {
        didSet {
            UserDefaults.standard.set(networkEnabled, forKey: "networkEnabled")
            networkEnabled ? server.start() : server.stop()
        }
    }

    /// Salida por teclado (solo Mac): necesita el permiso de Accesibilidad y MyWhoosh en primer plano.
    var keyboardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(keyboardEnabled, forKey: "keyboardEnabled")
            #if os(macOS)
            if keyboardEnabled { keyboard.requestPermissionIfNeeded() }
            #endif
        }
    }

    private(set) var lastActions: [BridgeAction] = []
    private(set) var actionCount = 0

    #if os(macOS)
    let keyboard = KeyboardSender()
    @ObservationIgnored private var activity: NSObjectProtocol?
    #endif

    init() {
        let defaults = UserDefaults.standard
        let deviceID = defaults.string(forKey: "deviceID") ?? {
            let id = UUID().uuidString
            defaults.set(id, forKey: "deviceID")
            return id
        }()
        server = OpenBikeControlServer(deviceName: "Taylor Mandos", deviceID: deviceID)
        networkEnabled = defaults.object(forKey: "networkEnabled") as? Bool ?? true
        keyboardEnabled = defaults.object(forKey: "keyboardEnabled") as? Bool ?? false

        server.onLog = { [hub] text in hub.appendLog(text) }
        hub.onButtonPress = { [weak self] buttons in self?.handle(buttons) }
        hub.startBridgeMode()
        if networkEnabled { server.start() }

        #if os(macOS)
        // Que macOS no «duerma» la app (App Nap) mientras está en segundo plano detrás de MyWhoosh.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Reenviar los mandos a MyWhoosh")
        #else
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    private func handle(_ buttons: ZwiftButton) {
        let actions = BridgeMapping.actions(for: buttons)
        guard !actions.isEmpty else { return }

        // La batería que contamos a MyWhoosh es la del mando más bajo.
        server.batteryPercent = hub.clicks.compactMap(\.batteryPercent).min()

        var outputs: [String] = []
        for action in actions {
            if networkEnabled {
                server.tap(action.openBikeControl)
            }
            #if os(macOS)
            if keyboardEnabled {
                keyboard.tap(action.macKeyCode)
            }
            #endif
        }
        if networkEnabled { outputs.append("red (\(server.readyClientCount) app)") }
        #if os(macOS)
        if keyboardEnabled { outputs.append("teclas \(actions.map(\.keyLabel).joined(separator: " "))") }
        #endif

        lastActions = actions
        actionCount += 1
        let names = actions.map(\.label).joined(separator: " + ")
        hub.appendLog("➡️ \(names) → \(outputs.isEmpty ? "ninguna salida activa" : outputs.joined(separator: ", "))")
    }
}
