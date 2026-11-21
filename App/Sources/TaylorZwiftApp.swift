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
        M3Destination(id: "rodar", title: "Rodar", systemImage: "figure.outdoor.cycle"),
        M3Destination(id: "entrenar", title: "Entrenar", systemImage: "figure.indoor.cycle"),
        M3Destination(id: "historial", title: "Historial", systemImage: "clock.arrow.circlepath"),
        M3Destination(id: "equipo", title: "Equipo", systemImage: "sensor.tag.radiowaves.forward"),
        M3Destination(id: "log", title: "Log", systemImage: "list.bullet.rectangle"),
    ]

    var body: some View {
        @Bindable var ride = ride
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                VStack(spacing: 0) {
                    screen
                    M3NavigationBar(destinations: destinations, selection: $ride.selectedTab)
                }
            } else {
                rail
            }
            #else
            rail
            #endif
        }
        .background(M3.surface)
        .tint(M3.primary)
        .overlay(alignment: .top) {
            if let notice = ride.notice {
                Text(notice)
                    .font(M3.font(.titleMedium))
                    .foregroundStyle(M3.onSurface)
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

    private var rail: some View {
        @Bindable var ride = ride
        return HStack(spacing: 0) {
            M3NavigationRail(destinations: destinations, selection: $ride.selectedTab)
            Divider()
            screen.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch ride.selectedTab {
        case "entrenar": WorkoutsView()
        case "historial": HistoryView()
        case "equipo": DevicesView()
        case "log": LogView()
        default: RideView()
        }
    }
}
