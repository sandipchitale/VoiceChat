import AppKit
import Testing
@testable import VoiceChatUI

// Spec §15.2 — Markdown ⇄ attributed round-trip.

@MainActor
@Suite("Markdown rendering — §7.2")
struct MarkdownRendererTests {

    @Test("block elements are separated, not run together")
    func paragraphsSeparated() {
        let rendered = MarkdownRenderer.attributed(from: "First paragraph.\n\nSecond paragraph.")
        #expect(rendered.string == "First paragraph.\n\nSecond paragraph.")
    }

    @Test("a code span is styled as code and nothing else")
    func codeSpanIsNotStruckThrough() {
        let rendered = MarkdownRenderer.attributed(from: "This is `vcp-probe` here.")
        let range = (rendered.string as NSString).range(of: "vcp-probe")
        #expect(range.location != NSNotFound)

        let attrs = rendered.attributes(at: range.location, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        #expect(font?.fontName == Metrics.codeFont.fontName, "code spans use the mono font")
        #expect(attrs[.strikethroughStyle] == nil, "a code span must not be struck through")
        #expect(attrs[.backgroundColor] != nil, "code spans carry a background")
    }

    @Test("emphasis maps to real font traits")
    func emphasis() {
        let rendered = MarkdownRenderer.attributed(from: "plain **bold** and *italic*")
        func traits(of word: String) -> NSFontTraitMask {
            let r = (rendered.string as NSString).range(of: word)
            guard r.location != NSNotFound,
                  let font = rendered.attributes(at: r.location, effectiveRange: nil)[.font] as? NSFont
            else { return [] }
            return NSFontManager.shared.traits(of: font)
        }
        #expect(traits(of: "bold").contains(.boldFontMask))
        #expect(traits(of: "italic").contains(.italicFontMask))
        #expect(!traits(of: "plain").contains(.boldFontMask))
    }

    @Test("headings and list items each land on their own line")
    func headingsAndLists() {
        let rendered = MarkdownRenderer.attributed(from: """
            # Title

            - one
            - two
            """)
        let lines = rendered.string.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.contains("Title"))
        #expect(lines.contains { $0.contains("one") })
        #expect(lines.contains { $0.contains("two") })
        #expect(lines.count >= 3, "each block gets its own line, got: \(lines)")
    }

    @Test("a fenced code block keeps its newlines")
    func codeBlock() {
        let rendered = MarkdownRenderer.attributed(from: "before\n\n```\nline one\nline two\n```\n\nafter")
        #expect(rendered.string.contains("line one\nline two"))
        #expect(rendered.string.hasPrefix("before"))
        #expect(rendered.string.hasSuffix("after"))
    }

    @Test("R-TXT-4 — malformed input never fails a turn")
    func malformedFallsBack() {
        let ugly = "unclosed **bold and `code"
        let rendered = MarkdownRenderer.attributed(from: ugly)
        #expect(!rendered.string.isEmpty)
    }

    @Test("R-TXT-6 — unformatted text round-trips byte-identically")
    func unformattedRoundTrip() {
        let plain = "just some words, 2 * 3 * 4, nothing special"
        let attributed = NSAttributedString(string: plain, attributes: [.font: Metrics.bodyFont])
        #expect(MarkdownRenderer.markdown(from: attributed) == plain)
    }
}
