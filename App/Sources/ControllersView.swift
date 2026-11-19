import CicloBluetooth
import CicloKit
import SwiftUI

/// Prueba B: encontrar los Zwift Click V2, saludar con «RideOn» y ver qué botón pulsas.
struct ControllersView: View {
    @Environment(BluetoothHub.self) private var hub

    var body: some View {
        Form {
            ScanSection(kind: .click, title: "Buscar mandos")

            if !hub.clicks.isEmpty {
                Section {
                    LabeledContent("Pulsado ahora",
                                   value: hub.buttonsPressed.names.isEmpty ? "—" : hub.buttonsPressed.names.joined(separator: " + "))
                    LabeledContent("Último botón") {
                        Text(hub.lastButtonNames.isEmpty ? "—" : hub.lastButtonNames.joined(separator: " + "))
                            .font(.title2.bold())
                    }
                    LabeledContent("Pulsaciones", value: "\(hub.buttonPressCount)")
                } header: {
                    Text("Botones (todos los mandos)")
                } footer: {
                    Text("Cada pulsación cuenta una vez aunque llegue por los dos mandos.")
                }
            }

            ForEach(hub.clicks) { click in
                Section(click.label) {
                    LabeledContent("Estado", value: click.connection.description)
                    LabeledContent("Saludo RideOn", value: click.handshakeDone ? "hecho ✅" : "pendiente")
                    LabeledContent("Batería", value: click.batteryPercent.map { "\($0) %" } ?? "—")
                    LabeledContent("Pulsado según este mando",
                                   value: click.pressed.names.isEmpty ? "—" : click.pressed.names.joined(separator: " + "))
                    LabeledContent("Mapa en bruto",
                                   value: click.rawMap.map { "0x" + String($0, radix: 16, uppercase: true) } ?? "—")
                    if click.connection != .disconnected {
                        Button("Desconectar", role: .destructive) { hub.disconnect(click.id) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
