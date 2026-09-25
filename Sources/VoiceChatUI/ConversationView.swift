import AppKit
import SwiftUI
import VoiceChatKit

// Spec §6 — the conversation window. Every enable/disable comes from the
// model, which derives it from the state machine (§6.6).

public struct ConversationView: View {
    @Bindable var model: ConversationModel
    let title: String
    let onCloseWindow: () -> Void
    @Bindable private var glassSettings = GlassSettings.shared
    @State private var showingCommandHelp = false
    @Environment(\.colorScheme) private var scheme

    public init(model: ConversationModel, title: String = "VoiceChat",
                onCloseWindow: @escaping () -> Void = {}) {
        self.model = model
        self.title = title
        self.onCloseWindow = onCloseWindow
    }

    public var body: some View {
        VStack(spacing: 0) {
            HUDHeader(title: title, subtitle: model.windowSubtitle, badge: model.identityBadge,
                     onClose: onCloseWindow)   // R-UI-1
            GlassDivider()
            if let banner = model.terminalBanner {
                TerminalBanner(text: banner)                      // R-UI-20
            }
            if let debate = model.debate {                        // R-DEB-8
                DebateBar(badge: debate,
                          onAutoHandoff: { model.onDebateAutoHandoff?($0) },
                          onSkip: { model.onDebateSkipTurn?() },
                          onEnd: { model.onDebateEnd?() })
            }
            if model.isViewingHistory {
                HistoryPeekBar { model.returnToCurrentTurn() }     // R-UI-11
            }

            PaneSplitView(axis: glassSettings.paneLayout.axis,
                          fraction: $glassSettings.paneSplit,
                          minFirst: minPaneLength,
                          minSecond: minPaneLength) {
                promptPane
            } second: {
                responsePane
            }
            .padding(Metrics.outerPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            GlassDivider()
            HistoryStrip(model: model)
            GlassDivider()
            bottomBar
        }
        .background(GlassTint())
        .overlay(GlassRim())
        .overlay(alignment: .bottom) { toast }
        .background {
            // ⇧⌘D toggles the voice mode from anywhere in the window (§6.8).
            Button("") {
                model.setVoiceMode(model.voiceMode == .dictation ? .command : .dictation)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .opacity(0)
            .accessibilityHidden(true)
            .disabled(!model.canChangeVoiceMode)
        }
    }

    /// R-STT-11 / R-STT-17 — an unrecognised or unavailable command is said
    /// out loud in the interface, never typed into the document.
    @ViewBuilder private var toast: some View {
        if let message = model.commandToast {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Glass.accent.opacity(0.5)))
                .padding(.bottom, Metrics.bottomBarHeight + 16)
                .transition(.opacity)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(2))
                    model.dismissToast()
                }
        }
    }

    // MARK: Panes

    /// R-UI-3 — the narrowest a pane may be dragged: its width side by side,
    /// its height when stacked.
    private var minPaneLength: CGFloat {
        glassSettings.paneLayout == .sideBySide ? Metrics.minPaneWidth : Metrics.minPaneHeight
    }

    private var promptPane: some View {
        Pane(
            title: "Compose prompt (edit or dictate)",
            chip: model.promptStatusText,
            isActive: model.state == .composing,
            hint: "⌘↩ Send · ⌃R Mic · ⇧⌘D Mode",
            editor: {
                ZStack(alignment: .topLeading) {
                    RichTextView(text: $model.promptText,
                                 isEditable: model.promptIsEditable,
                                 wantsFocus: model.focusedPane == .prompt,
                                 ghost: model.focusedPane == .prompt ? model.volatileText : "",
                                 onUserEdit: { model.clearVolatile() },
                                 onMakeTextView: { model.registerTextView(.prompt, $0) },
                                 onEdit: { model.promptDidEdit() },
                                 caretRequest: model.promptCaretRequest)
                    PlaceholderOverlay(text: "Speak or type your prompt…",
                                       isVisible: model.plainPrompt.isEmpty && model.volatileText.isEmpty)
                }
            },
            footer: { promptFooter },
            notice: { permissionNotice }
        )
    }

    private var promptFooter: some View {
        HStack(spacing: 12) {
            micButton
            modeControl
            commandHelpButton

            if model.voiceMode == .command {
                commandBox
            } else {
                Text(model.micStatus.isEmpty ? model.promptStatusText : model.micStatus)
                    .font(Metrics.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            Button("Send") { model.send() }
                .buttonStyle(GlassButtonStyle(tone: .accent, prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend)
        }
    }

    /// R-UI-21 / R-STT-26 — a recoverable problem is an inline row with one
    /// action, never a modal alert over a conversation that still works.
    @ViewBuilder private var permissionNotice: some View {
        if model.micDenied {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("VoiceChat cannot use the microphone. You can still type.")
                    .font(Metrics.captionFont)
                Spacer()
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(Metrics.captionFont)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.orange.opacity(0.10))
        }
    }

    private var micButton: some View {
        Button {
            model.setMicEnabled(!model.micEnabled)
        } label: {
            ZStack {
                Circle()
                    .fill(model.recognizerShouldRun
                          ? Glass.danger
                          : scheme.ink.opacity(0.12))
                // Level ring, driven by input RMS (§6.3).
                Circle()
                    .strokeBorder(Glass.danger.opacity(0.45), lineWidth: 2)
                    .scaleEffect(1 + CGFloat(model.micLevel) * 0.6)
                    .opacity(model.recognizerShouldRun ? 1 : 0)
                Image(systemName: model.micEnabled ? "mic.fill" : "mic.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.recognizerShouldRun ? Color.white : Color.secondary)
            }
            .frame(width: Metrics.controlHeight, height: Metrics.controlHeight)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("r", modifiers: .control)
        .disabled(!model.canToggleMic)
        .help(model.micEnabled ? "Turn the microphone off (⌃R)" : "Turn the microphone on (⌃R)")
        .accessibilityLabel("Microphone")
        .accessibilityValue(model.micEnabled ? "on" : "off")
    }

    /// Spec conflict C2 — the two-position control that v1.0 called a "slider".
    private var modeControl: some View {
        Picker("", selection: Binding(get: { model.voiceMode },
                                      set: { model.setVoiceMode($0) })) {
            Text("Dictation").tag(VoiceMode.dictation)
            Text("Command").tag(VoiceMode.command)
        }
        .pickerStyle(.segmented)
        .tint(Glass.accent)
        .labelsHidden()
        .fixedSize()
        .disabled(!model.canChangeVoiceMode)
        .accessibilityLabel("Voice mode")
    }

    /// Help affordance beside the mode control — opens a scrollable reference of
    /// every supported voice command.
    private var commandHelpButton: some View {
        Button {
            showingCommandHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .help("Show the voice commands")
        .accessibilityLabel("Voice command help")
        .popover(isPresented: $showingCommandHelp, arrowEdge: .bottom) {
            CommandHelpView()
        }
    }

    /// Command-mode only: shows the live interim command (and the last one) so
    /// command speech never enters the pane as ghost text. Read-only; commands
    /// come from the microphone.
    private var commandBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(model.commandLine.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            Text(model.commandLine.isEmpty ? "Say a command…" : model.commandLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(model.commandLine.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.controlHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scheme.wash.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(scheme.hairline)
        )
        .accessibilityElement()
        .accessibilityLabel("Command input")
        .accessibilityValue(model.commandLine)
    }

    private var responsePane: some View {
        Pane(
            title: "AI Response",
            chip: model.responseStatusText,
            isActive: model.state.isResponding,
            hint: "⌘↩ Got it! · ⇧⌘P Play/Stop",
            editor: {
                ZStack(alignment: .topLeading) {
                    RichTextView(text: $model.responseText,
                                 isEditable: model.responseIsEditable,
                                 wantsFocus: model.focusedPane == .response,
                                 spellChecking: false,
                                 highlightRange: model.highlightRange,
                                 ghost: model.focusedPane == .response ? model.volatileText : "",
                                 onUserEdit: { model.clearVolatile() },
                                 onMakeTextView: { model.registerTextView(.response, $0) },
                                 caretRequest: model.responseCaretRequest)
                        .opacity(model.showsPreviousResponse ? 0.55 : 1)
                    PlaceholderOverlay(text: model.responsePlaceholder,
                                       isVisible: model.plainResponse.isEmpty)
                }
            },
            footer: { responseFooter },
            notice: { EmptyView() }
        )
    }

    private var responseFooter: some View {
        HStack(spacing: 12) {
            MuteButton(isMuted: $glassSettings.speechMuted, isSpeaking: model.machine.isSpeaking)
            if TalkingHeadSpeaker.isInstalled {
                TalkingHeadButton(isOn: $glassSettings.useTalkingHead)
                TalkingHeadVoicePicker(selection: $glassSettings.talkingHeadVoice,
                                       isActive: glassSettings.useTalkingHead)
            }

            Text(model.responseStatusText)
                .font(Metrics.captionFont)
                .foregroundStyle(.secondary)

            Spacer()

            // One button, one shortcut: Stop while speaking, Play otherwise.
            if model.canStop {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(GlassButtonStyle(tone: .danger))
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            } else {
                Button { model.play() } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.canPlay)
            }

            Button("Got it!") { model.gotIt() }
                .buttonStyle(GlassButtonStyle(tone: .accent, prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canGotIt)
        }
    }

    // MARK: Bottom bar (§6.1)

    private var bottomBarText: String {
        // The host is already in "Connected to …", so only the model is added.
        let connected = model.sessionIdentity.map { "Connected to \($0)" } ?? "VoiceChat"
        guard let currentModel = model.currentModel else { return connected }
        return "\(connected) · \(currentModel)"
    }

    private var bottomBar: some View {
        HStack {
            Text(bottomBarText)
                .font(Metrics.captionFont)
                .foregroundStyle(.tertiary)
                .help(model.workingDirectory ?? "")
            if !model.roots.isEmpty {
                RootsButton(roots: model.roots)
            }
            Spacer()
            if model.state.isTerminal {
                // R-UI-20-adjacent — once ended there is nothing left to
                // confirm; this must always be enabled so the window can
                // always be dismissed, independent of the auto-close timer.
                Button("Close") { model.closeWindow() }
                    .buttonStyle(GlassButtonStyle(tone: .accent, prominent: true))
                    .keyboardShortcut("w", modifiers: .command)
            } else {
                Button("End conversation") {
                    // No confirmation — end immediately and close the window.
                    model.end(.userEnded)
                }
                .buttonStyle(GlassButtonStyle(tone: .danger, prominent: true))
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!model.canEnd)
            }
        }
        .padding(.horizontal, Metrics.outerPadding)
        .frame(height: Metrics.bottomBarHeight)
    }
}

/// R-UI-29 — the host's MCP roots, listed in a popover from the bottom bar.
/// Shown only when the host reported some: most conversations have none.
struct RootsButton: View {
    let roots: [WorkspaceRoot]
    @State private var isShowing = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { isShowing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text("\(roots.count)")
            }
            .font(Metrics.captionFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(scheme.ink.opacity(0.08)))
            .overlay(Capsule().strokeBorder(scheme.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(roots.count == 1 ? "1 workspace root the host is working in"
                               : "\(roots.count) workspace roots the host is working in")
        .accessibilityLabel("Workspace roots")
        .accessibilityValue("\(roots.count)")
        .popover(isPresented: $isShowing, arrowEdge: .top) {
            RootsPopover(roots: roots)
        }
    }
}

struct RootsPopover: View {
    let roots: [WorkspaceRoot]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workspace roots")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text("Reported by the app driving this conversation.")
                .font(Metrics.captionFont)
                .foregroundStyle(.tertiary)

            ForEach(roots) { root in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Glass.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(root.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Text(root.displayPath)
                            .font(Metrics.captionFont)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    if let path = root.path {
                        // A root is a folder on this Mac; opening it is the one
                        // thing there is to do with it here.
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: path)])
                        }
                        .buttonStyle(.link)
                        .font(Metrics.captionFont)
                        .help("Show this folder in the Finder")
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 320, maxWidth: 520, alignment: .leading)
    }
}

// MARK: - Pane chrome (§6.2)

struct Pane<Editor: View, Footer: View, Notice: View>: View {
    let title: String
    let chip: String
    let isActive: Bool
    let hint: String
    @ViewBuilder var editor: () -> Editor
    @ViewBuilder var footer: () -> Footer
    @ViewBuilder var notice: () -> Notice
    private let glass = GlassSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .textCase(.uppercase)
                    .tracking(1.6)
                    .foregroundStyle(isActive ? AnyShapeStyle(scheme.accentText) : AnyShapeStyle(.secondary))
                Spacer()
                if !chip.isEmpty {
                    Text(chip.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(spacing: 0) {
                editor()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    Spacer()
                    Text(hint)
                        .font(Metrics.captionFont)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Metrics.editorInset)
                .padding(.bottom, 6)

                notice()
                GlassDivider()
                footer()
                    .padding(.horizontal, 12)
                    .frame(height: Metrics.footerHeight)
            }
            .background(scheme.wash.opacity(glass.paneTint))
            .glassCard(isActive: isActive)
        }
    }
}

// MARK: - History strip (§6.5)

struct HistoryStrip: View {
    @Bindable var model: ConversationModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.historyExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.historyExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("History · turn \(model.turn) of \(max(model.turn, model.history.count))")
                            .font(Metrics.captionFont)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Spacer()

                Button("Export…") { exportTranscript() }
                    .buttonStyle(.link)
                    .font(Metrics.captionFont)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.history.isEmpty)
            }
            .padding(.horizontal, Metrics.outerPadding)
            .frame(height: Metrics.historyCollapsedHeight)

            if model.historyExpanded {
                List(model.history) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(entry.id)")
                            .font(Metrics.captionFont.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .trailing)
                        Text(entry.prompt).lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(entry.responsePreview).lineLimit(1).foregroundStyle(.secondary)
                        if entry.responseWasEdited {
                            Text("(edited)").font(Metrics.captionFont).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.showHistoryTurn(entry.id) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(height: Metrics.historyExpandedHeight)
            }
        }
    }

    private func exportTranscript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "VoiceChat transcript.md"
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // R-UI-14 / R-SEC-2 — the only path by which conversation content
        // reaches disk.
        try? model.transcriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Bars

struct TerminalBanner: View {
    let text: String
    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle")
            Text(text)
            Spacer()
        }
        .font(.system(size: 13, weight: .medium))
        .accentBar()
    }
}

struct HistoryPeekBar: View {
    let onReturn: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
            Text("Viewing an earlier turn — edit the prompt and send to reuse it.")
            Spacer()
            Button("Return to current turn", action: onReturn)
        }
        .font(.system(size: 12))
        .accentBar()
    }
}
