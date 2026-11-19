import SwiftUI

/// «Taylor Mandos»: usa los Zwift Click V2 como mando de MyWhoosh (u otra app compatible).
///
/// Conecta los dos Click por Bluetooth y reenvía cada pulsación:
/// - por la red, como mando **OpenBikeControl** (lo entiende MyWhoosh en Mac, iPad, iPhone…);
/// - o, en el Mac, como **teclas** (K/I = subir/bajar marcha en MyWhoosh).
@main
struct TaylorMandosApp: App {
    @State private var model = BridgeModel()

    var body: some Scene {
        WindowGroup {
            BridgeView()
                .environment(model)
                .environment(model.hub)
                .environment(model.server)
        }
        #if os(macOS)
        .defaultSize(width: 480, height: 720)
        #endif
    }
}
