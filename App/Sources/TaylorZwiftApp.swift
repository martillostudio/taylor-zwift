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
    @Environment(RideController.self) private var ride

    var body: some View {
        @Bindable var ride = ride
        TabView(selection: $ride.selectedTab) {
            RideView()
                .tabItem { Label("Rodar", systemImage: "figure.outdoor.cycle") }
                .tag("rodar")
            WorkoutsView()
                .tabItem { Label("Entrenar", systemImage: "figure.indoor.cycle") }
                .tag("entrenar")
            TrainerView()
                .tabItem { Label("Rodillo", systemImage: "bicycle") }
                .tag("rodillo")
            ControllersView()
                .tabItem { Label("Mandos", systemImage: "gamecontroller") }
                .tag("mandos")
            LogView()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
                .tag("log")
        }
    }
}
