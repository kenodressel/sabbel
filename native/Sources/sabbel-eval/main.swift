import FluidAudio
import Foundation
import SabbelCore
import SabbelEngine

// sabbel-eval --clips DIR --out FILE.jsonl --mode stream|full [--model v3|ultra]
//             [--long 60,300 --refs REFS.json --long-out DIR]
//             [--glossary glossary.txt]   (apply it to every hypothesis)
//             [--window S --settle-age S --final-context S]   (stream tuning)
//
// Writes one JSONL line per clip: {"clip", "text", "finish_ms", "audio_s"}.
// With --long, takes built from consecutive clips of one recording (0.3 s of
// silence between them) are written to --long-out together with their joined
// refs (refs-long<N>.json) and evaluated too, into FILE-long<N>.jsonl.

struct Fail: Error, CustomStringConvertible { let description: String }

let sampleRate = 16_000
let chunk = sampleRate / 10  // 0.1 s, fed without wall-clock pacing

func readWav(_ url: URL) throws -> [Float] {
    let d = try Data(contentsOf: url)
    var i = 12
    var formatChecked = false
    guard d.count >= 12, d[0..<4].elementsEqual("RIFF".utf8), d[8..<12].elementsEqual("WAVE".utf8) else {
        throw Fail(description: "\(url.lastPathComponent) is not a WAV file")
    }
    func le16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
    while i + 8 <= d.count {
        let id = String(decoding: d[i..<i + 4], as: UTF8.self)
        let size = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
        if id == "fmt " {
            // PCM (1), mono, 16 kHz, 16 bit
            guard size >= 16, i + 8 + 16 <= d.count, le16(i + 8) == 1, le16(i + 10) == 1,
                  le16(i + 12) | le16(i + 14) << 16 == sampleRate, le16(i + 22) == 16 else {
                throw Fail(description: "\(url.lastPathComponent) is not 16 kHz mono 16-bit PCM")
            }
            formatChecked = true
        }
        if id == "data" {
            guard formatChecked else { throw Fail(description: "\(url.lastPathComponent): data before fmt") }
            let end = min(d.count, i + 8 + size)
            return stride(from: i + 8, to: end - 1, by: 2).map {
                Float(Int16(bitPattern: UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8)) / 32768
            }
        }
        i += 8 + size + (size & 1)
    }
    throw Fail(description: "no data chunk in \(url.lastPathComponent)")
}

func writeWav(_ samples: [Float], to url: URL) throws {
    var d = Data()
    func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2)
    d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
    u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
    for s in samples {
        withUnsafeBytes(of: Int16(max(-1, min(1, s)) * 32767).littleEndian) { d.append(contentsOf: $0) }
    }
    try d.write(to: url)
}

func joined(_ words: [TimedWord]) -> String {
    words.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
}

func ms(since start: ContinuousClock.Instant) -> Double {
    let c = start.duration(to: .now).components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

/// Returns the text and the wall time of finish() (stream) or of the whole
/// recognition (full).
func transcribe(_ samples: [Float], stream: Bool, recognizer: ParakeetRecognizer, tuning: [String: Double]) async throws -> (String, Double) {
    if !stream {
        let t0 = ContinuousClock.now
        let text = joined(try await recognizer.recognize(samples))
        return (text, ms(since: t0))
    }
    let st = StreamingTranscriber(recognizer: recognizer,
                                  window: tuning["window"] ?? StreamingTranscriber.defaultWindow,
                                  settleAge: tuning["settle-age"] ?? StreamingTranscriber.defaultSettleAge,
                                  finalContext: tuning["final-context"] ?? StreamingTranscriber.defaultFinalContext)
    // One serial caller: append awaits each pass.
    for start in stride(from: 0, to: samples.count, by: chunk) {
        await st.append(Array(samples[start..<min(samples.count, start + chunk)]))
    }
    let t0 = ContinuousClock.now
    let text = try await st.finish()
    return (text, ms(since: t0))
}

struct Item { let name: String; let samples: [Float] }

func evaluate(_ items: [Item], stream: Bool, recognizer: ParakeetRecognizer, tuning: [String: Double],
              glossary: Glossary, to out: URL) async throws {
    var lines = ""
    for item in items {
        let (raw, finish) = try await transcribe(item.samples, stream: stream, recognizer: recognizer, tuning: tuning)
        let text = glossary.apply(raw).text
        let row: [String: Any] = ["clip": item.name, "text": text, "finish_ms": finish,
                                  "audio_s": Double(item.samples.count) / Double(sampleRate)]
        lines += String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }
    try lines.write(to: out, atomically: true, encoding: .utf8)
}

/// Takes of at least `target` seconds from consecutive clips of one recording;
/// a recording's leftover shorter than that is dropped.
func longTakes(clips: [Item], refs: [[String: Any]], target: Double, dir: URL) throws -> [Item] {
    let byClip = Dictionary(uniqueKeysWithValues: refs.compactMap { r in (r["clip"] as? String).map { ($0, r) } })
    var recordings: [String: [Item]] = [:]
    for c in clips {
        let stem = c.name.replacingOccurrences(of: ".wav", with: "")
        let rec = stem.range(of: "_", options: .backwards).map { String(stem[..<$0.lowerBound]) } ?? stem
        recordings[rec, default: []].append(c)
    }
    let gap = [Float](repeating: 0, count: Int(0.3 * Double(sampleRate)))
    var takes: [Item] = [], takeRefs: [[String: Any]] = []
    for rec in recordings.keys.sorted() {
        var audio: [Float] = [], texts: [String] = [], terms: [String] = [], index = 0
        func flush() throws {
            let name = "long\(Int(target))_\(rec)_\(index).wav"
            index += 1
            try writeWav(audio, to: dir.appendingPathComponent(name))
            takes.append(Item(name: name, samples: audio))
            takeRefs.append(["clip": name, "seconds": Double(audio.count) / Double(sampleRate),
                             "ref": texts.joined(separator: " "), "en_terms": terms])
            audio = []; texts = []; terms = []
        }
        for c in recordings[rec]!.sorted(by: { $0.name < $1.name }) {
            if !audio.isEmpty { audio += gap }
            audio += c.samples
            guard let r = byClip[c.name] else {
                throw Fail(description: "\(c.name) has no entry in the refs file")
            }
            texts.append(r["ref"] as? String ?? "")
            terms += r["en_terms"] as? [String] ?? []
            if Double(audio.count) / Double(sampleRate) >= target { try flush() }
        }
    }
    let data = try JSONSerialization.data(withJSONObject: takeRefs, options: [.sortedKeys])
    try data.write(to: dir.appendingPathComponent("refs-long\(Int(target)).json"))
    return takes
}

func run() async throws {
    var args: [String: String] = [:]
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let k = it.next() {
        let known: Set = ["clips", "out", "mode", "model", "long", "refs", "long-out",
                          "window", "settle-age", "final-context", "glossary"]
        guard k.hasPrefix("--"), known.contains(String(k.dropFirst(2))), let v = it.next() else {
            throw Fail(description: "unknown flag or missing value: \(k)")
        }
        args[String(k.dropFirst(2))] = v
    }
    guard let clipsDir = args["clips"], let outPath = args["out"], let mode = args["mode"],
          mode == "stream" || mode == "full" else {
        throw Fail(description: "usage: sabbel-eval --clips DIR --out FILE.jsonl --mode stream|full [--model v3|ultra] [--long 60,300 --refs REFS.json --long-out DIR]")
    }
    let version: AsrModelVersion
    switch args["model"] ?? "v3" {
    case "v3": version = .v3
    case "ultra": version = .ultra
    case let other: throw Fail(description: "unknown model \(other)")
    }

    let dir = URL(fileURLWithPath: (clipsDir as NSString).expandingTildeInPath)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".wav") }.sorted()
    let clips = try names.map { Item(name: $0, samples: try readWav(dir.appendingPathComponent($0))) }

    let recognizer = try await ParakeetRecognizer.load(version: version)
    _ = try await recognizer.recognize([Float](repeating: 0, count: sampleRate))  // warm-up

    let out = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
    let stream = mode == "stream"
    var tuning: [String: Double] = [:]
    for k in ["window", "settle-age", "final-context"] {
        guard let raw = args[k] else { continue }
        guard let v = Double(raw), v > 0 else { throw Fail(description: "--\(k) needs a positive number, got \(raw)") }
        tuning[k] = v
    }
    var glossary = Glossary.empty
    if let path = args["glossary"] {
        let text = try String(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), encoding: .utf8)
        let parsed = Glossary.parse(text)
        for warning in parsed.warnings { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        glossary = parsed.glossary
    }
    try await evaluate(clips, stream: stream, recognizer: recognizer, tuning: tuning, glossary: glossary, to: out)

    if let long = args["long"] {
        guard let refsPath = args["refs"], let longOut = args["long-out"] else {
            throw Fail(description: "--long needs --refs and --long-out")
        }
        let targets = long.split(separator: ",").map { Double($0) }
        guard !targets.isEmpty, targets.allSatisfy({ ($0 ?? 0) > 0 }) else {
            throw Fail(description: "--long needs positive seconds, e.g. 60,300")
        }
        let refsData = try Data(contentsOf: URL(fileURLWithPath: (refsPath as NSString).expandingTildeInPath))
        let refs = try JSONSerialization.jsonObject(with: refsData) as? [[String: Any]] ?? []
        let longDir = URL(fileURLWithPath: (longOut as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: longDir, withIntermediateDirectories: true)
        for target in targets.compactMap({ $0 }) {
            let takes = try longTakes(clips: clips, refs: refs, target: target, dir: longDir)
            let path = out.deletingPathExtension().path + "-long\(Int(target)).jsonl"
            try await evaluate(takes, stream: stream, recognizer: recognizer, tuning: tuning, glossary: glossary,
                               to: URL(fileURLWithPath: path))
        }
    }
}

do { try await run() } catch {
    FileHandle.standardError.write(Data("sabbel-eval: \(error)\n".utf8))
    exit(1)
}
