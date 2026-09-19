import AppKit
import SwiftUI

// Spec R-TXT-1 — both panes are NSTextView over TextKit 2, holding attributed
// text. The command dispatcher of phase 4 drives exactly this view, so it is
// built on the real text system from the start rather than on TextEditor.

public struct RichTextView: NSViewRepresentable {
    @Binding var text: NSAttributedString
    var isEditable: Bool
    /// R-FSM-6 — focus follows state, so the person can start typing or
    /// dictating the moment a turn begins.
    var wantsFocus: Bool
    /// Useful while composing; noise over a model response, where every code
    /// identifier gets flagged as a misspelling.
    var spellChecking: Bool
    /// R-UI-8 — the sentence currently being spoken. Applied as a TextKit 2
    /// rendering attribute, so it never enters the text storage and can never
    /// be sent, serialised or undone.
    var highlightRange: NSRange?
    /// R-UI-6 — interim speech shown at the caret, never part of the document.
    var ghost: String
    var placeholder: String
    var onFocus: () -> Void
    /// Typing discards any pending speech hypothesis: the person has taken
    /// over, and a half-recognised phrase must never merge into what they wrote.
    var onUserEdit: () -> Void
    /// R-STT-16 — hands the live `NSTextView` back so command-mode edits can be
    /// applied to the focused pane's real document.
    var onMakeTextView: (NSTextView) -> Void
    /// Fires on any change to the view's text — user typing, paste, or a
    /// command-mode edit. Lets the prompt pane leave command mode the moment the
    /// person starts typing.
    var onEdit: () -> Void
    /// A one-shot caret position requested by the model after it edits the text
    /// programmatically (dictation). Applied once, then ignored until it changes.
    var caretRequest: NSRange?

    public init(text: Binding<NSAttributedString>,
                isEditable: Bool,
                wantsFocus: Bool = false,
                spellChecking: Bool = true,
                highlightRange: NSRange? = nil,
                ghost: String = "",
                placeholder: String = "",
                onFocus: @escaping () -> Void = {},
                onUserEdit: @escaping () -> Void = {},
                onMakeTextView: @escaping (NSTextView) -> Void = { _ in },
                onEdit: @escaping () -> Void = {},
                caretRequest: NSRange? = nil) {
        self._text = text
        self.isEditable = isEditable
        self.wantsFocus = wantsFocus
        self.spellChecking = spellChecking
        self.highlightRange = highlightRange
        self.ghost = ghost
        self.placeholder = placeholder
        self.onFocus = onFocus
        self.onUserEdit = onUserEdit
        self.onMakeTextView = onMakeTextView
        self.onEdit = onEdit
        self.caretRequest = caretRequest
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true                      // R-STT-15
        textView.textContainerInset = NSSize(width: Metrics.editorInset,
                                             height: Metrics.editorInset)
        textView.font = Metrics.bodyFont
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = spellChecking
        textView.textColor = .labelColor
        textView.insertionPointColor = .systemCyan

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        context.coordinator.textView = textView
        context.coordinator.apply(text, ghost: ghost)
        onMakeTextView(textView)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isContinuousSpellCheckingEnabled = spellChecking
        textView.isGrammarCheckingEnabled = spellChecking
        if !context.coordinator.isEditing,
           context.coordinator.documentDiffers(from: text, ghost: ghost) {
            context.coordinator.apply(text, ghost: ghost)
        }
        context.coordinator.placeholder = placeholder
        context.coordinator.applyFocus(wantsFocus: wantsFocus, isEditable: isEditable)
        context.coordinator.applyCaretRequest(caretRequest)
        context.coordinator.applyHighlight(highlightRange)
        context.coordinator.noteGhost(ghost)
        textView.needsDisplay = true
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextView
        weak var textView: NSTextView?
        var isEditing = false
        var placeholder = ""
        private var hadFocusRequest = false
        private var lastHighlight: NSRange?
        private var lastCaretRequest: NSRange?

        func noteGhost(_ ghost: String) { currentGhost = ghost }

        init(_ parent: RichTextView) { self.parent = parent }

        /// Applies a model-requested caret once (after the text it refers to has
        /// been applied), so dictation lands the caret after the inserted text
        /// rather than where the replaced selection was. Runs after `apply`.
        func applyCaretRequest(_ request: NSRange?) {
            guard let request, request != lastCaretRequest, let textView else {
                lastCaretRequest = request
                return
            }
            lastCaretRequest = request
            let length = (textView.string as NSString).length
            let location = min(max(request.location, 0), length)
            let len = min(request.length, length - location)
            textView.setSelectedRange(NSRange(location: location, length: len))
        }

        func apply(_ value: NSAttributedString, ghost: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let selected = textView.selectedRange()
            let composed = NSMutableAttributedString(attributedString: value)
            if !ghost.isEmpty {
                let joiner = value.length == 0 || value.string.hasSuffix(" ") ? "" : " "
                composed.append(NSAttributedString(string: joiner + ghost, attributes: [
                    .font: Metrics.bodyFont,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .vcVolatile: true,
                ]))
            }
            storage.setAttributedString(composed)
            // Preserve the whole selection, not just the caret — a command-mode
            // "Select word/all/…" sets a ranged selection, and re-applying the
            // text (e.g. when the interim hypothesis clears) must not collapse it.
            let loc = min(selected.location, value.length)
            let len = min(selected.length, value.length - loc)
            textView.setSelectedRange(NSRange(location: loc, length: len))
        }

        /// The document carries the ghost run, so compare against what we would
        /// have written rather than against the committed text alone.
        func documentDiffers(from value: NSAttributedString, ghost: String) -> Bool {
            guard let textView else { return true }
            return Self.stripVolatile(textView.attributedString()) != value || currentGhost != ghost
        }

        private var currentGhost = ""

        /// R-UI-6 — the hypothesis never reaches the published text.
        static func stripVolatile(_ text: NSAttributedString) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: text)
            var ranges: [NSRange] = []
            result.enumerateAttribute(.vcVolatile,
                                      in: NSRange(location: 0, length: result.length)) { value, range, _ in
                if value != nil { ranges.append(range) }
            }
            for range in ranges.reversed() { result.deleteCharacters(in: range) }
            return result
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isEditing = true
            parent.text = stripped(textView.attributedString())
            isEditing = false
            // Second defence, and the one that actually holds: the hypothesis
            // is abandoned the instant the person edits.
            if !currentGhost.isEmpty {
                currentGhost = ""
                parent.onUserEdit()
            }
            parent.onEdit()
        }

        /// Removes the hypothesis by attribute, and falls back to removing it
        /// by value if an edit stripped the marker off the run.
        private func stripped(_ text: NSAttributedString) -> NSAttributedString {
            let byAttribute = Self.stripVolatile(text)
            guard !currentGhost.isEmpty else { return byAttribute }
            let plain = byAttribute.string
            for candidate in [" " + currentGhost, currentGhost] where plain.hasSuffix(candidate) {
                let result = NSMutableAttributedString(attributedString: byAttribute)
                result.deleteCharacters(in: NSRange(location: byAttribute.length - candidate.count,
                                                    length: candidate.count))
                return result
            }
            return byAttribute
        }

        public func textDidBeginEditing(_ notification: Notification) {
            parent.onFocus()
        }

        func applyHighlight(_ range: NSRange?) {
            guard let textView, let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager else { return }
            guard range != lastHighlight else { return }
            lastHighlight = range

            layoutManager.removeRenderingAttribute(.backgroundColor,
                                                   for: contentManager.documentRange)
            guard let range, range.length > 0,
                  let textRange = Self.textRange(range, in: contentManager) else { return }
            layoutManager.addRenderingAttribute(
                .backgroundColor,
                value: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35),
                for: textRange)
            textView.scrollRangeToVisible(range)
        }

        private static func textRange(_ range: NSRange,
                                      in contentManager: NSTextContentManager) -> NSTextRange? {
            let documentStart = contentManager.documentRange.location
            guard let start = contentManager.location(documentStart, offsetBy: range.location),
                  let end = contentManager.location(start, offsetBy: range.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }

        /// Claim first responder when the pane becomes the active one, and
        /// never fight the person for it afterwards.
        ///
        /// The view is not in a window yet on the first update pass, so this
        /// retries briefly rather than giving up — a turn that opens with no
        /// insertion point means the person has to click before they can type.
        func applyFocus(wantsFocus: Bool, isEditable: Bool) {
            guard wantsFocus, isEditable else { hadFocusRequest = false; return }
            guard !hadFocusRequest else { return }
            hadFocusRequest = true
            claimFirstResponder(attemptsLeft: 20)
        }

        private func claimFirstResponder(attemptsLeft: Int) {
            guard attemptsLeft > 0 else { hadFocusRequest = false; return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let textView = self.textView else { return }
                guard let window = textView.window else {
                    self.claimFirstResponder(attemptsLeft: attemptsLeft - 1)
                    return
                }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        }
    }
}

/// A pane's placeholder, drawn behind the text view when it is empty. Kept out
/// of the text storage so it can never be sent or spoken.
public struct PlaceholderOverlay: View {
    let text: String
    let isVisible: Bool

    public init(text: String, isVisible: Bool) {
        self.text = text
        self.isVisible = isVisible
    }

    public var body: some View {
        if isVisible {
            Text(text)
                .font(.system(size: Metrics.bodyPointSize))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Metrics.editorInset + 5)
                .padding(.vertical, Metrics.editorInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }
}
