import AppKit
import Foundation

// Spec §7.2 — Markdown in, attributed text out.
//
// `AttributedString(markdown:)` hands back one flat run sequence with no
// newlines between block elements — paragraphs, headings and list items all
// butt together. So the block structure is rebuilt here from the presentation
// intents, which is also what lets headings, lists, quotes and code blocks
// carry real paragraph styles rather than being styled by guesswork.

public enum MarkdownRenderer {

    // MARK: Entry point

    public static func attributed(from markdown: String) -> NSAttributedString {
        guard !markdown.isEmpty else {
            return NSAttributedString(string: "", attributes: baseAttributes)
        }

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.allowsExtendedAttributes = true
        options.failurePolicy = .returnPartiallyParsedIfPossible

        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: baseAttributes)   // R-TXT-4
        }

        let out = NSMutableAttributedString()
        var previous: [PresentationIntent.IntentType]?

        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }
            let block = run.presentationIntent?.components ?? []

            if let previous {
                if !isSameBlock(previous, block) {
                    out.append(plain(separator(from: previous, to: block)))
                    out.append(plain(marker(for: block)))
                }
            } else {
                out.append(plain(marker(for: block)))
            }

            out.append(styled(text, inline: run.inlinePresentationIntent, block: block))
            previous = block
        }

        applyParagraphStyles(to: out)
        return out
    }

    // MARK: Block structure

    private static func isSameBlock(_ a: [PresentationIntent.IntentType],
                                    _ b: [PresentationIntent.IntentType]) -> Bool {
        a.map(\.identity) == b.map(\.identity)
    }

    /// List items are one line apart; every other block boundary is a blank
    /// line, which is what makes a response readable rather than a wall.
    private static func separator(from a: [PresentationIntent.IntentType],
                                  to b: [PresentationIntent.IntentType]) -> String {
        let sharedList = a.contains { isList($0.kind) }
            && b.contains { isList($0.kind) }
            && a.first(where: { isList($0.kind) })?.identity == b.first(where: { isList($0.kind) })?.identity
        return sharedList ? "\n" : "\n\n"
    }

    private static func isList(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .unorderedList, .orderedList: return true
        default: return false
        }
    }

    /// The visible bullet or number for a list item.
    private static func marker(for block: [PresentationIntent.IntentType]) -> String {
        for component in block {
            if case .listItem(let ordinal) = component.kind {
                let ordered = block.contains { if case .orderedList = $0.kind { return true } else { return false } }
                return ordered ? "\(ordinal). " : "• "
            }
        }
        return ""
    }

    private static func headerLevel(_ block: [PresentationIntent.IntentType]) -> Int? {
        for component in block {
            if case .header(let level) = component.kind { return level }
        }
        return nil
    }

    private static func isCodeBlock(_ block: [PresentationIntent.IntentType]) -> Bool {
        block.contains { if case .codeBlock = $0.kind { return true } else { return false } }
    }

    private static func isBlockQuote(_ block: [PresentationIntent.IntentType]) -> Bool {
        block.contains { if case .blockQuote = $0.kind { return true } else { return false } }
    }

    // MARK: Styling

    private static func styled(_ text: String,
                               inline: InlinePresentationIntent?,
                               block: [PresentationIntent.IntentType]) -> NSAttributedString {
        var attributes = baseAttributes
        var font = Metrics.bodyFont
        var kind = VCBlockKind.body

        if let level = headerLevel(block) {
            let size: CGFloat = level <= 1 ? 20 : (level == 2 ? 17 : 15)
            font = NSFont.systemFont(ofSize: size, weight: .semibold)
            kind = .heading
        }
        if isCodeBlock(block) {
            font = Metrics.codeFont
            attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.06)
            kind = .codeBlock
        }
        if isBlockQuote(block) {
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            kind = .blockQuote
        }
        if kind == .body, block.contains(where: { if case .listItem = $0.kind { return true } else { return false } }) {
            kind = .listItem
        }

        if let inline {
            if inline.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if inline.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if inline.contains(.code) {
                font = Metrics.codeFont
                attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.06)
                if kind != .codeBlock { kind = .inlineCode }
            }
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }

        attributes[.font] = font
        attributes[.vcBlockKind] = kind.rawValue
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func plain(_ text: String) -> NSAttributedString {
        var attributes = baseAttributes
        attributes[.vcBlockKind] = VCBlockKind.body.rawValue
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Metrics.bodyFont,
         .foregroundColor: NSColor.labelColor,
         .paragraphStyle: bodyParagraphStyle]
    }

    private static var bodyParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5           // §6.7
        style.paragraphSpacing = 10
        return style
    }

    /// Applied last so a single style object covers each whole paragraph rather
    /// than each run, which is what NSLayoutManager actually wants.
    private static func applyParagraphStyles(to text: NSMutableAttributedString) {
        text.addAttribute(.paragraphStyle, value: bodyParagraphStyle,
                          range: NSRange(location: 0, length: text.length))
    }

    // MARK: Serialisation (§7.3)

    /// R-TXT-6 — unformatted text round-trips byte-identically, which is why
    /// the fast path exists at all.
    public static func markdown(from attributed: NSAttributedString) -> String {
        let plain = attributed.string
        var hasFormatting = false
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if let font = value as? NSFont, font != Metrics.bodyFont {
                hasFormatting = true
                stop.pointee = true
            }
        }
        guard hasFormatting else { return plain }

        var out = ""
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            let piece = (attributed.string as NSString).substring(with: range)
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let isCode = font?.fontName == Metrics.codeFont.fontName
            let underlined = (attrs[.underlineStyle] as? Int ?? 0) != 0

            var wrapped = piece
            if isCode { wrapped = "`\(wrapped)`" }
            if traits.contains(.boldFontMask) { wrapped = "**\(wrapped)**" }
            if traits.contains(.italicFontMask) { wrapped = "*\(wrapped)*" }
            if underlined { wrapped = "<u>\(wrapped)</u>" }
            out += wrapped
        }
        return out
    }
}
