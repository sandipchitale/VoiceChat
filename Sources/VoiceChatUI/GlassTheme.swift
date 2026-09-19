import AppKit
import Observation
import SwiftUI

// Spec §6.1 / §6.7 — the "held glass" look: a frameless, translucent, always-on-top
// window with cyan HUD chrome. Everything visual that is not layout lives here, so
// the conversation view stays about behaviour.

enum Glass {
    /// System cyan — a semantic colour, so it still adapts to contrast settings.
    static let accent = Color(nsColor: .systemCyan)
    static let danger = Color(nsColor: .systemRed)
}

extension ColorScheme {
    /// The tone laid over the glass to calm what shows through it.
    var wash: Color { self == .dark ? .black : .white }
    /// The tone of lines and neutral controls drawn on it.
    var ink: Color { self == .dark ? .white : .black }
    var hairline: Color { ink.opacity(0.12) }
    /// Cyan that stays readable as text: pale cyan vanishes on light glass.
    var accentText: Color { self == .dark ? Glass.accent : Glass.accent.mix(with: .black, by: 0.5) }
}

/// The window's appearance. `system` is the default: it follows macOS.
enum GlassTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Default"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light:  "sun.max.fill"
        case .dark:   "moon.fill"
        }
    }

    /// `nil` lets the window inherit the system appearance.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
    }
}

/// The glass's opacity and theme, shared by every conversation window and
/// remembered across launches. Opacity only moves the backdrops — text and
/// controls stay crisp.
@MainActor @Observable
final class GlassSettings {
    static let shared = GlassSettings()
    private static let key = "VoiceChatGlassOpacity"
    private static let themeKey = "VoiceChatTheme"

    var theme: GlassTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    /// 0 is as see-through as the glass gets, 1 is nearly solid.
    var opacity: Double {
        didSet { UserDefaults.standard.set(opacity, forKey: Self.key) }
    }

    /// Wash strength over the whole window.
    var windowTint: Double { 0.04 + 0.80 * opacity }
    /// Wash strength behind each editor card.
    var paneTint: Double { 0.12 + 0.30 * opacity }

    private init() {
        let stored = UserDefaults.standard.object(forKey: Self.key) as? Double
        opacity = min(max(stored ?? 0.35, 0), 1)
        theme = UserDefaults.standard.string(forKey: Self.themeKey).flatMap(GlassTheme.init) ?? .system
    }
}

/// The window-wide wash whose strength the header slider sets.
struct GlassTint: View {
    private let settings = GlassSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.windowCornerRadius, style: .continuous)
            .fill(scheme.wash.opacity(settings.windowTint))
            .allowsHitTesting(false)
    }
}

// MARK: - Window chrome

/// A thin, luminous rim and a soft top-light sheen over the whole window.
struct GlassRim: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.windowCornerRadius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear],
                                      startPoint: .top,
                                      endPoint: UnitPoint(x: 0.5, y: 0.3)))
            shape.strokeBorder(
                LinearGradient(colors: [Glass.accent.opacity(0.65),
                                        .white.opacity(0.10),
                                        Glass.accent.opacity(0.30)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Lets the person drag the frameless window by its header.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

struct HUDHeader: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void
    @Bindable private var settings = GlassSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Glass.danger.opacity(0.28)))
                    .overlay(Circle().strokeBorder(Glass.danger.opacity(0.75), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Close the window — ends the conversation")
            .accessibilityLabel("Close window")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .textCase(.uppercase)
                    .tracking(2)
                    .foregroundStyle(.primary.opacity(0.9))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(scheme.accentText)
                }
            }
            Spacer()

            ThemePicker(selection: $settings.theme)

            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                Slider(value: $settings.opacity, in: 0...1)
                    .controlSize(.small)
                    .tint(Glass.accent)
                    .frame(width: 110)
                    .accessibilityLabel("Window opacity")
                    .accessibilityValue("\(Int(settings.opacity * 100)) percent")
                Image(systemName: "circle.fill")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .help("Window transparency")
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.outerPadding)
        .frame(height: Metrics.headerHeight)
        .background(WindowDragArea())
        .accessibilityElement(children: .contain)
    }
}

struct GlassDivider: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle().fill(scheme.hairline).frame(height: 1)
    }
}

/// Three icon buttons — Default (follows the system), Light, Dark.
struct ThemePicker: View {
    @Binding var selection: GlassTheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GlassTheme.allCases) { theme in
                let selected = theme == selection
                Button { selection = theme } label: {
                    Image(systemName: theme.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? AnyShapeStyle(scheme.accentText) : AnyShapeStyle(.secondary))
                        .frame(width: 26, height: 22)
                        .background(Capsule().fill(selected ? Glass.accent.opacity(0.22) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(theme.title) theme")
                .accessibilityLabel("\(theme.title) theme")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(scheme.ink.opacity(0.06)))
        .overlay(Capsule().strokeBorder(scheme.hairline))
        .padding(.trailing, 6)
    }
}

// MARK: - Pane chrome

/// Four bracket ticks hugging the corners of a rounded rectangle — the
/// targeting-reticle detail of a holographic panel.
struct CornerBrackets: Shape {
    var radius: CGFloat
    var length: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = radius, l = length
        // top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // top-right
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // bottom-left
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}

// MARK: - Buttons

struct GlassButtonStyle: ButtonStyle {
    enum Tone { case neutral, accent, danger }

    var tone: Tone = .neutral
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tone: tone, prominent: prominent)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let tone: Tone
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme

        private var color: Color {
            switch tone {
            case .neutral: scheme.ink
            case .accent:  Glass.accent
            case .danger:  Glass.danger
            }
        }

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: Metrics.controlHeight)
                .background(Capsule().fill(color.opacity(prominent ? (pressed ? 0.45 : 0.30)
                                                                   : (pressed ? 0.22 : 0.10))))
                .overlay(Capsule().strokeBorder(color.opacity(prominent ? 0.85 : 0.35), lineWidth: 1))
                .shadow(color: prominent && isEnabled ? color.opacity(0.45) : .clear, radius: 7)
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Capsule())
        }
    }
}
