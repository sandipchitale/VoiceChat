import AppKit
import VoiceChatKit

// Spec §8.5 / §15.2 — the live `TextDocument` adapter over a real `NSTextView`.
// `TextCommandExecutor` computes every unit boundary, phrase range and count
// against `text` + `selectedRange` alone (R-ARCH-5), so this file only has to
// supply the handful of primitives that genuinely need AppKit: mutation with
// undo registration (R-STT-15), the native correction panel (`showGuessPanel:`,
// per `Commands and Dictation.md`), the clipboard, and scrolling.
//
// `TextDocument` is a plain (non-isolated) protocol so the in-memory test double
// can conform without AppKit. The one concrete conformer that touches AppKit is
// only ever driven from `ConversationModel` (the main actor), so each requirement
// is satisfied `nonisolated` and hops onto the main actor with
// `MainActor.assumeIsolated` — correct at runtime because there is no other
// caller.
public final class NSTextViewDocument: TextDocument, @unchecked Sendable {

    nonisolated(unsafe) private weak var textView: NSTextView?

    @MainActor
    public init(_ textView: NSTextView) {
        self.textView = textView
    }

    // MARK: Observable state

    public var text: String {
        MainActor.assumeIsolated { textView?.string ?? "" }
    }

    public var selectedRange: NSRange {
        get { MainActor.assumeIsolated { textView?.selectedRange() ?? NSRange(location: 0, length: 0) } }
        set { MainActor.assumeIsolated { textView?.setSelectedRange(clampedToText(newValue)) } }
    }

    // MARK: Mutation (undoable — R-STT-15)

    public func replaceCharacters(in range: NSRange, with string: String) {
        edit(range, replacement: string, actionName: string.isEmpty ? "Delete" : "Replace")
    }

    public func setCase(_ transform: CaseTransform, on range: NSRange) {
        MainActor.assumeIsolated {
            guard let textView else { return }
            let original = (textView.string as NSString).substring(with: clampedToText(range))
            edit(range, replacement: Self.applyCase(transform, to: original), actionName: "Change Case")
        }
    }

    public func setFormatting(_ trait: FormattingTrait, on range: NSRange) {
        MainActor.assumeIsolated {
            guard let textView, let storage = textView.textStorage else { return }
            let range = clampedToText(range)
            guard range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.beginEditing()
            switch trait {
            case .underline:
                storage.addAttribute(.underlineStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: range)
            case .bold, .italic:
                let fontTrait: NSFontTraitMask = trait == .bold ? .boldFontMask : .italicFontMask
                storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let base = (value as? NSFont) ?? Metrics.bodyFont
                    let restyled = NSFontManager.shared.convert(base, toHaveTrait: fontTrait)
                    storage.addAttribute(.font, value: restyled, range: subrange)
                }
            }
            storage.endEditing()
            textView.didChangeText()
            textView.undoManager?.setActionName(trait == .underline ? "Underline" : (trait == .bold ? "Bold" : "Italicise"))
        }
    }

    // MARK: Native panels and clipboard

    public func showCorrectionPanel(for range: NSRange) {
        MainActor.assumeIsolated {
            guard let textView else { return }
            textView.setSelectedRange(clampedToText(range))
            // `showGuessPanel:` is the native spelling/grammar replacement panel,
            // as `Commands and Dictation.md` specifies for "Correct".
            textView.showGuessPanel(nil)
        }
    }

    public func cut(_ range: NSRange) {
        MainActor.assumeIsolated {
            guard let textView else { return }
            textView.setSelectedRange(clampedToText(range))
            textView.cut(nil)
        }
    }

    public func copy(_ range: NSRange) {
        MainActor.assumeIsolated {
            guard let textView else { return }
            textView.setSelectedRange(clampedToText(range))
            textView.copy(nil)
        }
    }

    public func pasteAtCaret() {
        MainActor.assumeIsolated { textView?.paste(nil) }
    }

    public func performUndo() {
        MainActor.assumeIsolated { textView?.undoManager?.undo() }
    }

    public func performRedo() {
        MainActor.assumeIsolated { textView?.undoManager?.redo() }
    }

    public func scroll(_ target: ScrollTarget) {
        MainActor.assumeIsolated {
            guard let textView else { return }
            switch target {
            case .up:       textView.scrollPageUp(nil)
            case .down:     textView.scrollPageDown(nil)
            case .toTop:    textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            case .toBottom: textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
    }

    // MARK: Helpers

    /// One undoable, delegate-notifying edit. `shouldChangeText`/`didChangeText`
    /// register the change with the view's own `UndoManager`, so "Undo that"
    /// (which routes through `performUndo`) reverses exactly this step.
    private func edit(_ range: NSRange, replacement: String, actionName: String) {
        MainActor.assumeIsolated {
            guard let textView, let storage = textView.textStorage else { return }
            let range = clampedToText(range)
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            storage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            textView.undoManager?.setActionName(actionName)
        }
    }

    private func clampedToText(_ range: NSRange) -> NSRange {
        let length = MainActor.assumeIsolated { (textView?.string as NSString?)?.length ?? 0 }
        let location = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, location), length)
        return NSRange(location: location, length: end - location)
    }

    private static func applyCase(_ transform: CaseTransform, to text: String) -> String {
        switch transform {
        case .capitalize: return text.capitalized
        case .lower:      return text.lowercased()
        case .upper:      return text.uppercased()
        }
    }
}
