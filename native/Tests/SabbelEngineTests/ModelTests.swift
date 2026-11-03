import AVFoundation
import Foundation
import SabbelCore
import Testing
@testable import SabbelEngine

/// Tests against the real Parakeet model. Slow, so only with SABBEL_MODEL_TESTS=1
/// (`make native-test-model`). Audio is synthesised with `say`.
private let modelTests = ProcessInfo.processInfo.environment["SABBEL_MODEL_TESTS"] == "1"
private let englishText = "Hello world, this is a dictation test."

private enum Models {
    static let recognizer = Task { try await ParakeetRecognizer.load() }
}

private func say(_ text: String, voice: String? = nil) throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", url.path, "--data-format=LEI16@16000", text]
    try p.run()
    p.waitUntilExit()
    let file = try AVAudioFile(forReading: url)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

private func hasVoice(_ name: String) throws -> Bool {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "?"]
    p.standardOutput = pipe
    try p.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return out.split(separator: "\n").contains { $0.hasPrefix(name + " ") }
}

private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

private func clean(_ s: String) -> String {
    s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
}

/// Normalised Levenshtein similarity: 1 - distance / max length.
private func similarity(_ a: String, _ b: String) -> Double {
    let a = Array(a), b = Array(b)
    if a.isEmpty && b.isEmpty { return 1 }
    var prev = Array(0...b.count)
    for i in 1...max(a.count, 1) where !a.isEmpty {
        var cur = [i] + Array(repeating: 0, count: b.count)
        for j in 1...max(b.count, 1) where !b.isEmpty {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
}

@Suite(.serialized, .enabled(if: modelTests)) struct ModelTests {
    @Test func englishPhrase() async throws {
        let rec = try await Models.recognizer.value
        let words = try await rec.recognize(try say(englishText)).map { clean($0.text) }
        #expect(words.contains("hello"))
        #expect(words.contains("world"))
        #expect(words.contains("test"))
    }

    @Test func mixedGermanEnglish() async throws {
        guard try hasVoice("Anna") else {
            print("SKIPPED mixedGermanEnglish: German voice Anna not installed")
            return
        }
        let rec = try await Models.recognizer.value
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mixed_de_en.txt")
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
        var found = 0, total = 0
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let terms = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let output = try await rec.recognize(try say(parts[0], voice: "Anna")).map { clean($0.text) }
            for term in terms {
                total += 1
                // Multi-word terms match when every word of them does.
                let hit = term.split(separator: " ").allSatisfy { w in
                    output.contains { similarity(clean(String(w)), $0) >= 0.85 }
                }
                if hit { found += 1 } else { print("MISS \(term) in: \(output.joined(separator: " "))") }
            }
        }
        let recall = Double(found) / Double(total)
        print("mixedGermanEnglish recall: \(found)/\(total) = \(Int(recall * 100)) %")
        #expect(recall >= 0.8)
    }

    @Test func timingsAreMonotonic() async throws {
        let rec = try await Models.recognizer.value
        let audio = try say(englishText)
        let duration = Double(audio.count) / 16_000
        let words = try await rec.recognize(audio)
        #expect(!words.isEmpty)
        var last = 0.0
        for w in words {
            #expect(w.start >= last)
            #expect(w.end >= w.start)
            last = w.start
        }
        #expect(words.first!.start >= 0)
        #expect(words.last!.end <= duration + 0.1)
    }

    @Test func memoryStaysFlat() async throws {
        let rec = try await Models.recognizer.value
        let audio = try say(englishText)
        for _ in 0..<2 { _ = try await rec.recognize(audio) }
        let before = footprintMB()
        for _ in 0..<10 { _ = try await rec.recognize(audio) }
        let after = footprintMB()
        print("memoryStaysFlat: footprint \(Int(before)) -> \(Int(after)) MB")
        #expect(after - before < 64)
    }

    @Test func finishLatency() async throws {
        let rec = try await Models.recognizer.value
        var take: [Float] = []
        let en = try say(englishText)
        let de = try say("Wir müssen das Deployment bis Freitag fertig haben, und danach schauen wir uns den Pull Request an.",
                         voice: try hasVoice("Anna") ? "Anna" : nil)
        while take.count < 60 * 16_000 { take += en + de }
        take = Array(take.prefix(60 * 16_000))

        let transcriber = StreamingTranscriber(recognizer: rec)
        var peak = footprintMB()
        let chunk = 1_600
        let clock = ContinuousClock()
        let start = clock.now
        // One serial caller, paced against the wall clock like the microphone.
        for i in stride(from: 0, to: take.count, by: chunk) {
            await transcriber.append(Array(take[i..<min(i + chunk, take.count)]))
            peak = max(peak, footprintMB())
            try await Task.sleep(until: start + .milliseconds(100 * (i / chunk + 1)), clock: clock)
        }
        let t0 = clock.now
        let text = try await transcriber.finish()
        let d = clock.now - t0
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        let passes = await transcriber.passCount
        print("finishLatency: \(Int(ms)) ms after 60 s take, \(passes) passes, peak footprint \(Int(peak)) MB, \(text.split(separator: " ").count) words")
        #expect(!text.isEmpty)
        // GitHub's macOS runners have no Neural Engine (a dry run took 2.5 s there), so CI gets a looser bound.
        let bound: Double = ProcessInfo.processInfo.environment["CI"] != nil ? 5000 : 500
        #expect(ms <= bound, "finishLatency: \(Int(ms)) ms, bound \(Int(bound)) ms")
    }
}
