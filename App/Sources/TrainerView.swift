import CicloBluetooth
import CicloKit
import SwiftUI

/// Prueba A: conectar al Kickr, ver datos en vivo, cambiar pendiente (SIM) y potencia (ERG).
struct TrainerView: View {
    @Environment(BluetoothHub.self) private var hub
    @State private var grade = 0.0
    @State private var ergWatts = 150

    private var connected: Bool { hub.trainerConnection == .connected }

    var body: some View {
        Form {
            if hub.trainerConnection == .disconnected {
                ScanSection(kind: .trainer, title: "Buscar rodillo")
            }

            Section("Rodillo") {
                LabeledContent("Dispositivo", value: hub.trainerName ?? "—")
                LabeledContent("Estado", value: hub.trainerConnection.description)
                LabeledContent("Control", value: hub.hasControl ? "concedido ✅" : "no")
                LabeledContent("Última respuesta", value: hub.lastControlResult)
                LabeledContent("Último estado", value: hub.lastMachineStatus)
                if hub.trainerConnection != .disconnected {
                    Button("Desconectar", role: .destructive) { hub.disconnectTrainer() }
                }
            }

            Section("En vivo") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Metric(title: "Potencia", value: hub.bikeData.powerWatts.map { "\($0)" }, unit: "W")
                        Metric(title: "Cadencia", value: hub.bikeData.cadenceRpm.map { "\(Int($0))" }, unit: "rpm")
                        Metric(title: "Velocidad",
                               value: hub.bikeData.speedKmh.map { $0.formatted(.number.precision(.fractionLength(1))) },
                               unit: "km/h")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Modo SIM — pendiente") {
                HStack {
                    Slider(value: $grade, in: -10...20, step: 0.5) { editing in
                        if !editing { hub.setGrade(grade) }
                    }
                    Text("\(grade.formatted(.number.precision(.fractionLength(1)))) %")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                HStack {
                    Button("Llano (0 %)") { grade = 0; hub.setGrade(0) }
                    Button("Enviar pendiente") { hub.setGrade(grade) }
                }
                .disabled(!connected)
                Text("La pendiente se envía al soltar el deslizador.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!connected)

            Section("Modo ERG — potencia fija") {
                Stepper("\(ergWatts) W", value: $ergWatts, in: 50...600, step: 10)
                Button("Poner \(ergWatts) W") { hub.setTargetPower(ergWatts) }
            }
            .disabled(!connected)

            Section {
                Button("Pedir control") { hub.requestControl() }
                    .disabled(!connected)
            } footer: {
                Text("Se pide automáticamente al enviar una pendiente o un ERG. Si sale «control no permitido», cierra Zwift, MyWhoosh y la app de Wahoo.")
            }
        }
        .formStyle(.grouped)
    }
}

struct Metric: View {
    let title: String
    let value: String?
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "—").font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
