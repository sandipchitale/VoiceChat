import AppKit
import SwiftUI
import VoiceChatKit

// Spec §17 — "New Debate…": set a motion and two positions, then hand each
// seat's join instruction to whichever MCP client will argue it.
//
// It lives here, beside the conversation window, because it is built from the
// same glass: the same card, the same section headers, the same buttons. A
// stock system form beside that window looks like a different application.

@MainActor
public final class DebateSetupWindowController: NSWindowController {
    private static var current: DebateSetupWindowController?

    public static func show(onCreate: @escaping (DebateRoom) -> Void) {
        let controller = current ?? DebateSetupWindowController(onCreate: onCreate)
        current = controller
        controller.present()
    }

    private init(onCreate: @escaping (DebateRoom) -> Void) {
        let window = GlassWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "New Debate"
        window.minSize = NSSize(width: 620, height: 540)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Conversation windows float; this must not slide behind one.
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        observeTheme()

        let root = DebateSetupView(
            onCreate: { [weak self] room in
                onCreate(room)
                self?.close()
            },
            onCancel: { [weak self] in self?.close() })

        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = Metrics.windowCornerRadius
        glass.contentView = host
        window.contentView = glass

        // A borderless window's frame is square, so its shadow and outline
        // poke past the rounded glass unless the frame is rounded too.
        if let frame = glass.superview {
            frame.wantsLayer = true
            frame.layer?.cornerRadius = Metrics.windowCornerRadius
            frame.layer?.cornerCurve = .continuous
            frame.layer?.masksToBounds = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Follows the theme the header's buttons set, as conversation windows do;
    /// otherwise switching to Light leaves this dialog dark behind them.
    private func observeTheme() {
        withObservationTracking {
            _ = GlassSettings.shared.theme
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTheme() }
        }
        window?.appearance = GlassSettings.shared.theme.appearance
    }

    private func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension DebateSetupWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

// MARK: - The form

private struct DebateSetupView: View {
    let onCreate: (DebateRoom) -> Void
    let onCancel: () -> Void

    @State private var motion = ""
    @State private var forPosition = ""
    @State private var againstPosition = ""
    @State private var statements = 6
    private static let defaultGuidance = "Keep each statement under 120 words."
    @State private var guidance = DebateSetupView.defaultGuidance
    @State private var forVoice = ""
    @State private var againstVoice = ""
    @FocusState private var focus: Field?
    @Environment(\.colorScheme) private var scheme

    private enum Field: Hashable { case motion, forSide, againstSide, rules }

    private static let statementRange = 2...40

    private func adjustStatements(by delta: Int) {
        statements = min(max(statements + delta, Self.statementRange.lowerBound),
                         Self.statementRange.upperBound)
    }

    /// One half of the count control: a proper target, not a 7-point arrow.
    @ViewBuilder
    private func countButton(_ symbol: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? AnyShapeStyle(scheme.accentText)
                                         : AnyShapeStyle(.tertiary))
                .frame(width: 30, height: 26)
                .background(Capsule().fill(Glass.accent.opacity(enabled ? 0.16 : 0.05)))
                .overlay(Capsule().strokeBorder(enabled ? Glass.accent.opacity(0.45)
                                                        : scheme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Read once: the installed voices cannot change while this is open, and
    /// the body re-evaluates on every keystroke.
    @State private var voices = DebateVoices.installed()

    private var trimmedMotion: String {
        motion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GlassDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    motionCard
                    HStack(alignment: .top, spacing: Metrics.paneGap) {
                        seatCard("For the motion", key: "for",
                                 position: $forPosition, voice: $forVoice,
                                 placeholder: "Argue in favour", field: .forSide)
                        seatCard("Against the motion", key: "against",
                                 position: $againstPosition, voice: $againstVoice,
                                 placeholder: "Argue against", field: .againstSide)
                    }
                    rulesCard
                }
                .padding(Metrics.outerPadding)
            }

            GlassDivider()
            footer
        }
        .background(GlassTint())
        .overlay(GlassRim())
        .onAppear { focus = .motion }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            CloseButton(help: "Close without creating a debate", action: onCancel)
                .keyboardShortcut(.cancelAction)

            VStack(alignment: .leading, spacing: 2) {
                Text("NEW DEBATE")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.primary.opacity(0.9))
                Text("Two AI clients argue a motion you set")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(scheme.accentText)
            }
            Spacer()
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.outerPadding)
        .frame(height: Metrics.headerHeight)
        .background(WindowDragArea())
    }

    // MARK: Cards

    private var motionCard: some View {
        card(title: "Motion", active: focus == .motion) {
            wrappingField($motion, prompt: "Does consciousness require a biological substrate?",
                          lines: 3...6, field: .motion)
        }
    }

    /// A vertical TextField rather than a TextEditor: its prompt is drawn
    /// where the caret actually is, instead of an overlay guessing at the
    /// text inset.
    private func wrappingField(_ text: Binding<String>, prompt: String,
                               lines: ClosedRange<Int>, field: Field) -> some View {
        TextField("", text: text, prompt: Text(prompt), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: Metrics.bodyPointSize))
            .lineLimit(lines)
            .focused($focus, equals: field)
    }

    private func seatCard(_ title: String, key: String,
                          position: Binding<String>, voice: Binding<String>,
                          placeholder: String, field: Field) -> some View {
        card(title: title, trailing: "“\(key)”", active: focus == field) {
            VStack(alignment: .leading, spacing: 12) {
                wrappingField(position, prompt: placeholder, lines: 2...4, field: field)

                HStack(spacing: 8) {
                    Text("Voice")
                        .font(Metrics.captionFont)
                        .foregroundStyle(.secondary)
                    Picker("", selection: voice) {
                        Text("System").tag("")
                        ForEach(voices, id: \.identifier) { entry in
                            Text(entry.name).tag(entry.identifier)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .help("Both sides use the system voice unless you choose otherwise")
                }
            }
        }
    }

    private var rulesCard: some View {
        HStack(alignment: .top, spacing: Metrics.paneGap) {
            card(title: "House rules", active: focus == .rules) {
                TextField("", text: $guidance, prompt: Text(Self.defaultGuidance))
                    .textFieldStyle(.plain)
                    .font(.system(size: Metrics.bodyPointSize))
                    .focused($focus, equals: .rules)
                    .frame(height: 22)
            }
            card(title: "Statements", trailing: "then closings", active: false) {
                HStack(spacing: 0) {
                    countButton("minus", enabled: statements > Self.statementRange.lowerBound) {
                        adjustStatements(by: -1)
                    }
                    Text("\(statements)")
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.15), value: statements)
                    countButton("plus", enabled: statements < Self.statementRange.upperBound) {
                        adjustStatements(by: 1)
                    }
                }
                .frame(height: 26)
                .help("How many statements the two sides make before closing arguments")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Statements before closing arguments")
                .accessibilityValue("\(statements)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: adjustStatements(by: 1)
                    case .decrement: adjustStatements(by: -1)
                    @unknown default: break
                    }
                }
            }
            .frame(width: 210)
        }
    }

    /// The pane card of §6.2, at dialog scale: an accent-bracketed box whose
    /// border lights up when what it holds has focus.
    @ViewBuilder
    private func card<Content: View>(title: String, trailing: String? = nil,
                                     active: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(active ? AnyShapeStyle(scheme.accentText)
                                            : AnyShapeStyle(.secondary))
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            content()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(scheme.wash.opacity(GlassSettings.shared.paneTint))
                .glassCard(isActive: active, bracketLength: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(trimmedMotion.isEmpty
                 ? "Set a motion to create the debate"
                 : "Both seats open when two clients join")
                .font(Metrics.captionFont)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(GlassButtonStyle())
            Button("Create Debate") { onCreate(room()) }
                .buttonStyle(GlassButtonStyle(tone: .accent, prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(trimmedMotion.isEmpty)
                .help("Create the room, then copy a join instruction for each seat (⌘↩)")
        }
        .padding(.horizontal, Metrics.outerPadding)
        .frame(height: Metrics.bottomBarHeight)
    }

    private func room() -> DebateRoom {
        func position(_ text: String, fallback: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }
        return DebateRoom(
            motion: trimmedMotion,
            seats: [
                DebateSeat(key: "for", name: "For the motion",
                           position: position(forPosition, fallback: "In favour of the motion."),
                           voice: forVoice.isEmpty ? nil : forVoice),
                DebateSeat(key: "against", name: "Against the motion",
                           position: position(againstPosition, fallback: "Against the motion."),
                           voice: againstVoice.isEmpty ? nil : againstVoice),
            ],
            maxStatements: statements,
            guidance: guidance)
    }
}
