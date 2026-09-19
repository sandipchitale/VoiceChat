import Foundation

// Spec §8.6 — the store behind the `Add to vocabulary` dictation directive.
//
// R-STT-20: capped, most-recently-added first, short phrases. The cap and the
// ordering both come from the platform guidance for contextual phrase lists:
// long lists and long phrases both make recognition worse, not better.

public struct VocabularyStore: Sendable {
    public static let maximumPhrases = 100

    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? VCP.supportDirectoryURL().appendingPathComponent("vocabulary.json")
    }

    public func load() -> [String] {
        guard let data = try? Data(contentsOf: url),
              let phrases = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return phrases
    }

    /// Returns the updated list. Adding an existing phrase moves it to the
    /// front rather than duplicating it.
    @discardableResult
    public func add(_ phrase: String) -> [String] {
        let cleaned = Self.clean(phrase)
        guard !cleaned.isEmpty else { return load() }

        var phrases = load()
        phrases.removeAll { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
        phrases.insert(cleaned, at: 0)
        if phrases.count > Self.maximumPhrases {
            phrases = Array(phrases.prefix(Self.maximumPhrases))
        }
        save(phrases)
        return phrases
    }

    @discardableResult
    public func remove(_ phrase: String) -> [String] {
        var phrases = load()
        phrases.removeAll { $0.caseInsensitiveCompare(phrase) == .orderedSame }
        save(phrases)
        return phrases
    }

    public func save(_ phrases: [String]) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(phrases) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Phrases are kept to one or two words; a whole sentence is not something
    /// the recogniser can usefully be biased towards.
    static func clean(_ phrase: String) -> String {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'"))
        let words = trimmed.split(separator: " ").prefix(2)
        return words.joined(separator: " ")
    }
}
