import CicloBluetooth
import SwiftUI

/// Botón de escanear + lista de dispositivos de un tipo, con botón de conectar.
struct ScanSection: View {
    @Environment(BluetoothHub.self) private var hub
    let kind: DeviceKind
    let title: String

    @State private var showAll = false

    private var visible: [DiscoveredDevice] {
        hub.devices
            .filter { showAll || $0.kind == kind }
            .sorted { $0.rssi > $1.rssi }
    }

    var body: some View {
        Section {
            HStack {
                Text("Bluetooth: \(hub.bluetoothState)")
                    .foregroundStyle(.secondary)
                Spacer()
                if hub.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Parar") { hub.stopScan() }
                } else {
                    Button("Buscar") { hub.startScan() }
                }
            }
            Toggle("Mostrar todos los dispositivos", isOn: $showAll)

            if visible.isEmpty {
                Text(hub.isScanning ? "Buscando…" : "Pulsa «Buscar».")
                    .foregroundStyle(.secondary)
            }
            ForEach(visible) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text("\(device.kind.rawValue) · RSSI \(device.rssi)"
                             + (device.advertisedServices.isEmpty ? "" : " · \(device.advertisedServices.joined(separator: ", "))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Conectar") { hub.connect(device) }
                }
            }
        } header: {
            Text(title)
        }
    }
}
