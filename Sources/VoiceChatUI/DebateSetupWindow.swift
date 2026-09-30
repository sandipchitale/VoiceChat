import AppKit
import SwiftUI
import VoiceChatKit

// Spec §17 — "New Debate…": set a motion and two positions, then hand each
// seat's join instruction to whichever MCP client will argue it.
//
// It lives here, beside the conversation window, because it is built from the
// same glass: the same card, the same section headers, the same buttons. A
// stock system form beside that window looks like a different application.

/// What the New Debate dialog creates: the room, the command-line client to
/// start for each seat that has one (R-DEB-11), and the first seat's Talking
/// Head face, the other seat taking the opposite (R-DEB-12).
public struct DebateSetup {
    /// A command-line client to start for a seat, and the command to run: the
    /// proposed one, as the person edited it.
    public struct Debater {
        public let client: DebateClient
        public let command: String
    }

    public let room: DebateRoom
    /// By seat key.
    public let debaters: [String: Debater]
    public let firstSeatFace: TalkingHeadVoice
}

@MainActor
public final class DebateSetupWindowController: NSWindowController {
    private static var current: DebateSetupWindowController?

    public static func show(onCreate: @escaping (DebateSetup) -> Void) {
        let controller = current ?? DebateSetupWindowController(onCreate: onCreate)
        current = controller
        controller.present()
    }

    private init(onCreate: @escaping (DebateSetup) -> Void) {
        let window = GlassWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "New Debate"
        window.minSize = NSSize(width: 700, height: 600)
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
            onCreate: { [weak self] setup in
                onCreate(setup)
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
    let onCreate: (DebateSetup) -> Void
    let onCancel: () -> Void

    @State private var motion = ""
    @State private var forPosition = ""
    @State private var againstPosition = ""
    @State private var statements = 6
    private static let defaultGuidance = "Keep each statement under 120 words."
    @State private var guidance = DebateSetupView.defaultGuidance
    @State private var forVoice = ""
    @State private var againstVoice = ""
    /// The command-line client to start for each seat; nil means the person
    /// pastes the join instruction into a client themselves.
    @State private var forClient: DebateClient?
    @State private var againstClient: DebateClient?
    /// Each chosen client's command, proposed when it is picked, then the
    /// person's to edit.
    @State private var forCommand = ""
    @State private var againstCommand = ""
    /// The room's id, picked when the dialog opens so the join instructions
    /// shown here are the ones that will work.
    @State private var roomID = DebateRoom.makeID()
    /// The seat whose prompt was just copied, to say so briefly.
    @State private var copiedSeat: String?
    /// The clients found on the person's PATH (looked up when the dialog opens).
    @State private var installedClients: [DebateClient] = []
    /// The "for" seat's Talking Head face; "against" always gets the other.
    @State private var forFace = GlassSettings.shared.talkingHeadVoice
    private let hasTalkingHead = TalkingHeadSpeaker.isInstalled
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
                                 client: $forClient, command: $forCommand,
                                 placeholder: "Argue in favour", field: .forSide)
                        seatCard("Against the motion", key: "against",
                                 position: $againstPosition, voice: $againstVoice,
                                 client: $againstClient, command: $againstCommand,
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
        .task {
            let found = await DebateClientFinder.available()
            installedClients = DebateClient.allCases.filter { found[$0] != nil }
        }
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

    /// A seat's Talking Head face. Both seats' controls share one choice, so
    /// picking a face for one side gives the other side the other face: two
    /// sides never share a face window.
    private func face(forSeat key: String) -> Binding<TalkingHeadVoice> {
        Binding(get: { key == "for" ? forFace : forFace.opposite },
                set: { forFace = key == "for" ? $0 : $0.opposite })
    }

    private func seatCard(_ title: String, key: String,
                          position: Binding<String>, voice: Binding<String>,
                          client: Binding<DebateClient?>, command: Binding<String>,
                          placeholder: String, field: Field) -> some View {
        card(title: title, trailing: "“\(key)”", active: focus == field) {
            VStack(alignment: .leading, spacing: 12) {
                wrappingField(position, prompt: placeholder, lines: 2...4, field: field)

                HStack(spacing: 8) {
                    Text("Debater")
                        .font(Metrics.captionFont)
                        .foregroundStyle(.secondary)
                    Picker("", selection: client) {
                        Text("None (paste the join instruction)").tag(DebateClient?.none)
                        ForEach(installedClients) { entry in
                            Text("\(entry.displayName) (\(entry.commandHint))").tag(DebateClient?.some(entry))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .help("Start a command-line AI to argue this side, or paste the join instruction into a client yourself")
                    .onChange(of: client.wrappedValue) { _, chosen in
                        command.wrappedValue = chosen?.commandLine(mcpServer: DebateClientLauncher.mcpServerPath) ?? ""
                    }
                }

                // Always shown: the command to run for a chosen client, else the
                // prompt to paste into one, with a button to copy it.
                VStack(alignment: .leading, spacing: 4) {
                    if let chosen = client.wrappedValue {
                        CommandTextView(text: command)
                            .frame(height: CommandTextView.height(lines: 5))
                            .background(RoundedRectangle(cornerRadius: 6).fill(scheme.wash.opacity(0.5)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(scheme.hairline))
                            .help("The command VoiceChat runs in your shell. Edit it freely; $VOICECHAT_JOIN holds this side's join instruction.")
                        HStack(spacing: 6) {
                            Text("Runs in your shell; $\(DebateClient.instructionVariable) is the join instruction")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            Button("Reset") {
                                command.wrappedValue = chosen.commandLine(mcpServer: DebateClientLauncher.mcpServerPath)
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 10))
                            .help("Go back to the proposed command")
                        }
                    } else {
                        let prompt = joinPrompt(forSeat: key)
                        CommandTextView(text: .constant(prompt), isEditable: false)
                            .frame(height: CommandTextView.height(lines: 5))
                            .background(RoundedRectangle(cornerRadius: 6).fill(scheme.wash.opacity(0.5)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(scheme.hairline))
                            .help("Paste this into the MCP client that should argue this side")
                        HStack(spacing: 6) {
                            Text("Paste into any MCP client to take this side")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            Button(copiedSeat == key ? "Copied" : "Copy") { copy(prompt, seat: key) }
                                .buttonStyle(.link)
                                .font(.system(size: 10))
                                .disabled(trimmedMotion.isEmpty)
                                .help("Copy this side's join instruction")
                        }
                    }
                }

                if hasTalkingHead {
                    HStack(spacing: 8) {
                        Text("Face")
                            .font(Metrics.captionFont)
                            .foregroundStyle(.secondary)
                        Picker("", selection: face(forSeat: key)) {
                            Text("Man").tag(TalkingHeadVoice.male)
                            Text("Woman").tag(TalkingHeadVoice.female)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .help("Talking Head's face for this side; the other side gets the other face")
                    }
                }

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
            Text(footerHint)
                .font(Metrics.captionFont)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(GlassButtonStyle())
            Button("Create Debate") {
                var debaters: [String: DebateSetup.Debater] = [:]
                for (key, client, command) in [("for", forClient, forCommand), ("against", againstClient, againstCommand)] {
                    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let client, !trimmed.isEmpty {
                        debaters[key] = DebateSetup.Debater(client: client, command: trimmed)
                    }
                }
                onCreate(DebateSetup(room: room(), debaters: debaters, firstSeatFace: forFace))
            }
                .buttonStyle(GlassButtonStyle(tone: .accent, prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(trimmedMotion.isEmpty)
                .help("Create the room, then copy a join instruction for each seat (⌘↩)")
        }
        .padding(.horizontal, Metrics.outerPadding)
        .frame(height: Metrics.bottomBarHeight)
    }

    /// Says who will join: the clients to be started, and whether the person
    /// still has a join instruction to paste.
    private var footerHint: String {
        guard !trimmedMotion.isEmpty else { return "Set a motion to create the debate" }
        let started = [forClient, againstClient].compactMap { $0?.displayName }
        switch started.count {
        case 2 where started[0] == started[1]: return "Two \(started[0]) debaters will join"
        case 2: return "\(started[0]) and \(started[1]) will join"
        case 1: return "\(started[0]) will join; paste the other side's join instruction"
        default: return "Both seats open when two clients join"
        }
    }

    /// The join instruction a person pastes into a client to take `key`'s seat,
    /// as it stands with the motion typed so far.
    private func joinPrompt(forSeat key: String) -> String {
        guard !trimmedMotion.isEmpty else { return "Set a motion to see this side's join instruction." }
        let draft = room()
        return draft.seat(key).map(draft.joinInstruction(for:)) ?? ""
    }

    private func copy(_ prompt: String, seat key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        copiedSeat = key
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedSeat == key { copiedSeat = nil }
        }
    }

    private func room() -> DebateRoom {
        func position(_ text: String, fallback: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }
        return DebateRoom(
            id: roomID,
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

// MARK: - The command field

/// A shell command, editable: five lines tall in both seats, wrapping, with a
/// scroll bar always shown. Plain AppKit text, so none of the text
/// substitutions (smart quotes and dashes above all) that would quietly break
/// a command can apply.
private struct CommandTextView: NSViewRepresentable {
    @Binding var text: String
    /// False for text that is only there to read and copy.
    var isEditable = true

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let inset = NSSize(width: 4, height: 5)

    /// The height that shows `lines` lines of the command.
    static func height(lines: Int) -> CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return ceil(lineHeight * CGFloat(lines) + inset.height * 2 + 2)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.textContainerInset = Self.inset
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isEditable = isEditable
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text { textView.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
