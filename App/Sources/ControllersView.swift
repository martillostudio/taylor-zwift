import CicloBluetooth
import CicloKit
import SwiftUI

/// Prueba B: encontrar los Zwift Click V2, saludar con «RideOn» y ver qué botón pulsas.
struct ControllersView: View {
    @Environment(BluetoothHub.self) private var hub

    var body: some View {
        Form {
            ScanSection(kind: .click, title: "Buscar mandos")

            ForEach(hub.clicks) { click in
                Section(click.name) {
                    LabeledContent("Estado", value: click.connection.description)
                    LabeledContent("Saludo RideOn", value: click.handshakeDone ? "hecho ✅" : "pendiente")
                    LabeledContent("Pulsado ahora",
                                   value: click.pressed.names.isEmpty ? "—" : click.pressed.names.joined(separator: " + "))
                    LabeledContent("Último botón") {
                        Text(click.lastPressedNames.isEmpty ? "—" : click.lastPressedNames.joined(separator: " + "))
                            .font(.title2.bold())
                    }
                    LabeledContent("Pulsaciones", value: "\(click.pressCount)")
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
