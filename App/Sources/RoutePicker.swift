import CicloKit
import MapKit
import SwiftUI

/// Tus rutas en tarjetas (3×3 por página): mapa, nombre, km, desnivel y año.
/// Al tocar una tarjeta, esa es la ruta que vas a rodar.
struct RoutePicker: View {
    @Environment(RideController.self) private var ride
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    var onImport: () -> Void

    enum Order: String, CaseIterable, Identifiable {
        case recent = "Recientes", gentle = "Más suaves", short = "Más cortas"
        var id: String { rawValue }
    }

    @AppStorage("ordenRutas") private var order: Order = .recent
    @State private var page = 0
    @State private var toDelete: Route?

    static let perPage = 9

    private var columnCount: Int {
        #if os(iOS)
        if sizeClass == .compact { return 1 }
        #endif
        return 3
    }

    private var sorted: [Route] {
        let all = ride.importedRoutes
        switch order {
        case .recent: return all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .gentle: return all.sorted { $0.climbPerKm < $1.climbPerKm }
        case .short: return all.sorted { $0.lengthMeters < $1.lengthMeters }
        }
    }

    var body: some View {
        let routes = sorted
        let pages = max(1, Int((Double(routes.count) / Double(Self.perPage)).rounded(.up)))
        let current = min(page, pages - 1)
        let shown = Array(routes.dropFirst(current * Self.perPage).prefix(Self.perPage))

        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .center, spacing: Space.m) {
                SectionTitle(title: "Tus rutas",
                               subtitle: routes.isEmpty ? "Importa un GPX para empezar"
                                   : "\(routes.count) rutas · toca una para rodarla")
                Spacer()
                if routes.count > 1 {
                    Picker("Orden", selection: $order) {
                        ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Button("Importar GPX", systemImage: "square.and.arrow.down", action: onImport)
                    .buttonStyle(.bordered)
                    .help("Importar una ruta GPX (de Garmin Connect, Strava, Komoot…)")
            }

            if routes.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.m, alignment: .top),
                                         count: columnCount),
                          alignment: .leading, spacing: Space.m) {
                    ForEach(shown) { r in
                        Button { ride.route = r } label: {
                            RouteTile(route: r, selected: r.id == ride.route.id)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Borrar «\(r.name)»", systemImage: "trash", role: .destructive) { toDelete = r }
                        }
                    }
                }
                if pages > 1 { pager(current: current, pages: pages) }
            }
        }
        .onChange(of: order) { page = 0 }
        .confirmationDialog("¿Borrar «\(toDelete?.name ?? "")»?", isPresented: Binding(
            get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Borrar", role: .destructive) {
                if let r = toDelete { ride.deleteRoute(r) }
                toDelete = nil
            }
        } message: {
            Text("Se borra de la app. El GPX original no se toca.")
        }
    }

    private func pager(current: Int, pages: Int) -> some View {
        HStack(spacing: Space.m) {
            Spacer()
            IconButton(systemImage: "chevron.left") { page = max(current - 1, 0) }
                .disabled(current == 0)
                .opacity(current == 0 ? 0.4 : 1)
                .accessibilityLabel("Página anterior")
            Text("Página \(current + 1) de \(pages)")
                .font(Theme.font(.labelLarge, numeric: true)).foregroundStyle(Color.secondary)
            IconButton(systemImage: "chevron.right") { page = min(current + 1, pages - 1) }
                .disabled(current == pages - 1)
                .opacity(current == pages - 1 ? 0.4 : 1)
                .accessibilityLabel("Página siguiente")
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Image(systemName: "map").font(.title).foregroundStyle(Theme.accent)
            Text("Aún no tienes rutas").font(Theme.font(.titleMedium))
            Text("Importa un GPX con altura: un recorrido de Garmin Connect, Strava, Komoot o Wikiloc. Lo rodarás con su pendiente real.")
                .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }
}

/// Una tarjeta de ruta: mapa con el recorrido y, debajo, nombre, km, desnivel y año.
struct RouteTile: View {
    let route: Route
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let track = route.track {
                    RouteMapPreview(track: track)
                } else {
                    Rectangle().fill(Theme.cardBackground)
                }
            }
            .frame(height: 140)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if selected {
                    Label("Elegida", systemImage: "checkmark")
                        .font(Theme.font(.labelMedium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                        .background(Theme.accentFill, in: Capsule())
                        .padding(Space.s)
                }
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(route.name)
                    .font(Theme.font(.titleSmall))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: Space.m) {
                    stat("ruler", "\(km(route.lengthMeters)) km")
                    stat("arrow.up.right", "+\(Int(route.climbMeters.rounded())) m")
                    if let date = route.date {
                        stat("calendar", date.formatted(.dateTime.year()))
                    }
                }
            }
            .padding(Space.m)
        }
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(selected ? Theme.accent : Theme.separator, lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(Theme.font(.labelLarge, numeric: true))
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
    }

    private func km(_ m: Double) -> String {
        (m / 1000).formatted(.number.precision(.fractionLength(1)))
    }
}

/// Mapa pequeño y quieto con el recorrido (sin tocarlo: la tarjeta entera es el botón).
struct RouteMapPreview: View {
    let track: RouteTrack

    var body: some View {
        Map(initialPosition: .rect(boundingRect), interactionModes: []) {
            MapPolyline(coordinates: track.points.map(\.coordinate))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
    }

    /// El recorrido con un 20 % de margen alrededor.
    private var boundingRect: MKMapRect {
        let pts = track.points.map { MKMapPoint($0.coordinate) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        return MKMapRect(x: minX - w * 0.2, y: minY - h * 0.2, width: w * 1.4, height: h * 1.4)
    }
}
