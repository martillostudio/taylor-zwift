import CicloBluetooth
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Todo lo que pasa por Bluetooth, para copiarlo y pegárselo a Claude.
struct LogView: View {
    @Environment(BluetoothHub.self) private var hub

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(hub.log.count) líneas").foregroundStyle(.secondary)
                Spacer()
                Button("Copiar todo", systemImage: "doc.on.doc") { copy(hub.logText) }
                Button("Borrar", systemImage: "trash") { hub.clearLog() }
            }
            .padding()

            ScrollViewReader { proxy in
                List(hub.log) { entry in
                    HStack(alignment: .top) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.secondary)
                        Text(entry.text)
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .id(entry.id)
                }
                .onChange(of: hub.log.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
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
