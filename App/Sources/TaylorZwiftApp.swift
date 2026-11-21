import CicloBluetooth
import SwiftUI

@main
struct TaylorZwiftApp: App {
    @State private var hub: BluetoothHub
    @State private var store: ActivityStore
    @State private var strava: StravaService
    @State private var intervals: IntervalsService
    @State private var ride: RideController

    init() {
        // La app está escrita en castellano: fechas, días y números en español aunque el Mac
        // esté en otro idioma (es lo mismo que elegir el idioma de la app en Ajustes).
        UserDefaults.standard.set(["es-ES"], forKey: "AppleLanguages")
        let hub = BluetoothHub()
        let store = ActivityStore()
        let strava = StravaService()
        let intervals = IntervalsService()
        _intervals = State(initialValue: intervals)
        _hub = State(initialValue: hub)
        _store = State(initialValue: store)
        _strava = State(initialValue: strava)
        _ride = State(initialValue: RideController(hub: hub, store: store, strava: strava, intervals: intervals))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(hub)
                .environment(store)
                .environment(strava)
                .environment(intervals)
                .environment(ride)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 880)
        #endif
    }
}

struct ContentView: View {
    @Environment(RideController.self) private var ride

    private let destinations = [
        Destination(id: "rodar", title: "Rodar", systemImage: "figure.outdoor.cycle"),
        Destination(id: "entrenar", title: "Entrenar", systemImage: "figure.indoor.cycle"),
        Destination(id: "historial", title: "Historial", systemImage: "clock.arrow.circlepath"),
        Destination(id: "equipo", title: "Equipo", systemImage: "sensor.tag.radiowaves.forward"),
        Destination(id: "log", title: "Log", systemImage: "list.bullet.rectangle"),
    ]

    var body: some View {
        // El simulador 2D ocupa toda la ventana (también la barra lateral) y sustituye a las
        // pantallas: así el mapa y las gráficas de Rodar no se repintan detrás.
        Group {
            if ride.showScene { RideScene().transition(.opacity) } else { navigation }
        }
            .animation(.easeInOut(duration: 0.25), value: ride.showScene)
            .tint(Theme.accent)
            .overlay(alignment: .top) {
                if let notice = ride.notice {
                    Text(notice)
                        .font(Theme.font(.titleMedium))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                        .padding(.top, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.spring(duration: 0.3), value: ride.notice)
    }

    /// Mac e iPad: barra lateral del sistema. iPhone: pestañas abajo.
    @ViewBuilder
    private var navigation: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { tabs } else { sidebar }
        #else
        sidebar
        #endif
    }

    private var sidebar: some View {
        @Bindable var ride = ride
        return NavigationSplitView {
            List(selection: Binding<String?>(get: { ride.selectedTab }, set: { if let id = $0 { ride.selectedTab = id } })) {
                ForEach(destinations) { d in
                    Label(d.title, systemImage: d.systemImage).tag(d.id)
                }
            }
            .navigationTitle("Taylor Zwift")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            screen(ride.selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    #if os(iOS)
    private var tabs: some View {
        @Bindable var ride = ride
        return TabView(selection: $ride.selectedTab) {
            ForEach(destinations) { d in
                screen(d.id)
                    .tabItem { Label(d.title, systemImage: d.systemImage) }
                    .tag(d.id)
            }
        }
    }
    #endif

    @ViewBuilder
    private func screen(_ id: String) -> some View {
        switch id {
        case "entrenar": WorkoutsView()
        case "historial": HistoryView()
        case "equipo": DevicesView()
        case "log": LogView()
        default: RideView()
        }
    }
}
