import AppKit
import Testing
@testable import VoiceChatUI

@MainActor
@Suite("Speech text derivation — §9.2")
struct SpeechTextBuilderTests {

    private func segments(_ markdown: String,
                          _ options: SpeechBuildOptions = SpeechBuildOptions()) -> [SpeechSegment] {
        SpeechTextBuilder.segments(from: MarkdownRenderer.attributed(from: markdown), options: options)
    }

    private func spoken(_ markdown: String,
                        _ options: SpeechBuildOptions = SpeechBuildOptions()) -> String {
        segments(markdown, options).map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    @Test("Markdown punctuation is never read aloud")
    func noMarkdownNoise() {
        let text = spoken("This is **bold** and *italic* text.")
        #expect(text.contains("This is bold and italic text."))
        #expect(!text.contains("*"))
        #expect(!text.contains("#"))
    }

    @Test("a code block is announced with its line count and skipped")
    func codeBlockAnnounced() {
        let text = spoken("Before.\n\n```\nlet a = 1\nlet b = 2\nlet c = 3\n```\n\nAfter.")
        #expect(text.contains("Before."))
        #expect(text.contains("After."))
        #expect(text.contains("Code block"))
        #expect(!text.contains("let a = 1"), "code must not be read aloud")
    }

    @Test("speaking code blocks can be turned on")
    func codeBlockOptIn() {
        var options = SpeechBuildOptions()
        options.speakCodeBlocks = true
        let text = spoken("```\nlet a = 1\n```", options)
        #expect(text.contains("let a = 1"))
        #expect(!text.contains("Code block,"))
    }

    @Test("a block quote is introduced as a quote")
    func blockQuote() {
        #expect(spoken("> To be, or not to be.").contains("Quote:"))
    }

    @Test("headings get a beat after them")
    func headingDelay() {
        let heading = segments("# Title\n\nBody text.").first { $0.text.contains("Title") }
        #expect(heading?.postDelay ?? 0 > 0.3)
    }

    @Test("R-TTS-7 — every segment maps back to real document text")
    func rangesAlign() {
        let attributed = MarkdownRenderer.attributed(from: """
            # Heading

            A first sentence. A second sentence.

            ```
            code here
            ```

            Closing words.
            """)
        let all = SpeechTextBuilder.segments(from: attributed)
        #expect(!all.isEmpty)
        for segment in all {
            #expect(NSMaxRange(segment.range) <= attributed.length,
                    "segment range \(segment.range) escapes the document")
        }
        // Ranges advance monotonically, which is what keeps the highlight in step.
        let starts = all.map(\.range.location)
        #expect(starts == starts.sorted(), "segments must be in document order")
    }

    @Test("R-TTS-8 — an over-long response is truncated at a sentence boundary")
    func truncation() {
        var options = SpeechBuildOptions()
        options.maximumCharacters = 80
        let long = String(repeating: "This is a sentence. ", count: 50)
        let all = segments(long, options)
        #expect(all.last?.text == "Response truncated for reading.")
        let body = all.dropLast().map(\.text).joined()
        #expect(body.count <= 80 + 20)
    }

    @Test("sentences are split so Stop can be immediate")
    func sentenceSplitting() {
        let all = segments("One. Two. Three.")
        let spokenOnly = all.filter(\.isSpoken)
        #expect(spokenOnly.count == 3, "got \(spokenOnly.map(\.text))")
    }

    @Test("empty input produces nothing to say")
    func empty() {
        #expect(segments("").isEmpty)
    }
}
