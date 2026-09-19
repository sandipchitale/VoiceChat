import Foundation

// Spec §9.2 — speech is derived from the pane's attributed content, so the
// renderer records what each run *was* in Markdown terms. Without this a code
// block and an inline code span are indistinguishable after rendering (both
// end up mono on a tinted background), and the two are read aloud very
// differently.

public extension NSAttributedString.Key {
    static let vcBlockKind = NSAttributedString.Key("dev.sandipchitale.voicechat.blockKind")
}

public enum VCBlockKind: String, Sendable, Equatable {
    case body
    case heading
    case listItem
    case blockQuote
    case codeBlock
    case inlineCode
    case link
}

public extension NSAttributedString.Key {
    /// Marks the interim recognition hypothesis shown at the caret. It lives in
    /// the text storage only so it can be drawn inline; it is stripped before
    /// anything is published, sent or serialised (R-UI-6, R-STT-7).
    static let vcVolatile = NSAttributedString.Key("dev.sandipchitale.voicechat.volatile")
}
