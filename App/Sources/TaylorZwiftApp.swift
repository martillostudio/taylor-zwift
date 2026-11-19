import CicloBluetooth
import SwiftUI

@main
struct TaylorZwiftApp: App {
    @State private var hub: BluetoothHub
    @State private var ride: RideController

    init() {
        let hub = BluetoothHub()
        _hub = State(initialValue: hub)
        _ride = State(initialValue: RideController(hub: hub))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(hub)
                .environment(ride)
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 820)
        #endif
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            RideView()
                .tabItem { Label("Rodar", systemImage: "figure.outdoor.cycle") }
            WorkoutsView()
                .tabItem { Label("Entrenar", systemImage: "figure.indoor.cycle") }
            TrainerView()
                .tabItem { Label("Rodillo", systemImage: "bicycle") }
            ControllersView()
                .tabItem { Label("Mandos", systemImage: "gamecontroller") }
            LogView()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
        }
    }
}
