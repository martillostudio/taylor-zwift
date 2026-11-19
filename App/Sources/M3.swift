import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Sistema de diseño Material 3 hecho en SwiftUI (sin la librería material-components-ios,
/// que está archivada). Colores, tipografía, formas y componentes según m3.material.io,
/// con un naranja deportivo como color base.
enum M3 {
    // MARK: Color (roles de M3, claro / oscuro)

    static let primary = Color(light: 0x9A4600, dark: 0xFFB68B)
    static let onPrimary = Color(light: 0xFFFFFF, dark: 0x532200)
    static let primaryContainer = Color(light: 0xFFDBC8, dark: 0x763300)
    static let onPrimaryContainer = Color(light: 0x321200, dark: 0xFFDBC8)
    static let secondary = Color(light: 0x765848, dark: 0xE6BEAB)
    static let secondaryContainer = Color(light: 0xFFDBC8, dark: 0x5C4132)
    static let onSecondaryContainer = Color(light: 0x2B160A, dark: 0xFFDBC8)
    static let tertiary = Color(light: 0x006A60, dark: 0x53DBC9)
    static let tertiaryContainer = Color(light: 0x74F8E5, dark: 0x005048)
    static let onTertiaryContainer = Color(light: 0x00201C, dark: 0x74F8E5)
    static let error = Color(light: 0xBA1A1A, dark: 0xFFB4AB)
    static let surface = Color(light: 0xFFF8F5, dark: 0x1A120D)
    static let surfaceContainerLowest = Color(light: 0xFFFFFF, dark: 0x140C08)
    static let surfaceContainerLow = Color(light: 0xFFF1EA, dark: 0x221A15)
    static let surfaceContainer = Color(light: 0xFCEAE2, dark: 0x271E19)
    static let surfaceContainerHigh = Color(light: 0xF6E5DC, dark: 0x322823)
    static let surfaceContainerHighest = Color(light: 0xF0DFD7, dark: 0x3D332D)
    static let onSurface = Color(light: 0x221A15, dark: 0xF0DFD7)
    static let onSurfaceVariant = Color(light: 0x52443C, dark: 0xD7C2B8)
    static let outline = Color(light: 0x85746B, dark: 0xA08D84)
    static let outlineVariant = Color(light: 0xD7C2B8, dark: 0x52443C)
    static let strava = Color(light: 0xFC4C02, dark: 0xFC4C02)

    // MARK: Formas

    enum Shape {
        static let extraSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 28
    }

    // MARK: Tipografía (escala de M3; los números, redondeados y monoespaciados)

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
        case .displayLarge: .system(size: 57, weight: .regular, design: design)
        case .displayMedium: .system(size: 45, weight: .regular, design: design)
        case .displaySmall: .system(size: 36, weight: .regular, design: design)
        case .headlineLarge: .system(size: 32, weight: .regular, design: design)
        case .headlineMedium: .system(size: 28, weight: .regular, design: design)
        case .headlineSmall: .system(size: 24, weight: .regular, design: design)
        case .titleLarge: .system(size: 22, weight: .regular, design: design)
        case .titleMedium: .system(size: 16, weight: .medium, design: design)
        case .titleSmall: .system(size: 14, weight: .medium, design: design)
        case .bodyLarge: .system(size: 16, weight: .regular, design: design)
        case .bodyMedium: .system(size: 14, weight: .regular, design: design)
        case .bodySmall: .system(size: 12, weight: .regular, design: design)
        case .labelLarge: .system(size: 14, weight: .medium, design: design)
        case .labelMedium: .system(size: 12, weight: .medium, design: design)
        case .labelSmall: .system(size: 11, weight: .medium, design: design)
        }
    }
}

extension Color {
    /// Color que cambia entre modo claro y oscuro (valores hexadecimales 0xRRGGBB).
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

#if os(macOS)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

// MARK: - Tarjetas

/// Tarjeta de M3: rellena (por defecto), elevada o con contorno.
struct M3Card<Content: View>: View {
    enum Style { case filled, elevated, outlined }
    var style: Style = .filled
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: M3.Shape.medium))
            .overlay {
                if style == .outlined {
                    RoundedRectangle(cornerRadius: M3.Shape.medium).strokeBorder(M3.outlineVariant)
                }
            }
            .shadow(color: style == .elevated ? Color.black.opacity(0.12) : Color.clear, radius: 3, y: 1)
    }

    private var background: Color {
        switch style {
        case .filled: M3.surfaceContainerHighest
        case .elevated: M3.surfaceContainerLow
        case .outlined: M3.surface
        }
    }
}

/// Título de sección con el estilo de M3.
struct M3SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(M3.font(.titleLarge)).foregroundStyle(M3.onSurface)
            if let subtitle {
                Text(subtitle).font(M3.font(.bodyMedium)).foregroundStyle(M3.onSurfaceVariant)
            }
        }
    }
}

// MARK: - Botones

struct M3ButtonStyle: ButtonStyle {
    enum Kind { case filled, tonal, outlined, text }
    var kind: Kind = .filled
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(M3.font(.labelLarge))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, kind == .text ? 12 : 24)
            .frame(minHeight: 40)
            .foregroundStyle(foreground.opacity(isEnabled ? 1 : 0.38))
            .background(background.opacity(isEnabled ? 1 : 0.12), in: Capsule())
            .overlay {
                if kind == .outlined { Capsule().strokeBorder(M3.outline.opacity(isEnabled ? 1 : 0.12)) }
            }
            .overlay { Capsule().fill(M3.onSurface.opacity(configuration.isPressed ? 0.12 : 0)) }
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .filled: M3.onPrimary
        case .tonal: M3.onSecondaryContainer
        case .outlined, .text: M3.primary
        }
    }

    private var background: Color {
        switch kind {
        case .filled: M3.primary
        case .tonal: M3.secondaryContainer
        case .outlined, .text: .clear
        }
    }
}

extension ButtonStyle where Self == M3ButtonStyle {
    static var m3Filled: M3ButtonStyle { M3ButtonStyle(kind: .filled) }
    static var m3Tonal: M3ButtonStyle { M3ButtonStyle(kind: .tonal) }
    static var m3Outlined: M3ButtonStyle { M3ButtonStyle(kind: .outlined) }
    static var m3Text: M3ButtonStyle { M3ButtonStyle(kind: .text) }
}

/// Botón de icono redondo (M3 «icon button», tonal).
struct M3IconButton: View {
    let systemImage: String
    var size: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(M3.onSecondaryContainer)
                .background(M3.secondaryContainer, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Botón flotante extendido (M3 «extended FAB»).
struct M3FAB: View {
    let title: String
    let systemImage: String
    var tone: Color = M3.primaryContainer
    var onTone: Color = M3.onPrimaryContainer
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(M3.font(.labelLarge))
                .padding(.horizontal, 20)
                .frame(height: 56)
                .foregroundStyle(onTone.opacity(isEnabled ? 1 : 0.38))
                .background(tone.opacity(isEnabled ? 1 : 0.3), in: RoundedRectangle(cornerRadius: M3.Shape.large))
                .shadow(color: .black.opacity(isEnabled ? 0.18 : 0), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chips

/// Chip de M3 (asistente o de filtro).
struct M3Chip: View {
    let title: String
    var systemImage: String?
    var selected = false
    var dot: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            if selected {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 13))
            }
            Text(title).font(M3.font(.labelLarge))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .foregroundStyle(selected ? M3.onSecondaryContainer : M3.onSurfaceVariant)
        .background(selected ? M3.secondaryContainer : Color.clear, in: RoundedRectangle(cornerRadius: M3.Shape.small))
        .overlay {
            if !selected { RoundedRectangle(cornerRadius: M3.Shape.small).strokeBorder(M3.outlineVariant) }
        }
    }
}

/// Botones segmentados de M3 (selección única).
struct M3SegmentedButtons<Value: Hashable>: View {
    let options: [(value: Value, title: String, systemImage: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selected ? "checkmark" : option.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                        Text(option.title).font(M3.font(.labelLarge))
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(selected ? M3.onSecondaryContainer : M3.onSurface)
                    .background(selected ? M3.secondaryContainer : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < options.count - 1 {
                    Rectangle().fill(M3.outline).frame(width: 1, height: 40)
                }
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(M3.outline))
    }
}

// MARK: - Datos

/// Dato grande (valor + unidad) para los paneles.
struct M3Stat: View {
    let title: String
    let value: String
    var unit = ""
    var size: M3.TypeStyle = .displaySmall
    var color: Color = M3.onSurface
    var caption: String?
    var captionColor: Color = M3.onSurfaceVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant).tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(M3.font(size, numeric: true).weight(.semibold)).monospacedDigit().foregroundStyle(color)
                if !unit.isEmpty {
                    Text(unit).font(M3.font(.titleMedium)).foregroundStyle(M3.onSurfaceVariant)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if let caption {
                Text(caption).font(M3.font(.labelMedium)).foregroundStyle(captionColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Navegación

struct M3Destination: Identifiable {
    let id: String
    let title: String
    let systemImage: String
}

/// Barra de navegación lateral de M3 («navigation rail»), para Mac y iPad.
struct M3NavigationRail: View {
    let destinations: [M3Destination]
    @Binding var selection: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bicycle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(M3.onPrimaryContainer)
                .frame(width: 56, height: 56)
                .background(M3.primaryContainer, in: RoundedRectangle(cornerRadius: M3.Shape.large))
                .padding(.bottom, 12)
            ForEach(destinations) { d in
                let selected = d.id == selection
                Button {
                    selection = d.id
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: d.systemImage)
                            .font(.system(size: 18, weight: selected ? .semibold : .regular))
                            .frame(width: 56, height: 32)
                            .foregroundStyle(selected ? M3.onSecondaryContainer : M3.onSurfaceVariant)
                            .background(selected ? M3.secondaryContainer : Color.clear, in: Capsule())
                        Text(d.title)
                            .font(M3.font(.labelMedium))
                            .foregroundStyle(selected ? M3.onSurface : M3.onSurfaceVariant)
                    }
                    .frame(width: 80)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 20)
        .frame(width: 88)
        .frame(maxHeight: .infinity)
        .background(M3.surface)
    }
}

/// Barra de navegación inferior de M3, para el iPhone.
struct M3NavigationBar: View {
    let destinations: [M3Destination]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(destinations) { d in
                let selected = d.id == selection
                Button {
                    selection = d.id
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: d.systemImage)
                            .font(.system(size: 18, weight: selected ? .semibold : .regular))
                            .frame(width: 56, height: 32)
                            .foregroundStyle(selected ? M3.onSecondaryContainer : M3.onSurfaceVariant)
                            .background(selected ? M3.secondaryContainer : Color.clear, in: Capsule())
                        Text(d.title).font(M3.font(.labelMedium)).foregroundStyle(M3.onSurface)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .background(M3.surfaceContainer)
    }
}
