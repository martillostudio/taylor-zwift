import CoreLocation
import Foundation
import Observation

/// Dónde estás, para que el cielo del simulador siga al sol de verdad. Se pide una vez (con
/// precisión reducida) y se recuerda; si no das permiso, se usa la ubicación de la ruta.
@MainActor
@Observable
final class SceneLocation: NSObject, CLLocationManagerDelegate {
    struct Coordinate: Equatable { var latitude: Double; var longitude: Double }

    private(set) var coordinate: Coordinate? = {
        let d = UserDefaults.standard
        guard d.object(forKey: "ubicacionLat") != nil else { return nil }
        return Coordinate(latitude: d.double(forKey: "ubicacionLat"), longitude: d.double(forKey: "ubicacionLon"))
    }()

    @ObservationIgnored private var manager: CLLocationManager?

    func request() {
        guard manager == nil else { return }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyReduced
        manager = m
        switch m.authorizationStatus {
        case .notDetermined: m.requestWhenInUseAuthorization()
        case .denied, .restricted: break
        default: m.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if status == .authorizedAlways || status == .authorizedWhenInUse_compat { self.manager?.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let c = Coordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
        MainActor.assumeIsolated {
            coordinate = c
            UserDefaults.standard.set(c.latitude, forKey: "ubicacionLat")
            UserDefaults.standard.set(c.longitude, forKey: "ubicacionLon")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension CLAuthorizationStatus {
    /// `.authorizedWhenInUse` no existe en macOS antes de la 11; así vale en las dos plataformas.
    static var authorizedWhenInUse_compat: CLAuthorizationStatus {
        #if os(macOS)
        .authorized
        #else
        .authorizedWhenInUse
        #endif
    }
}
