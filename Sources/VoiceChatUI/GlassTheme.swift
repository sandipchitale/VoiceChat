import AppKit
import Observation
import SwiftUI

// Spec §6.1 / §6.7 — the "held glass" look: a frameless, translucent, always-on-top
// window with cyan HUD chrome. Everything visual that is not layout lives here, so
// the conversation view stays about behaviour.

enum Glass {
    /// The hairline rule, for the chrome helpers that have no `ColorScheme`
    /// to ask. `ColorScheme.hairline` stays the per-scheme answer.
    static let hairline = Color(nsColor: .separatorColor)

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

    /// Tooltip text: what choosing this theme does.
    var help: String {
        switch self {
        case .system: "Default theme — follow the system's light or dark appearance"
        case .light:  "Light theme"
        case .dark:   "Dark theme"
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

/// How the two panes are arranged: prompt beside the response, or above it.
enum PaneLayout: String, CaseIterable, Identifiable {
    case sideBySide, stacked

    var id: String { rawValue }

    /// The axis the panes are laid out along.
    var axis: Axis { self == .sideBySide ? .horizontal : .vertical }

    /// A picture of this arrangement.
    var symbol: String {
        switch self {
        case .sideBySide: "rectangle.split.2x1"
        case .stacked:    "rectangle.split.1x2"
        }
    }

    var toggled: PaneLayout { self == .sideBySide ? .stacked : .sideBySide }
}

/// The glass's opacity and theme, shared by every conversation window and
/// remembered across launches. Opacity only moves the backdrops — text and
/// controls stay crisp.
@MainActor @Observable
final class GlassSettings {
    static let shared = GlassSettings()
    private static let key = "VoiceChatGlassOpacity"
    private static let themeKey = "VoiceChatTheme"
    private static let alwaysOnTopKey = "VoiceChatAlwaysOnTop"
    private static let speechMutedKey = "VoiceChatSpeechMuted"
    private static let useTalkingHeadKey = "VoiceChatUseTalkingHead"
    private static let talkingHeadVoiceKey = "VoiceChatTalkingHeadVoice"
    private static let paneLayoutKey = "VoiceChatPaneLayout"
    private static let sideBySideSplitKey = "VoiceChatSideBySideSplit"
    private static let stackedSplitKey = "VoiceChatStackedSplit"

    /// Side by side or stacked, from the header's layout button.
    var paneLayout: PaneLayout {
        didSet { UserDefaults.standard.set(paneLayout.rawValue, forKey: Self.paneLayoutKey) }
    }

    /// The prompt pane's share of the split, 0…1, remembered separately for
    /// each layout — a good width split is rarely a good height split.
    var sideBySideSplit: Double {
        didSet { UserDefaults.standard.set(sideBySideSplit, forKey: Self.sideBySideSplitKey) }
    }
    var stackedSplit: Double {
        didSet { UserDefaults.standard.set(stackedSplit, forKey: Self.stackedSplitKey) }
    }

    /// The split for whichever layout is current.
    var paneSplit: Double {
        get { paneLayout == .sideBySide ? sideBySideSplit : stackedSplit }
        set {
            if paneLayout == .sideBySide { sideBySideSplit = newValue } else { stackedSplit = newValue }
        }
    }

    var theme: GlassTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    /// Whether conversation windows float above other apps' windows. On by
    /// default — a conversation window nobody can see defeats the point of the
    /// tool call — but the pin in the header lets the person opt out.
    var alwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: Self.alwaysOnTopKey) }
    }

    /// Whether replies are read silently. Shared by every conversation window
    /// (it is about the machine's audio, not one conversation) and remembered,
    /// with the button's state always visible so a silent reply is never a
    /// mystery.
    var speechMuted: Bool {
        didSet { UserDefaults.standard.set(speechMuted, forKey: Self.speechMutedKey) }
    }

    /// Whether replies are read by Talking Head's `th` rather than the built-in
    /// voice. Only offered when `th` is installed.
    var useTalkingHead: Bool {
        didSet { UserDefaults.standard.set(useTalkingHead, forKey: Self.useTalkingHeadKey) }
    }

    /// Which Talking Head character reads, passed to `th` as `-v`.
    var talkingHeadVoice: TalkingHeadVoice {
        didSet { UserDefaults.standard.set(talkingHeadVoice.rawValue, forKey: Self.talkingHeadVoiceKey) }
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
        alwaysOnTop = UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) as? Bool ?? true
        speechMuted = UserDefaults.standard.bool(forKey: Self.speechMutedKey)
        useTalkingHead = UserDefaults.standard.bool(forKey: Self.useTalkingHeadKey)
        talkingHeadVoice = UserDefaults.standard.string(forKey: Self.talkingHeadVoiceKey)
            .flatMap(TalkingHeadVoice.init) ?? .male
        paneLayout = UserDefaults.standard.string(forKey: Self.paneLayoutKey).flatMap(PaneLayout.init) ?? .sideBySide
        sideBySideSplit = Self.storedSplit(Self.sideBySideSplitKey)
        stackedSplit = Self.storedSplit(Self.stackedSplitKey)
    }

    private static func storedSplit(_ key: String) -> Double {
        let stored = UserDefaults.standard.object(forKey: key) as? Double
        return min(max(stored ?? 0.5, 0), 1)
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

/// The red disc every glass window closes from.
struct CloseButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Glass.danger.opacity(0.28)))
                .overlay(Circle().strokeBorder(Glass.danger.opacity(0.75), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Close")
    }
}

struct HUDHeader: View {
    let title: String
    let subtitle: String
    let badge: String?
    let onClose: () -> Void
    @Bindable private var settings = GlassSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 14) {
            CloseButton(help: "Close the window — ends the conversation", action: onClose)

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

            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Glass.accent.opacity(0.12)))
                    .help("Model and app driving this conversation")
            }

            LayoutButton(layout: $settings.paneLayout)

            PinButton(isPinned: $settings.alwaysOnTop)

            ThemePicker(selection: $settings.theme)

            // Each part carries its own tooltip: an AppKit-backed slider does
            // not reliably inherit one set on its container.
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                    .help("More transparent")
                Slider(value: $settings.opacity, in: 0...1)
                    .controlSize(.small)
                    .tint(Glass.accent)
                    .frame(width: 110)
                    .help("Window opacity — \(Int(settings.opacity * 100))%. Drag left for more transparent, right for more opaque.")
                    .accessibilityLabel("Window opacity")
                    .accessibilityValue("\(Int(settings.opacity * 100)) percent")
                Image(systemName: "circle.fill")
                    .help("More opaque")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.outerPadding)
        .frame(height: Metrics.headerHeight)
        .background(WindowDragArea())
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// R-UI-4 — a card of held glass whose rim, brackets and glow answer to
    /// focus. One definition, so the panes and the debate dialog cannot drift
    /// apart on border widths or the glow.
    func glassCard(isActive: Bool, cornerRadius: CGFloat = Metrics.cardRadius,
                   bracketLength: CGFloat = 18) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isActive ? Glass.accent.opacity(0.85) : Glass.hairline,
                                  lineWidth: isActive ? 1.5 : 1))
            .overlay(
                CornerBrackets(radius: cornerRadius, length: bracketLength)
                    .stroke(Glass.accent.opacity(isActive ? 1 : 0.4),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .allowsHitTesting(false))
            .shadow(color: isActive ? Glass.accent.opacity(0.35) : .clear, radius: 12)
    }

    /// The accent strip the banners and the debate bar share.
    func accentBar() -> some View {
        padding(.horizontal, Metrics.outerPadding)
            .frame(height: Metrics.accentBarHeight)
            .background(Glass.accent.opacity(0.12))
    }
}

struct GlassDivider: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle().fill(scheme.hairline).frame(height: 1)
    }
}

/// Switches the panes between side by side and stacked. The current layout
/// is already on screen, so the icon shows the one a click switches *to*.
/// It is an action, not a state, so it reads at full strength rather than in
/// the muted style of an off toggle.
struct LayoutButton: View {
    @Binding var layout: PaneLayout
    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { layout = layout.toggled } label: {
            Image(systemName: layout.toggled.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? AnyShapeStyle(scheme.accentText)
                                            : AnyShapeStyle(.primary.opacity(0.85)))
                .frame(width: 26, height: 22)
                .background(Capsule().fill(isHovering ? Glass.accent.opacity(0.22)
                                                      : scheme.ink.opacity(0.10)))
                .overlay(Capsule().strokeBorder(isHovering ? Glass.accent.opacity(0.6)
                                                           : scheme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .keyboardShortcut("l", modifiers: [.command, .option])
        .help(layout == .sideBySide
              ? "Stack the panes top and bottom (⌥⌘L)"
              : "Put the panes side by side (⌥⌘L)")
        .accessibilityLabel(layout == .sideBySide ? "Stack panes top and bottom"
                                                  : "Put panes side by side")
    }
}

/// Pins the window above other apps' windows, or lets it sit among them.
struct PinButton: View {
    @Binding var isPinned: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { isPinned.toggle() } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin.slash")
                .font(.system(size: 11))
                .foregroundStyle(isPinned ? AnyShapeStyle(scheme.accentText) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 22)
                .background(Capsule().fill(isPinned ? Glass.accent.opacity(0.22) : scheme.ink.opacity(0.06)))
                .overlay(Capsule().strokeBorder(scheme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Always on top — click to let other windows cover it"
                       : "Not always on top — click to keep it above other windows")
        .accessibilityLabel("Always on top")
        .accessibilityValue(isPinned ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .padding(.trailing, 6)
    }
}

/// Silences the reading without stopping it: the highlight, the timing and the
/// auto-advance all carry on, just without sound.
struct MuteButton: View {
    @Binding var isMuted: Bool
    let isSpeaking: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { isMuted.toggle() } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : (isSpeaking ? "waveform" : "speaker.wave.2.fill"))
                .font(.system(size: 11))
                .foregroundStyle(isMuted ? AnyShapeStyle(Glass.danger)
                                         : (isSpeaking ? AnyShapeStyle(scheme.accentText) : AnyShapeStyle(.secondary)))
                .frame(width: 26, height: 22)
                .background(Capsule().fill(isMuted ? Glass.danger.opacity(0.18) : scheme.ink.opacity(0.06)))
                .overlay(Capsule().strokeBorder(isMuted ? Glass.danger.opacity(0.5) : scheme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .help(isMuted ? "Muted — click to hear replies again (⇧⌘M)"
                      : "Click to read replies silently (⇧⌘M)")
        .accessibilityLabel("Mute speech")
        .accessibilityValue(isMuted ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Reads replies with Talking Head's animated face instead of the built-in
/// voice. Shown only when its `th` command is installed.
struct TalkingHeadButton: View {
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: isOn ? "person.wave.2.fill" : "person.wave.2")
                .font(.system(size: 11))
                .foregroundStyle(isOn ? AnyShapeStyle(scheme.accentText) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 22)
                .background(Capsule().fill(isOn ? scheme.accentText.opacity(0.14) : scheme.ink.opacity(0.06)))
                .overlay(Capsule().strokeBorder(isOn ? scheme.accentText.opacity(0.45) : scheme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Replies are read by Talking Head — click to use the built-in voice (from the next reply)"
                   : "Click to read replies with Talking Head (from the next reply)")
        .accessibilityLabel("Speak with Talking Head")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Male or female Talking Head, styled like the theme picker. Dimmed while
/// Talking Head is off, but still settable, so the voice can be chosen first.
struct TalkingHeadVoicePicker: View {
    @Binding var selection: TalkingHeadVoice
    let isActive: Bool
    var isDebateSeat = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TalkingHeadVoice.allCases, id: \.self) { voice in
                let selected = voice == selection
                Button { selection = voice } label: {
                    Image(systemName: voice.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? AnyShapeStyle(scheme.accentText) : AnyShapeStyle(.secondary))
                        .frame(width: 26, height: 22)
                        .background(Capsule().fill(selected ? Glass.accent.opacity(0.22) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help(for: voice, selected: selected))
                .accessibilityLabel("\(voice.title) Talking Head voice")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(scheme.ink.opacity(0.06)))
        .overlay(Capsule().strokeBorder(scheme.hairline))
        .opacity(isActive ? 1 : 0.5)
    }

    private func help(for voice: TalkingHeadVoice, selected: Bool) -> String {
        var text = "Talking Head voice: \(voice.title)"
        if selected { text += " (current)" }
        if isDebateSeat { text += " — this seat only; the other side takes the opposite" }
        return text
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
                .help(selected ? "\(theme.help) (current)" : theme.help)
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
