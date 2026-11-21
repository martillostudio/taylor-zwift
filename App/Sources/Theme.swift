import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Estilo de la app: el de Apple. Colores del sistema (claro/oscuro automático), tipografía
/// con los estilos de texto del sistema (Dynamic Type) y controles nativos. Solo lo que el
/// sistema no trae (tarjetas, datos grandes, chips) se dibuja aquí, con esos mismos colores.
enum Theme {
    // MARK: Color

    /// Color de acento: el naranja del sistema.
    static let accent = Color.orange
    /// Algo bien hecho, conectado o en objetivo.
    static let positive = Color.green
    static let strava = Color(red: 252 / 255, green: 76 / 255, blue: 2 / 255)
    /// Relleno suave con el acento (lo elegido).
    static let accentFill = Color.orange.opacity(0.16)
    /// Relleno neutro (botones redondos, chips, huecos sin imagen).
    static let neutralFill = Color.secondary.opacity(0.14)

    #if os(macOS)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    #else
    static let background = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let separator = Color(uiColor: .separator)
    #endif

    // MARK: Esquinas

    enum Radius {
        static let extraSmall: CGFloat = 4
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
        static let extraLarge: CGFloat = 22
    }

    // MARK: Tipografía

    /// Los textos usan los estilos del sistema; los números grandes, tamaños fijos en
    /// redondeada (como la app Fitness).
    enum TypeStyle {
        case displayLarge, displayMedium, displaySmall
        case headlineLarge, headlineMedium, headlineSmall
        case titleLarge, titleMedium, titleSmall
        case bodyLarge, bodyMedium, bodySmall
        case labelLarge, labelMedium, labelSmall
    }

    static func font(_ style: TypeStyle, numeric: Bool = false) -> Font {
        let design: Font.Design = numeric ? .rounded : .default
        return switch style {
        case .displayLarge: .system(size: 56, weight: .semibold, design: design)
        case .displayMedium: .system(size: 44, weight: .semibold, design: design)
        case .displaySmall: .system(size: 34, weight: .semibold, design: design)
        case .headlineLarge: .system(.largeTitle, design: design)
        case .headlineMedium: .system(.title, design: design)
        case .headlineSmall: .system(.title2, design: design)
        case .titleLarge: .system(.title3, design: design, weight: .semibold)
        case .titleMedium: .system(.headline, design: design)
        case .titleSmall: .system(.subheadline, design: design, weight: .semibold)
        case .bodyLarge: .system(.body, design: design)
        case .bodyMedium: .system(.callout, design: design)
        case .bodySmall: .system(.footnote, design: design)
        case .labelLarge: .system(.callout, design: design, weight: .medium)
        case .labelMedium: .system(.caption, design: design, weight: .medium)
        case .labelSmall: .system(.caption2, design: design, weight: .medium)
        }
    }
}

// MARK: - Tarjetas

/// Bloque de contenido: fondo de grupo del sistema (como Ajustes o Fitness) o solo contorno.
struct Card<Content: View>: View {
    enum Style { case filled, elevated, outlined }
    var style: Style = .filled
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style == .outlined ? Color.clear : Theme.cardBackground,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(Theme.separator, lineWidth: style == .outlined ? 1 : 0.5)
            }
            .shadow(color: style == .elevated ? Color.black.opacity(0.08) : Color.clear, radius: 4, y: 1)
    }
}

/// Título de un bloque, con una línea de explicación opcional.
struct SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.font(.titleLarge)).foregroundStyle(Color.primary)
            if let subtitle {
                Text(subtitle).font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
            }
        }
    }
}

// MARK: - Botones

/// Botón redondo con un icono (− / + de marchas y vatios). Grande para darle pedaleando.
struct IconButton: View {
    let systemImage: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(CircleButtonStyle())
    }
}

private struct CircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(isEnabled ? 1 : 0.35))
            .background(Theme.neutralFill, in: Circle())
            .overlay(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0)))
            .contentShape(Circle())
    }
}

/// La acción principal de la pantalla (Empezar, Pausa): botón grande del sistema.
struct ActionButton: View {
    let title: String
    let systemImage: String
    var prominent = true
    let action: () -> Void

    var body: some View {
        if prominent {
            Button(title, systemImage: systemImage, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
        } else {
            Button(title, systemImage: systemImage, action: action)
                .buttonStyle(.bordered)
                .controlSize(.extraLarge)
        }
    }
}

// MARK: - Chips

/// Etiqueta pequeña en cápsula (categoría de subida, filtro elegido…).
struct Chip: View {
    let title: String
    var systemImage: String?
    var selected = false
    var dot: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            if selected {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 12))
            }
            Text(title).font(Theme.font(.labelLarge))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .foregroundStyle(selected ? Theme.accent : Color.primary)
        .background(selected ? Theme.accentFill : Theme.neutralFill, in: Capsule())
    }
}

/// Selector de una opción entre pocas: el control segmentado del sistema.
struct SegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String, systemImage: String)]
    @Binding var selection: Value

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.title).tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - Datos

/// Dato grande (valor + unidad) para los paneles.
struct Stat: View {
    let title: String
    let value: String
    var unit = ""
    var size: Theme.TypeStyle = .displaySmall
    var color: Color = Color.primary
    var caption: String?
    var captionColor: Color = Color.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.font(size, numeric: true)).monospacedDigit().foregroundStyle(color)
                if !unit.isEmpty {
                    Text(unit).font(Theme.font(.titleMedium)).foregroundStyle(Color.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if let caption {
                Text(caption).font(Theme.font(.labelMedium)).foregroundStyle(captionColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Navegación

struct Destination: Identifiable {
    let id: String
    let title: String
    let systemImage: String
}
