import CicloBluetooth
import SwiftUI

@main
struct TaylorZwiftApp: App {
    @State private var hub = BluetoothHub()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(hub)
        }
        #if os(macOS)
        .defaultSize(width: 720, height: 640)
        #endif
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            TrainerView()
                .tabItem { Label("Rodillo", systemImage: "bicycle") }
            ControllersView()
                .tabItem { Label("Mandos", systemImage: "gamecontroller") }
            LogView()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
        }
    }
}
