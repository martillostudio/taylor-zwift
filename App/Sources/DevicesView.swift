import CicloBluetooth
import SwiftUI

/// «Equipo»: rodillo, mandos y pulsómetro (las pantallas de prueba de la Fase 1, juntas).
struct DevicesView: View {
    @Environment(BluetoothHub.self) private var hub
    @State private var section = "rodillo"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Equipo").font(M3.font(.headlineMedium)).foregroundStyle(M3.onSurface)
                Spacer()
                Button("Conectar todo", systemImage: "antenna.radiowaves.left.and.right") { hub.connectEverything() }
                    .buttonStyle(.m3Tonal)
            }
            M3SegmentedButtons(options: [
                ("rodillo", "Rodillo", "bicycle"),
                ("mandos", "Mandos", "gamecontroller"),
                ("pulso", "Pulsómetro", "heart"),
            ], selection: $section)
            .frame(maxWidth: 520)
            switch section {
            case "mandos": ControllersView()
            case "pulso": HeartRateView()
            default: TrainerView()
            }
        }
        .padding(24)
        .background(M3.surface)
    }
}

private struct HeartRateView: View {
    @Environment(BluetoothHub.self) private var hub

    var body: some View {
        Form {
            Section("Pulsómetro") {
                LabeledContent("Dispositivo", value: hub.heartRateName ?? "—")
                LabeledContent("Estado", value: hub.heartRateConnection.description)
                LabeledContent("Pulso", value: hub.heartRateBpm.map { "\($0) ppm" } ?? "—")
                if hub.heartRateConnection != .disconnected {
                    Button("Desconectar", role: .destructive) { hub.disconnectHeartRate() }
                }
            }
            ScanSection(kind: .heartRate, title: "Buscar pulsómetros (póntelo para que se anuncie)")
        }
        .formStyle(.grouped)
    }
}
