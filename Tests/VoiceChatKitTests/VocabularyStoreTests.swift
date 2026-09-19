import Foundation
import Testing
@testable import VoiceChatKit

@Suite("Vocabulary store — §8.6")
struct VocabularyStoreTests {

    private func temporaryStore() -> VocabularyStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-\(UUID().uuidString).json")
        return VocabularyStore(url: url)
    }

    @Test("a phrase round-trips to disk")
    func roundTrip() {
        let store = temporaryStore()
        store.add("Kubernetes")
        #expect(store.load() == ["Kubernetes"])
    }

    @Test("re-adding moves a phrase to the front instead of duplicating it")
    func deduplicates() {
        let store = temporaryStore()
        store.add("alpha")
        store.add("beta")
        store.add("alpha")
        #expect(store.load() == ["alpha", "beta"])
    }

    @Test("R-STT-20 — the list is capped, newest first")
    func capped() {
        let store = temporaryStore()
        for i in 0..<(VocabularyStore.maximumPhrases + 20) { store.add("word\(i)") }
        let phrases = store.load()
        #expect(phrases.count == VocabularyStore.maximumPhrases)
        #expect(phrases.first == "word\(VocabularyStore.maximumPhrases + 19)")
    }

    @Test("phrases are trimmed to something the recogniser can use")
    func cleaning() {
        #expect(VocabularyStore.clean("  Kubernetes.  ") == "Kubernetes")
        #expect(VocabularyStore.clean("Model Context Protocol is long") == "Model Context")
        #expect(VocabularyStore.clean("   ") == "")
    }

    @Test("an empty phrase is not stored")
    func ignoresEmpty() {
        let store = temporaryStore()
        store.add("   ")
        #expect(store.load().isEmpty)
    }

    @Test("a missing file reads as an empty vocabulary")
    func missingFile() {
        #expect(temporaryStore().load().isEmpty)
    }
}
