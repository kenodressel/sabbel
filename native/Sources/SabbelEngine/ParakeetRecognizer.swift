import FluidAudio
import Foundation
import SabbelCore

public enum EngineInfo { public static let description = "Parakeet TDT 0.6b v3 (CoreML, FluidAudio 0.18.2)" }

/// Parakeet TDT through FluidAudio (CoreML, Neural Engine).
public actor ParakeetRecognizer: Recognizer {
    private let asr: AsrManager

    private init(asr: AsrManager) { self.asr = asr }

    /// Downloads the model if it is not cached, then loads it. The first load
    /// compiles the CoreML models, which takes a minute or two; later loads are fast.
    /// `progress` reports the download as a fraction in 0...1.
    public static func load(version: AsrModelVersion = .v3,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> ParakeetRecognizer {
        let models = try await AsrModels.downloadAndLoad(
            version: version,
            progressHandler: progress.map { report in { @Sendable p in report(p.fractionCompleted) } })
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        return ParakeetRecognizer(asr: asr)
    }

    /// Overlapping takes call this concurrently, and the actor is reentrant
    /// across `await`: without the lock a second call would enter `AsrManager`
    /// while the first is suspended inside it. FluidAudio's manager is not
    /// built for that, so transcriptions run strictly one at a time, in order.
    private let serial = AsyncSerialLock()

    public func recognize(_ samples: [Float]) async throws -> [TimedWord] {
        try await serial.run { try await self.transcribe(samples) }
    }

    private func transcribe(_ samples: [Float]) async throws -> [TimedWord] {
        // A fresh decoder state per call: every call is its own stretch of audio.
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state)
        return Self.words(from: result.tokenTimings ?? [])
    }

    /// Groups SentencePiece tokens into words: a token starting with "▁" begins a
    /// new word, any other token continues the current one. FluidAudio's token
    /// strings carry the word boundary as a leading space (the "▁" already
    /// normalised), so a leading space counts as the marker too.
    static func words(from timings: [TokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        var text = "", start = 0.0, end = 0.0
        func flush() {
            if !text.isEmpty { words.append(TimedWord(text: text, start: start, end: end)) }
            text = ""
        }
        for t in timings {
            let begins = t.token.hasPrefix("▁") || t.token.hasPrefix(" ")
            let piece = begins ? String(t.token.dropFirst()) : t.token
            if begins { flush() }
            if text.isEmpty {
                if piece.isEmpty { continue }
                start = t.startTime
            }
            text += piece
            end = t.endTime
        }
        flush()
        return words
    }
}
