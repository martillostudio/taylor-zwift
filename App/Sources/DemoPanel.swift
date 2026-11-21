import CicloBluetooth
import CicloKit
import SwiftUI

/// Panel del modo prueba: cuánto empuja el ciclista de mentira (en SIM) y los botones de los Click.
/// En ERG y en los entrenos el ciclista sigue el objetivo; si se pasa mucho del FTP, se cansa y para 20 s.
struct DemoPanel: View {
    @Environment(BluetoothHub.self) private var hub
    @Environment(RideController.self) private var ride

    var body: some View {
        Card(style: .outlined) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    Label("Modo prueba", systemImage: "testtube.2")
                        .font(Theme.font(.titleSmall)).foregroundStyle(Theme.accent)
                    Text("Nada se guarda ni se sube; el FTP no cambia.")
                        .font(Theme.font(.bodySmall)).foregroundStyle(Color.secondary)
                    Spacer()
                    Button("Salir", systemImage: "xmark") { hub.stopDemo() }
                        .buttonStyle(.bordered)
                        .disabled(ride.isRunning)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.l) { effort; speed; buttons }
                    VStack(alignment: .leading, spacing: Space.m) { HStack(spacing: Space.l) { effort; speed }; buttons }
                    VStack(alignment: .leading, spacing: Space.m) { effort; speed; buttons }
                }
            }
        }
    }

    private var effort: some View {
        @Bindable var hub = hub
        return HStack(spacing: Space.s) {
            Text("Esfuerzo en ruta").font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
            Slider(value: $hub.demoEffort, in: 0.4...1.2, step: 0.05)
                .frame(minWidth: 140, maxWidth: 220)
            Text("\(Int((hub.demoEffort * 100).rounded())) % FTP")
                .font(Theme.font(.bodyMedium)).monospacedDigit()
                .frame(width: 76, alignment: .leading)
        }
    }

    /// El tiempo acelerado: un entreno de 60' en 6' (×10) o en 2' (×30).
    private var speed: some View {
        @Bindable var hub = hub
        return Picker("Tiempo", selection: $hub.timeScale) {
            Text("×1").tag(1.0)
            Text("×10").tag(10.0)
            Text("×30").tag(30.0)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Acelera el tiempo para recorrer un entreno entero en pocos minutos")
    }

    private var buttons: some View {
        HStack(spacing: Space.s) {
            press("−", .shiftUpLeft, help: "Mando izquierdo: más blanda / menos vatios")
            press("+", .shiftUpRight, help: "Mando derecho: más dura / más vatios")
            press("↑", .up, help: "Cruceta: más pendiente en un tramo libre")
            press("↓", .down, help: "Cruceta: menos pendiente en un tramo libre")
            press("A", .a, help: "Empezar / pausar")
            press("B", .b, help: "Dos veces seguidas: terminar y guardar")
        }
    }

    private func press(_ title: String, _ button: ZwiftButton, help: String) -> some View {
        Button(title) { hub.demoPress(button, label: title) }
            .buttonStyle(.bordered)
            .font(Theme.font(.titleSmall).monospacedDigit())
            .help(help)
    }
}
