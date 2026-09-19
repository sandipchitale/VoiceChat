import AVFoundation
import AppKit
import Foundation
import Speech

// Spec §8 — on-device speech recognition.
//
// AVAudioEngine input tap → AsyncStream<AnalyzerInput> → SpeechAnalyzer +
// SpeechTranscriber, with volatile results rendered as interim text and only
// finalised results acted on (R-STT-5, R-STT-6).

/// The converter is touched only from the audio thread, which calls the tap
/// serially. Boxing it keeps that promise explicit rather than implicit.
private final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    init(converter: AVAudioConverter, format: AVAudioFormat) {
        self.converter = converter
        self.format = format
    }
}

@MainActor
public final class SpeechInputController {

    public enum State: Equatable, Sendable {
        case idle
        /// Model assets are downloading.
        case preparing
        case listening
        case microphoneDenied
        case unavailable(String)

        public var isRunning: Bool { self == .listening || self == .preparing }
    }

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    public var onStateChange: ((State) -> Void)?
    /// Interim hypothesis; replaced in place, never committed (R-UI-6).
    public var onVolatile: ((String) -> Void)?
    /// A committed result: inserted, or dispatched as a command.
    public var onFinal: ((String) -> Void)?
    /// Input RMS, 0…1, for the mic level ring.
    public var onLevel: ((Float) -> Void)?

    public var locale: Locale = Locale(identifier: "en-US")
    /// R-STT-19 — phrases from the user's vocabulary store.
    public var contextualPhrases: [String] = []

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var reservedLocale: Locale?
    private var lastLevelSent = Date.distantPast

    public init() {}

    // MARK: Permission (R-STT-25)

    /// Requested at first microphone activation, never at launch.
    public static func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Lifecycle

    public func start() async {
        guard !state.isRunning else { return }

        guard await Self.microphoneAuthorized() else {
            state = .microphoneDenied
            return
        }

        do {
            let resolved = try await resolveLocale()
            let transcriber = SpeechTranscriber(
                locale: resolved,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange])
            self.transcriber = transcriber

            // Model assets may need downloading on first use; the mic control
            // shows "Preparing…" rather than silently failing (R-STT-2).
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                state = .preparing
                try await request.downloadAndInstall()
            }
            if try await AssetInventory.reserve(locale: resolved) {
                reservedLocale = resolved
            }

            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]) else {
                state = .unavailable("This Mac has no compatible audio format for transcription.")
                return
            }

            let context = AnalysisContext()
            if !contextualPhrases.isEmpty {
                context.contextualStrings[.general] = contextualPhrases
            }

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            inputContinuation = continuation

            // The analysis context travels with the input sequence: the plain
            // init(modules:) overload has no place to put it.
            let analyzer = SpeechAnalyzer(inputSequence: stream,
                                          modules: [transcriber],
                                          analysisContext: context)
            self.analyzer = analyzer

            try startEngine(converting: analyzerFormat)
            consumeResults(from: transcriber)
            state = .listening

        } catch {
            state = .unavailable(Self.describe(error))
            await teardown()
        }
    }

    public func stop() async {
        guard state != .idle else { return }
        await teardown()
        state = .idle
    }

    private func teardown() async {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        // R-STT-7 — interim text outstanding at stop is discarded, not committed.
        onVolatile?("")
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        transcriber = nil
        if let reservedLocale {
            _ = await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }
        onLevel?(0)
    }

    // MARK: Audio

    private func startEngine(converting analyzerFormat: AVAudioFormat) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "VoiceChat", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input device is available."])
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw NSError(domain: "VoiceChat", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Cannot convert this microphone's audio for transcription."])
        }
        let box = ConverterBox(converter: converter, format: analyzerFormat)
        let continuation = inputContinuation
        let levelSink: @Sendable (Float) -> Void = { [weak self] level in
            Task { @MainActor in self?.deliverLevel(level) }
        }

        // The tap runs on a realtime audio thread. Written inline it would
        // inherit this type's @MainActor isolation and trap on the first
        // buffer, so it is declared @Sendable explicitly and touches nothing
        // isolated: the level hops to the main actor, the converter is boxed,
        // and the continuation is already Sendable.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            levelSink(Self.rms(of: buffer))
            guard let converted = Self.convert(buffer, with: box) else { return }
            continuation?.yield(AnalyzerInput(buffer: converted))
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: tap)

        engine.prepare()
        try engine.start()
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer,
                                            with box: ConverterBox) -> AVAudioPCMBuffer? {
        let ratio = box.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: box.format, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = box.converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = (sum / Float(count)).squareRoot()
        // Perceptual-ish curve so the ring moves visibly at speech level.
        return min(1, rms * 12)
    }

    private func deliverLevel(_ level: Float) {
        // ~20 Hz is plenty for a level ring and keeps this off the hot path.
        guard Date().timeIntervalSince(lastLevelSent) > 0.05 else { return }
        lastLevelSent = Date()
        onLevel?(level)
    }

    // MARK: Results

    private func consumeResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self else { return }
                        if result.isFinal {
                            self.onVolatile?("")
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { self.onFinal?(trimmed) }
                        } else {
                            self.onVolatile?(text)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.state = .unavailable(Self.describe(error))
                }
            }
        }
    }

    // MARK: Locale

    private func resolveLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        func matches(_ candidate: Locale) -> Locale? {
            supported.first { $0.identifier(.bcp47) == candidate.identifier(.bcp47) }
                ?? supported.first { $0.language.languageCode == candidate.language.languageCode }
        }
        if let match = matches(locale) { return match }
        if let english = matches(Locale(identifier: "en-US")) { return english }
        guard let first = supported.first else {
            throw NSError(domain: "VoiceChat", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "No speech transcription languages are installed."])
        }
        return first
    }

    private nonisolated static func describe(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }
}
