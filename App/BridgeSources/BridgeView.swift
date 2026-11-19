import CicloBluetooth
import CicloKit
import CicloNetwork
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct BridgeView: View {
    @Environment(BridgeModel.self) private var model
    @Environment(BluetoothHub.self) private var hub
    @Environment(OpenBikeControlServer.self) private var server
    @State private var showLog = false

    var body: some View {
        @Bindable var model = model
        Form {
            // Lo importante, en grande.
            Section {
                VStack(spacing: 6) {
                    Text(model.lastActions.isEmpty ? "—" : model.lastActions.map(\.label).joined(separator: " + "))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.actionCount)
                    Text("\(model.actionCount) pulsaciones").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                if hub.clicks.isEmpty {
                    Label("Buscando mandos… pulsa un botón de cada Click para despertarlos",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                }
                ForEach(hub.clicks) { click in
                    LabeledContent {
                        Text(clickStatus(click))
                    } label: {
                        Label(click.label, systemImage: click.connection == .connected ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(click.connection == .connected ? .green : .secondary)
                    }
                }
            } header: {
                Text("Mandos")
            } footer: {
                Text("Bluetooth: \(hub.bluetoothState). Se conectan y reconectan solos. Cierra Zwift y la otra app de mandos para que no te los «quiten».")
            }

            Section {
                Toggle("Red (OpenBikeControl)", isOn: $model.networkEnabled)
                if model.networkEnabled {
                    LabeledContent("Estado", value: server.state)
                    if server.clients.isEmpty {
                        Text("Ninguna app conectada todavía.").foregroundStyle(.secondary)
                    }
                    ForEach(server.clients) { client in
                        LabeledContent(client.appName ?? "App", value: client.ready ? "conectada ✅" : "conectando…")
                    }
                }
            } header: {
                Text("Salida hacia MyWhoosh")
            } footer: {
                Text("En MyWhoosh: pantalla de conexión → icono de OpenBikeControl (arriba a la derecha) → «Taylor Mandos». MyWhoosh y esta app tienen que estar en la misma wifi.")
            }

            #if os(macOS)
            Section {
                Toggle("Teclado (K / I)", isOn: $model.keyboardEnabled)
                if model.keyboardEnabled {
                    LabeledContent("Permiso de Accesibilidad",
                                   value: model.keyboard.isTrusted ? "concedido ✅" : "falta ⚠️")
                    if !model.keyboard.isTrusted {
                        Button("Dar permiso…") { model.keyboard.requestPermissionIfNeeded() }
                        Button("Ya lo he dado, comprobar") { model.keyboard.refresh() }
                    }
                }
            } footer: {
                Text("Plan B si la red no funciona: MyWhoosh tiene que estar en este Mac y en primer plano. Usa solo una salida a la vez, o cada pulsación cambiará dos marchas.")
            }
            #endif

            Section("Botones") {
                ForEach(BridgeMapping.clickV2, id: \.button.rawValue) { item in
                    LabeledContent(BridgeMapping.buttonLabel(item.button), value: item.action.label)
                }
            }

            Section {
                DisclosureGroup("Log (\(hub.log.count) líneas)", isExpanded: $showLog) {
                    Button("Copiar todo", systemImage: "doc.on.doc") { copy(hub.logText) }
                    ForEach(hub.log.suffix(150).reversed()) { entry in
                        Text("\(entry.date, format: .dateTime.hour().minute().second())  \(entry.text)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.keyboard.refresh()
        }
        #endif
    }

    private func clickStatus(_ click: ClickState) -> String {
        var parts = [click.connection.description]
        if let battery = click.batteryPercent { parts.append("🔋 \(battery) %") }
        return parts.joined(separator: " · ")
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
