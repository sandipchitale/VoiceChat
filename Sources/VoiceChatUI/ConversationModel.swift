import AppKit
import Observation
import SwiftUI
import VoiceChatKit

// Spec §5 — the window derives every control from the state machine. Nothing
// in the view layer sets a control directly.

public struct HistoryTurn: Identifiable, Sendable {
    public let id: Int
    public var prompt: String
    /// Raw Markdown as received, for export (R-TXT-9).
    public var response: String
    /// Rendered text, for the one-line preview in the strip.
    public var responsePreview: String
    public var responseWasEdited: Bool

    public init(id: Int, prompt: String, response: String,
                responsePreview: String, responseWasEdited: Bool = false) {
        self.id = id
        self.prompt = prompt
        self.response = response
        self.responsePreview = responsePreview
        self.responseWasEdited = responseWasEdited
    }
}

@MainActor
@Observable
public final class ConversationModel {

    // MARK: State

    public private(set) var machine = SessionMachine()
    public var promptText = NSAttributedString(string: "")
    public var responseText = NSAttributedString(string: "")
    public private(set) var history: [HistoryTurn] = []
    public var historyExpanded = false
    public var selectedHistoryTurn: Int?
    public private(set) var receivedResponse: String = ""
    /// R-UI-8 — the sentence currently being spoken.
    public private(set) var highlightRange: NSRange?
    /// R-UI-6 — interim hypothesis, shown but never committed.
    public private(set) var volatileText: String = ""
    /// The live interim (and last) command, shown in the command box while in
    /// command mode. Kept out of the pane so command speech never scrambles the
    /// real text (unlike the pane ghost used for dictation).
    public private(set) var commandLine: String = ""
    public private(set) var micLevel: Float = 0
    public private(set) var micStatus: String = ""
    /// R-STT-26 — drives the inline affordance, not a modal alert.
    public private(set) var micDenied = false
    /// R-STT-11 — an unrecognised command is reported, never typed.
    public private(set) var commandToast: String?
    /// The rendered text as first shown. Comparing the pane against the raw
    /// Markdown instead would mark every formatted response as edited.
    private var presentedResponse: String = ""
    /// The response pane is still showing the last turn's answer, kept as
    /// read-only context while the person composes a reply. Replaced as soon
    /// as the next response arrives.
    public private(set) var responseIsPrevious = false
    /// Previous-turn context is dimmed, except while peeking at history, where
    /// the pane shows that turn's own response instead.
    public var showsPreviousResponse: Bool { responseIsPrevious && !isViewingHistory }

    /// R-UI-29 — the folders the host says this conversation is about, shown
    /// in the bottom bar. Empty when the host reports no roots, or does not
    /// support them at all.
    public private(set) var roots: [WorkspaceRoot] = []

    public func setRoots(_ roots: [WorkspaceRoot]) { self.roots = roots }

    /// Set while this window is a seat in a debate; drives the debate bar.
    public var debate: DebateBadge?
    /// The debate bar's two moderator actions, wired by the session.
    public var onDebateSkipTurn: (() -> Void)?
    public var onDebateEnd: (() -> Void)?

    /// R-DEB-10 — when on, a statement arriving in this window is passed to
    /// its debater without waiting for Send. Per window, so one side can run
    /// itself while the other is still moderated by hand.
    public var debateAutoHandoff = false {
        didSet {
            guard debateAutoHandoff, oldValue != debateAutoHandoff else { return }
            // Switching it on with a statement already waiting sends that one
            // too, rather than stranding it until the next handover.
            if debate?.awaitingSend == true, canSend { send() }
        }
    }

    public var hostName: String?
    /// The last path component of the host's working directory, if known — the
    /// "project" this conversation belongs to.
    public var projectName: String?
    /// The host's full working directory, tilde-abbreviated, shown as a tooltip.
    public var workingDirectory: String?
    public private(set) var terminalBanner: String?

    /// The model driving the conversation, if the caller supplied one. May
    /// change turn to turn.
    public var currentModel: String?

    /// Model and host (e.g. "claude-opus-5 · Claude Code") when either is
    /// known, else `nil`. Shown as a short badge in the window header.
    public var identityBadge: String? {
        switch (currentModel, hostName) {
        case let (model?, host?): return "\(model) · \(host)"
        case let (model?, nil):   return model
        case let (nil, host?):    return host
        case (nil, nil):          return nil
        }
    }

    /// Host and project together when either is known, else `nil`. Used where a
    /// missing identity should fall back to a generic label (e.g. the window
    /// title).
    public var sessionIdentity: String? {
        switch (hostName, projectName) {
        case let (host?, project?): return "\(host) — \(project)"
        case let (host?, nil):      return host
        case let (nil, project?):   return project
        case (nil, nil):            return nil
        }
    }

    /// Always-present label for chrome that must show something (menu, footer).
    public var sessionDisplayName: String { sessionIdentity ?? "Voice conversation" }

    /// Phase 2 installs a speech controller here. Until then responses land in
    /// `Responding.Manual` by way of R-UI-24's auto-play-off path, so a turn is
    /// still readable and still needs an explicit "Got it!".
    public var speechAvailable = false {
        didSet { machine.autoPlayEnabled = speechAvailable }
    }

    // MARK: Hooks into the session

    public var onSubmitPrompt: ((String) -> Void)?
    public var onEnd: ((EndReason) -> Void)?
    /// A person-initiated dismissal of a window that has already ended —
    /// independent of the state machine, so it always works even once
    /// `canEnd` has gone false.
    public var onRequestClose: (() -> Void)?
    /// Driven only from SessionTransition effects, never ad hoc, so the
    /// microphone interlock of R-TTS-4 cannot be broken by a missed call site.
    public var onRecognizer: ((RecognizerAction) -> Void)?
    public var onStartSpeech: ((NSAttributedString, NSRange?) -> Void)?
    public var onStopSpeech: (() -> Void)?
    /// A turn just completed: `statement` is the response as it was read out,
    /// and `turn` is the turn it belonged to. Fires for every advancing row —
    /// speech finishing, "Got it!", and an empty response — so a caller that
    /// relays a finished answer elsewhere cannot be stranded by a turn that
    /// advanced without speech (R-DEB-1).
    public var onTurnAdvanced: ((_ statement: String, _ turn: Int) -> Void)?

    public func setHighlight(_ range: NSRange?) { highlightRange = range }

    /// `micEnabled` starts false only where speech input makes no sense — a
    /// debate seat, whose turns arrive as text from the other seat. Opening
    /// such a window with the mic live would take the microphone and raise a
    /// permission prompt for a window that will never listen.
    public init(micEnabled: Bool = true) {
        machine.autoPlayEnabled = speechAvailable
        // R-STT-8 — a turn starts in dictation mode with the mic live. The
        // permission prompt therefore lands on first use, not at launch.
        machine.micEnabled = micEnabled
    }

    // MARK: Derived (§6.1, §6.6)

    public var state: SessionState { machine.state }
    public var turn: Int { machine.turn }
    public var isViewingHistory: Bool { selectedHistoryTurn != nil }

    public var windowSubtitle: String {
        if let terminalBanner { return terminalBanner }
        switch machine.state {
        case .idle:              return ""
        case .composing:         return machine.recognizerShouldRun ? "Listening" : "Composing"
        case .submitted:         return "Waiting for the assistant…"
        case .respondingAuto:    return "Speaking"
        case .respondingManual:  return machine.isSpeaking ? "Speaking" : "Paused"
        case .ended:             return "Conversation ended"
        }
    }

    public var promptStatusText: String {
        switch machine.state {
        case .composing: return machine.recognizerShouldRun ? "Listening…" : "Ready"
        case .submitted: return "Sent"
        default:         return ""
        }
    }

    public var responseStatusText: String {
        switch machine.state {
        case .submitted:        return "Waiting…"
        case .respondingAuto:   return "Speaking…"
        case .respondingManual: return machine.isSpeaking ? "Speaking…" : "Paused"
        case .composing:        return responseIsPrevious ? "Previous response" : ""
        default:                return ""
        }
    }

    public var focusedPane: SessionMachine.Pane { machine.focusedPane }

    /// R-UI-12-adjacent — the prompt pane stays editable while peeking at an
    /// earlier turn, so that turn's prompt can be revised and resent as a new
    /// one. The response pane does not: what was already said is immutable.
    public var promptIsEditable: Bool { machine.state == .composing }
    /// Only a response that has actually arrived can be edited: text typed
    /// into an empty pane before then is never sent, played or kept.
    public var responseIsEditable: Bool {
        machine.state.isResponding && !isViewingHistory && !responseIsPrevious
    }

    /// Says what the empty pane is for, without inviting typing into it.
    public var responsePlaceholder: String {
        machine.state == .submitted ? "Waiting for the response…" : "The response will appear here."
    }

    public var canSend: Bool {
        machine.state == .composing && !plainPrompt.trimmed.isEmpty
    }
    public var canPlay: Bool {
        machine.state == .respondingManual && !machine.isSpeaking && !isViewingHistory
    }
    public var canStop: Bool { machine.isSpeaking }
    public var canGotIt: Bool { machine.state.isResponding && !isViewingHistory }
    public var canEnd: Bool { !machine.state.isTerminal }
    /// Mirrors `promptIsEditable`: peeking at history is just another way of
    /// having text in the prompt pane, not a different mode, so dictation
    /// stays available exactly as it would while typing fresh.
    public var canToggleMic: Bool {
        machine.state == .composing || machine.state == .respondingManual
    }
    public var canChangeVoiceMode: Bool { canToggleMic && micEnabled }

    /// Set by the response pane so Play can honour a selection.
    public var responseSelection: NSRange?

    /// One-shot caret placement requested after a model-driven edit (dictation).
    /// The pane's view applies it once, so the caret lands after inserted text
    /// instead of where the old selection was.
    public var promptCaretRequest: NSRange?
    public var responseCaretRequest: NSRange?

    public var plainPrompt: String { promptText.string }
    public var plainResponse: String { responseText.string }

    // MARK: Actions

    /// Row 1 of §5.2.
    public func open() {
        apply(machine.handle(.sessionOpened), beforeTurn: machine.turn)
    }

    /// The single place session effects reach the outside world.
    ///
    /// Ordering matters and is load-bearing: the recogniser is torn down
    /// *before* the first utterance is enqueued, and only brought back once
    /// everything else has settled (R-TTS-4, R-TTS-9).
    private func apply(_ transition: SessionTransition, beforeTurn: Int) {
        if transition.effects.recognizer == .stop { onRecognizer?(.stop) }

        switch transition.effects.speech {
        case .stop:
            onStopSpeech?()
            highlightRange = nil
        case .start:
            onStartSpeech?(responseText, responseSelection)
        case .unchanged:
            break
        }

        if transition.effects.advancesTurn {
            // `commitTurn` clears `receivedResponse`, so the statement is read
            // out of the model first.
            let statement = spokenStatement()
            commitTurn(number: beforeTurn)
            if let onTurnAdvanced {
                // Deferred a tick: a relay handler drives *another* model's
                // send() synchronously, and this transition's own effects —
                // including the recogniser restart below — must finish first.
                Task { @MainActor in onTurnAdvanced(statement, beforeTurn) }
            }
        }

        if case .start = transition.effects.recognizer {
            onRecognizer?(transition.effects.recognizer)
        }
    }

    public func send() {
        clearVolatile()
        let text = plainPrompt.trimmed
        let before = machine.turn
        let transition = machine.handle(.send(isEmpty: text.isEmpty))
        if transition.effects.rejectsEmptySend {          // R-UI-7
            commandToast = "Nothing to send yet"
            return
        }
        if selectedHistoryTurn != nil {
            // Sending a revised past prompt supersedes the draft it was
            // shielding — restoring it on "return to current turn" would
            // silently discard what was just sent.
            selectedHistoryTurn = nil
            draftPrompt = NSAttributedString(string: "")
            draftResponse = NSAttributedString(string: "")
            // The past turn's response stays on screen as context for the
            // revised prompt, like any other previous response.
            responseIsPrevious = !plainResponse.isEmpty
        }
        apply(transition, beforeTurn: before)
        if transition.effects.submitsPrompt { onSubmitPrompt?(text) }
    }

    /// A response arrived over VCP (§5.2 row 6 / row 7).
    public func present(response markdown: String) {
        let isEmpty = markdown.trimmed.isEmpty
        receivedResponse = markdown
        // The previous turn's response gives way to this one — or to nothing,
        // so an empty response never leaves stale text standing in for it.
        responseIsPrevious = false
        responseText = isEmpty ? NSAttributedString(string: "")
                               : MarkdownRenderer.attributed(from: markdown)
        presentedResponse = isEmpty ? "" : responseText.string
        let before = machine.turn
        apply(machine.handle(.responseReceived(isEmpty: isEmpty)), beforeTurn: before)
    }

    public func play() {
        guard canPlay else { return }
        apply(machine.handle(.play), beforeTurn: machine.turn)   // R-TTS-15
    }

    public func stop() {
        guard canStop else { return }
        apply(machine.handle(.stop), beforeTurn: machine.turn)
    }

    public func speechFinished() {
        highlightRange = nil
        let before = machine.turn
        apply(machine.handle(.speechFinished), beforeTurn: before)
    }

    public func gotIt() {
        guard canGotIt else { return }
        let before = machine.turn
        apply(machine.handle(.gotIt), beforeTurn: before)
    }

    public func end(_ reason: EndReason) {
        guard canEnd else { return }
        clearVolatile()
        apply(machine.handle(.end(reason)), beforeTurn: machine.turn)
        terminalBanner = Self.banner(for: reason)
        onEnd?(reason)
    }

    /// R-UI-20-adjacent — a terminal window must always be dismissable, not
    /// just for the four seconds of the auto-close window and not only while
    /// the history strip happens to be collapsed.
    public func closeWindow() { onRequestClose?() }

    /// Driven by the peer, not by the person — no confirmation, no callback back
    /// out (R-VCP-15).
    public func endedByPeer(_ reason: EndReason) {
        guard canEnd else { return }
        clearVolatile()
        apply(machine.handle(.end(reason)), beforeTurn: machine.turn)
        terminalBanner = Self.banner(for: reason)
    }

    // MARK: Voice input (§8)

    public var voiceMode: VoiceMode { machine.voiceMode }
    public var micEnabled: Bool { machine.micEnabled }
    public var recognizerShouldRun: Bool { machine.recognizerShouldRun }

    public func setMicEnabled(_ on: Bool) {
        apply(machine.handle(.setMicEnabled(on)), beforeTurn: machine.turn)
    }

    /// R-STT-10 — the control, the keyboard and the spoken phrase all drive the
    /// same single mode variable.
    public func setVoiceMode(_ mode: VoiceMode) {
        apply(machine.handle(.setVoiceMode(mode)), beforeTurn: machine.turn)
        // No interim should carry across a mode switch: the pane ghost and the
        // command box both start clean.
        volatileText = ""
        commandLine = ""
    }

    public func setMicLevel(_ level: Float) { micLevel = level }
    public func setMicStatus(_ status: String) { micStatus = status }
    public func setMicDenied(_ denied: Bool) { micDenied = denied }

    /// R-UI-6 — interim text, replaced in place and never committed. In command
    /// mode it goes to the command box (`commandLine`), never the pane ghost, so
    /// command speech cannot scramble the real text.
    public func setVolatile(_ text: String) {
        if voiceMode == .command {
            commandLine = text
            if !volatileText.isEmpty { volatileText = "" }
        } else {
            volatileText = text
        }
    }
    public func clearVolatile() { volatileText = "" }

    public func dismissToast() { commandToast = nil }

    public let vocabulary = VocabularyStore()
    /// Lets the session push the updated phrase list to the recogniser.
    public var onVocabularyChanged: (([String]) -> Void)?

    /// A finalised recognition result (R-STT-6).
    public func handleFinalUtterance(_ utterance: String) {
        clearVolatile()
        // In command mode the box shows the last command that was heard; errors
        // still surface via the toast. Dictation never touches the box.
        if voiceMode == .command {
            commandLine = utterance.trimmed
        }
        guard let command = VoiceCommandRouter.route(utterance, mode: voiceMode) else {
            insertDictated(utterance)
            return
        }
        switch command {
        case .setMode(let mode):
            setVoiceMode(mode)
        case .sendPrompt:
            run("Send prompt", available: canSend, action: send)
        case .stop:
            run("Stop", available: canStop, action: stop)
        case .play:
            run("Play", available: canPlay, action: play)
        case .gotIt:
            run("Got it", available: canGotIt, action: gotIt)
        case .insertDate:
            insertDictated(DateFormatter.localizedString(from: Date(),
                                                         dateStyle: .long, timeStyle: .none))
        case .pressReturn:
            appendVerbatim("\n")
        case .pressEscape:
            // Dismisses the pending hypothesis and any transient message, which
            // is the only thing there is to dismiss in this window.
            clearVolatile()
            commandToast = nil
        case .addToVocabulary:
            addSelectionToVocabulary()
        case .typeVerbatim(let phrase):
            appendVerbatim(phrase)
        case .emoji(let name):
            if let emoji = EmojiLexicon.emoji(named: name) {
                appendVerbatim(emoji)
            } else {
                // Unknown name: dictate it literally rather than swallow it.
                insertDictated(name)
            }
        case .unrecognised(let normalized):
            // Groups 3-6 of R-STT-14 — selection, navigation, editing and
            // deletion. These arrive here (never as their own `VoiceCommand`)
            // and are parsed and applied to the focused pane's live document.
            // Only a genuinely unparseable phrase becomes an unrecognised toast
            // (R-STT-11 — reported, never typed).
            if let command = TextCommandParser.parse(normalized, original: utterance) {
                applyEditCommand(command)
            } else {
                commandToast = "Unrecognised command: \u{201C}\(normalized)\u{201D}"
            }
        }
    }

    // MARK: Command-mode structural editing (§8.5, groups 3-6)

    /// The live `NSTextView` backing each pane, registered by the view layer so
    /// command-mode edits (R-STT-16) can drive the focused pane's real document
    /// — selection, undo (R-STT-15), the correction panel and the clipboard all
    /// need the view, not just the attributed string.
    private weak var promptTextView: NSTextView?
    private weak var responseTextView: NSTextView?
    /// True only while a parsed voice command is being applied, so the text
    /// change it produces is not mistaken for the person typing.
    private var isApplyingVoiceCommand = false

    public func registerTextView(_ pane: SessionMachine.Pane, _ textView: NSTextView) {
        switch pane {
        case .prompt:   promptTextView = textView
        case .response: responseTextView = textView
        }
    }

    /// The person typed or pasted into the prompt while composing. If a voice
    /// command isn't driving the edit and command mode is active, hand control
    /// back to dictation immediately — typing is dictation, not commanding.
    public func promptDidEdit() {
        guard !isApplyingVoiceCommand,
              machine.state == .composing,
              voiceMode == .command else { return }
        setVoiceMode(.dictation)
    }

    private func documentForFocusedPane(requiresEditable: Bool) -> TextDocument? {
        if requiresEditable {
            let editable = focusedPane == .prompt ? promptIsEditable : responseIsEditable
            guard editable else { return nil }
        }
        guard let textView = focusedPane == .prompt ? promptTextView : responseTextView else { return nil }
        // Selection and caret changes only render when the pane is first
        // responder, so claim focus for the pane the command is aimed at.
        if textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
        return NSTextViewDocument(textView)
    }

    /// R-STT-17 — a command that parsed but cannot act right now (nothing
    /// selected, phrase absent) reads differently from one never understood.
    private func applyEditCommand(_ command: EditCommand) {
        guard let document = documentForFocusedPane(requiresEditable: command.isMutating) else {
            commandToast = command.isMutating ? "This pane can't be edited right now"
                                              : "Nothing to act on here right now"
            return
        }
        isApplyingVoiceCommand = true
        defer { isApplyingVoiceCommand = false }
        switch TextCommandExecutor.apply(command, to: document) {
        case .ok:
            break
        case .phraseNotFound(let phrase):
            commandToast = "Couldn't find \u{201C}\(phrase)\u{201D}"
        case .nothingSelected:
            commandToast = "Nothing is selected"
        case .notApplicable(let reason):
            commandToast = reason
        }
    }

    /// R-STT-17 — a correctly spoken command that cannot run right now reads
    /// differently from one that was not understood at all.
    private func run(_ name: String, available: Bool, action: () -> Void) {
        guard available else {
            commandToast = "\(name) is not available right now"
            return
        }
        action()
    }

    /// R-STT-19 — the last word of the focused pane joins the user vocabulary.
    private func addSelectionToVocabulary() {
        let source = focusedPane == .prompt ? plainPrompt : plainResponse
        guard let last = source.split(whereSeparator: { $0.isWhitespace }).last else {
            commandToast = "Nothing to add to the vocabulary"
            return
        }
        let phrase = vocabulary.add(String(last)).first ?? String(last)
        onVocabularyChanged?(vocabulary.load())
        commandToast = "Added \u{201C}\(phrase)\u{201D} to your vocabulary"
    }

    /// `Type <phrase>`, emoji and `Press Return`: inserted verbatim at the
    /// caret, replacing any selection, with no auto-formatting.
    private func appendVerbatim(_ text: String) {
        insert(text, verbatim: true)
    }

    /// Ordinary dictation: inserted at the caret, replacing any selection, and
    /// separated from a preceding word by a space.
    private func insertDictated(_ text: String) {
        insert(text, verbatim: false)
    }

    /// Inserts dictated text the way typing would — honouring the caret and
    /// overwriting any selection in the focused pane. The current selection is
    /// read from the live view; the edit is applied to the model (the source of
    /// truth, so it never collides with the interim-hypothesis ghost), and the
    /// resulting caret is pushed back to the view via a one-shot caret request.
    private func insert(_ text: String, verbatim: Bool) {
        guard !text.isEmpty else { return }
        let target = focusedPane
        guard target == .prompt ? promptIsEditable : responseIsEditable else { return }

        let existing = target == .prompt ? promptText : responseText
        let length = (existing.string as NSString).length

        // Where to insert: the live selection if we have a window, else the end.
        let live = (target == .prompt ? promptTextView : responseTextView)?.selectedRange()
        var range = live ?? NSRange(location: length, length: 0)
        range.location = min(max(range.location, 0), length)
        range.length = min(range.length, length - range.location)

        let leadingSpace = !verbatim && range.location > 0
            && !isWhitespace(existing.string, at: range.location - 1) ? " " : ""
        let insertedText = leadingSpace + text

        let combined = NSMutableAttributedString(attributedString: existing)
        combined.replaceCharacters(in: range, with: NSAttributedString(string: insertedText, attributes: [
            .font: Metrics.bodyFont,
            .foregroundColor: NSColor.labelColor,
        ]))
        let caret = NSRange(location: range.location + (insertedText as NSString).length, length: 0)
        if target == .prompt {
            promptText = combined
            promptCaretRequest = caret
        } else {
            responseText = combined
            responseCaretRequest = caret
        }
    }

    private func isWhitespace(_ text: String, at utf16Offset: Int) -> Bool {
        let ns = text as NSString
        guard utf16Offset >= 0, utf16Offset < ns.length else { return true }
        return ns.substring(with: NSRange(location: utf16Offset, length: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: History (§6.5)

    /// What was actually said for this turn: the response as received, or the
    /// person's edit of it if they changed the pane before it was read
    /// (the test `commitTurn` uses for `responseWasEdited`).
    private func spokenStatement() -> String {
        let edited = !presentedResponse.isEmpty && plainResponse != presentedResponse
        return edited ? plainResponse : receivedResponse
    }

    /// Puts `text` in the prompt pane as if it had been typed there, and sends
    /// it when asked. Everything goes through `send()`, so the state machine,
    /// the history commit and the empty-send rejection all still apply —
    /// unlike writing to the turn coordinator directly, which would leave the
    /// window showing one thing and the peer another.
    public func submitPrompt(_ text: String, autoSend: Bool = true) {
        clearVolatile()
        promptText = NSAttributedString(string: text, attributes: [
            .font: Metrics.bodyFont,
            .foregroundColor: NSColor.labelColor,
        ])
        promptCaretRequest = NSRange(location: (text as NSString).length, length: 0)
        if autoSend || debateAutoHandoff { send() }
    }

    private func commitTurn(number: Int) {
        // R-TXT-9 — history records the response as received, not as edited.
        let edited = !presentedResponse.isEmpty && plainResponse != presentedResponse
        history.append(HistoryTurn(id: number,
                                   prompt: plainPrompt.trimmed,
                                   response: receivedResponse,
                                   responsePreview: presentedResponse,
                                   responseWasEdited: edited))
        promptText = NSAttributedString(string: "")
        // The response stays visible, read-only, so the person can see what
        // they are replying to while composing the next prompt.
        responseIsPrevious = !plainResponse.isEmpty
        receivedResponse = ""
        presentedResponse = ""
    }

    public func showHistoryTurn(_ id: Int) {
        guard let entry = history.first(where: { $0.id == id }) else { return }
        if selectedHistoryTurn == nil {
            draftPrompt = promptText
            draftResponse = responseText
        }
        selectedHistoryTurn = id
        promptText = NSAttributedString(string: entry.prompt, attributes: [.font: Metrics.bodyFont])
        responseText = MarkdownRenderer.attributed(from: entry.response)
    }

    /// R-UI-12 — returning restores the draft exactly.
    public func returnToCurrentTurn() {
        guard selectedHistoryTurn != nil else { return }
        selectedHistoryTurn = nil
        promptText = draftPrompt
        responseText = draftResponse
    }

    private var draftPrompt = NSAttributedString(string: "")
    private var draftResponse = NSAttributedString(string: "")

    /// R-UI-19 — confirm only when there is something to lose.
    public var endNeedsConfirmation: Bool {
        !plainPrompt.trimmed.isEmpty || machine.isSpeaking
    }

    public func transcriptMarkdown() -> String {
        var out = "# VoiceChat conversation\n\n"
        if let hostName { out += "_Host: \(hostName)_\n\n" }
        for entry in history {
            out += "## Turn \(entry.id)\n\n**You:**\n\n\(entry.prompt)\n\n**Assistant:**\n\n\(entry.response)\n\n"
        }
        return out
    }

    static func banner(for reason: EndReason) -> String {
        switch reason {
        case .userEnded, .windowClosed: return "Conversation ended."
        case .hostCancelled:            return "The assistant cancelled this conversation."
        case .daemonQuit:               return "VoiceChat is quitting."
        case .mcpExit, .peerLost:       return "VoiceChat lost contact with the assistant."
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
