import CicloKit
import MapKit
import SwiftUI

/// Mapa de una ruta GPX: el recorrido, lo que llevas hecho y dónde estás.
/// «Seguirme» centra el mapa en tu posición mientras ruedas; si mueves el mapa, deja de seguirte.
struct RouteMapCard: View {
    let route: Route
    let track: RouteTrack
    let distance: Double
    /// Alto del mapa; `nil` = ocupa todo el sitio que le den (al lado del perfil).
    var mapHeight: CGFloat? = 320
    /// Empieza siguiéndote (mientras ruedas, lo normal es querer verte).
    var followsOnAppear = false

    @State private var camera: MapCameraPosition = .automatic
    @State private var following = false

    var body: some View {
        let here = route.mapPosition(atDistance: distance)
        M3Card(style: .filled) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("MAPA").font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
                    Spacer()
                    Button(following ? "Siguiéndote" : "Seguirme",
                           systemImage: following ? "location.fill" : "location") {
                        following.toggle()
                        if following { follow(here?.point) } else { camera = .automatic }
                    }
                    .buttonStyle(.m3Text)
                    .help("Centrar el mapa en tu posición mientras ruedas")
                }
                Map(position: $camera, interactionModes: [.pan, .zoom]) {
                    MapPolyline(coordinates: track.points.map(\.coordinate))
                        .stroke(M3.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    if let here, here.trackMeters > 0 {
                        MapPolyline(coordinates: track.points(upTo: here.trackMeters).map(\.coordinate))
                            .stroke(M3.outline, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                    Annotation("Salida", coordinate: track.points[0].coordinate, anchor: .center) {
                        endpoint("flag.fill", M3.tertiary)
                    }
                    Annotation("Llegada", coordinate: track.points[track.points.count - 1].coordinate, anchor: .center) {
                        endpoint("flag.checkered", M3.onSurface)
                    }
                    if let here {
                        Annotation("Tú", coordinate: here.point.coordinate, anchor: .center) {
                            Circle()
                                .fill(M3.primary)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                                .shadow(color: .black.opacity(0.3), radius: 3)
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
                .mapControls { MapScaleView() }
                .frame(minHeight: mapHeight ?? 200, maxHeight: mapHeight ?? .infinity)
                .clipShape(RoundedRectangle(cornerRadius: M3.Shape.medium))
                .onMapCameraChange(frequency: .onEnd) { context in
                    // Si lo mueves tú (y no estamos siguiéndote a ti), se deja de seguir.
                    if following, let here, !isNear(context.region.center, here.point) { following = false }
                }
                .onChange(of: Int(distance / 20)) { // cada 20 m, no en cada muestra
                    if following { follow(route.mapPosition(atDistance: distance)?.point) }
                }
                .onAppear {
                    if followsOnAppear, !following {
                        following = true
                        follow(here?.point)
                    }
                }
                .onChange(of: route.id) {
                    following = false
                    camera = .automatic
                }
            }
        }
    }

    private func follow(_ point: GeoPoint?) {
        guard let point else { return }
        withAnimation(.easeInOut(duration: 0.8)) {
            camera = .camera(MapCamera(centerCoordinate: point.coordinate, distance: 2_500))
        }
    }

    /// Dentro de ~300 m.
    private func isNear(_ c: CLLocationCoordinate2D, _ p: GeoPoint) -> Bool {
        abs(c.latitude - p.latitude) < 0.003 && abs(c.longitude - p.longitude) < 0.004
    }

    private func endpoint(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
    }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
