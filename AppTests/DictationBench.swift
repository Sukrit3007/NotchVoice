import AVFoundation
import Foundation
import NotchVoiceCore
import Testing
@testable import NotchVoice

/// Latency and accuracy of the dictation pipeline over the clips in
/// `Tools/Bench`. Run it with `Tools/Bench/run.sh`; `docs/benchmarks/README.md`
/// says how and what the numbers mean.
///
/// A test rather than a command-line tool so it runs the app's own code in
/// the app's own process: the installed model and settings come from the
/// app's Application Support folder and defaults, and CoreML reuses the
/// compile cache it keeps per bundle ID. A separate binary would compile the
/// model for the Neural Engine from scratch, which takes minutes to hours and
/// says nothing about the app.
///
/// Each clip goes through the steps `DictationCoordinator` runs after key-up:
/// transcribe (custom words as the bias prompt), clean up, fit to the caret.
/// Not timed: recording, the dictionary read, corrections and snippets (no
/// store here), and the paste.
///
/// Off unless `NOTCHVOICE_BENCH=1`, so `xcodebuild test` doesn't spend minutes
/// on it.
@MainActor
@Suite("Dictation bench")
struct DictationBench {

    @Test("latency and word error rate over Tools/Bench/Fixtures",
          .enabled(if: BenchSettings.isRequested, "Run it with Tools/Bench/run.sh"),
          .timeLimit(.minutes(30)))
    func bench() async throws {
        let settings = BenchSettings()
        let fixtures = try settings.loadFixtures()
        let model = settings.model

        guard let folder = BenchSettings.installedFolder(for: model) else {
            try Test.cancel(Comment(rawValue:
                "Speech model \(model.rawValue) is not installed in \(AppPaths.models.path). "
                    + "Open Notch Voice once to download it; the bench never downloads."))
        }

        // Model load, as at app launch: CoreML load + prewarm, no network.
        let transcriber = WhisperKitService(model: model)
        let (_, load) = try await measure { try await transcriber.load(from: folder) }
        let loadMs = load.ms
        log("model \(model.rawValue) loaded in \(Int(loadMs)) ms")

        let cleanup = await Cleanup.onThisMac()
        log("cleanup: \(cleanup.summary)")

        let clips = try fixtures.map { try BenchClip(fixture: $0, directory: settings.fixtures) }
        let pipeline = Pipeline(transcriber: transcriber, cleanup: cleanup, language: settings.language)

        // Cold: every clip once, straight after the load. Only the first one
        // is cold in the strict sense; the rest are each clip's first pass.
        var cold: [String: BenchRun] = [:]
        for clip in clips {
            cold[clip.id] = try await pipeline.run(clip)
            log("cold \(clip.id): \(Int(cold[clip.id]!.totalMs)) ms")
        }

        // Warm: whole passes over the set, so no clip runs N times in a row.
        var warm: [String: [BenchRun]] = [:]
        for pass in 1 ... settings.runs {
            for clip in clips {
                warm[clip.id, default: []].append(try await pipeline.run(clip))
            }
            log("warm pass \(pass)/\(settings.runs) done")
        }

        // What the custom words are worth: the same clips with no bias prompt.
        var unbiased: [String: [UnbiasedRun]] = [:]
        for clip in clips where !clip.terms.isEmpty {
            for _ in 1 ... settings.runs {
                unbiased[clip.id, default: []].append(try await pipeline.transcribeOnly(clip))
            }
        }

        let report = BenchReport(
            settings: settings, model: model, loadMs: loadMs, cleanup: cleanup,
            clips: clips, cold: cold, warm: warm, unbiased: unbiased)
        try report.write(to: settings.output)
        log("wrote \(settings.output.path)/bench.json and bench.md")

        #expect(report.fixtures.count == fixtures.count)
    }

    private func log(_ line: String) {
        print("[bench] \(line)")
    }
}

// MARK: - Settings

/// Everything the bench reads from outside: environment, fixtures, app state.
struct BenchSettings {

    /// `xcodebuild` passes `TEST_RUNNER_<NAME>` through as `<NAME>`.
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["NOTCHVOICE_BENCH"] == "1"
    }

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The repository, found from this file's path.
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    var fixtures: URL { repository.appending(path: "Tools/Bench", directoryHint: .isDirectory) }

    var output: URL {
        Self.environment["NOTCHVOICE_BENCH_OUT"].map { URL(fileURLWithPath: $0) }
            ?? repository.appending(path: "build/bench", directoryHint: .isDirectory)
    }

    /// Warm passes; each clip's warm figure is the median over them.
    var runs: Int {
        Self.environment["NOTCHVOICE_BENCH_RUNS"].flatMap(Int.init).map { max(1, $0) } ?? 5
    }

    /// The app's chosen model, unless `NOTCHVOICE_BENCH_MODEL` names another
    /// installed variant.
    var model: SpeechModel {
        Self.environment["NOTCHVOICE_BENCH_MODEL"].flatMap(SpeechModel.init(rawValue:))
            ?? ModelPreference.current
    }

    /// Fixed rather than the app's preference: the clips are English, and
    /// "auto" would add a language-detection pass that varies by setting.
    let language = "en"

    var commit: String { Self.environment["NOTCHVOICE_BENCH_COMMIT"] ?? "unknown" }

    func loadFixtures() throws -> [BenchFixture] {
        let data = try Data(contentsOf: fixtures.appending(path: "fixtures.json"))
        return try JSONDecoder().decode(BenchFixtureFile.self, from: data).fixtures
    }

    /// Where `WhisperKit.download` puts a variant under the app's model folder,
    /// or nil when it isn't there.
    static func installedFolder(for model: SpeechModel) -> URL? {
        let folder = AppPaths.models
            .appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
            .appending(path: model.rawValue, directoryHint: .isDirectory)
        let encoder = folder.appending(path: "AudioEncoder.mlmodelc").path
        return FileManager.default.fileExists(atPath: encoder) ? folder : nil
    }
}

struct BenchFixtureFile: Decodable {
    let fixtures: [BenchFixture]
}

struct BenchFixture: Decodable {
    let id: String
    /// What should land in the document.
    let expected: String
    /// What was said, word for word, when the transcript is not expected to
    /// match `expected` — a spoken self-correction that only cleanup should
    /// remove. The reference for the raw transcript.
    let verbatim: String?
    /// Custom words, fed to the decoder as the app feeds the user's dictionary.
    let terms: [String]?
}

/// A fixture with its audio loaded.
struct BenchClip {
    let id: String
    let expected: String
    let verbatim: String
    let terms: [String]
    let samples: [Float]
    var seconds: Double { Double(samples.count) / 16_000 }

    init(fixture: BenchFixture, directory: URL) throws {
        id = fixture.id
        expected = fixture.expected
        verbatim = fixture.verbatim ?? fixture.expected
        terms = fixture.terms ?? []
        samples = try Self.samples(at: directory.appending(path: "Fixtures/\(fixture.id).wav"))
    }

    /// 16 kHz mono Float32, as `MicRecorder` hands it over. The clips are
    /// rendered in that rate, so nothing is resampled.
    private static func samples(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw BenchError.unexpectedFormat(url.lastPathComponent) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw BenchError.unexpectedFormat(url.lastPathComponent)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

enum BenchError: Error {
    case unexpectedFormat(String)
}

// MARK: - Cleanup

/// The cleanup backends that can run here, and the one the app would use.
struct Cleanup {
    let backends: [any PolishBackend]
    /// Same rule as `PolishService.backend`.
    let appBackend: (any PolishBackend)?
    let appleAvailability: PolishAvailability
    let localInstalled: Bool
    let localEnabled: Bool
    let localLoadMs: Double?

    static func onThisMac() async -> Cleanup {
        let apple = AppleIntelligencePolish()
        let local = LocalModelPolish()
        var backends: [any PolishBackend] = []
        if apple.isAvailable { backends.append(apple) }

        // Loaded up front, as `PolishService.prepare` does at launch, so no
        // dictation pays for it.
        var localLoadMs: Double?
        if local.isAvailable {
            do {
                let (_, load) = try await measure { try await local.prepare() }
                localLoadMs = load.ms
                backends.append(local)
            } catch {
                print("[bench] local cleanup model failed to load: \(error)")
            }
        }

        let localEnabled = LocalPolishPreference.isEnabled
        let appBackend: (any PolishBackend)? =
            if localEnabled, localLoadMs != nil { local }
            else if apple.isAvailable { apple }
            else { nil }

        return Cleanup(
            backends: backends, appBackend: appBackend,
            appleAvailability: apple.availability,
            localInstalled: local.isAvailable, localEnabled: localEnabled,
            localLoadMs: localLoadMs)
    }

    var summary: String {
        let apple = appleAvailability == .available ? "available" : "unavailable (\(appleAvailability))"
        let local = localInstalled
            ? (localEnabled ? "installed, enabled" : "installed, not enabled")
            : "not installed"
        return "app uses \(appBackend?.name ?? "none") · Apple Intelligence \(apple) · local model \(local)"
    }
}

// MARK: - Pipeline

/// The post-recording steps of `DictationCoordinator.finishAndTranscribe`.
@MainActor
struct Pipeline {
    let transcriber: WhisperKitService
    let cleanup: Cleanup
    let language: String

    func run(_ clip: BenchClip) async throws -> BenchRun {
        let prompt = BiasPrompt.build(terms: clip.terms)
        let (raw, transcribe) = try await measure {
            try await transcribeOrEmpty(clip.samples, prompt: prompt)
        }

        // The app stops here on a transcript with no letters or digits and
        // reports silence, so nothing after this runs for it.
        let hasSpeech = raw.contains { $0.isLetter || $0.isNumber }

        // Every backend that can run, each timed without a deadline; the
        // app's deadline and guards then decide what it would have delivered.
        var runs: [CleanupRun] = []
        for backend in cleanup.backends where hasSpeech {
            runs.append(await Self.clean(raw, with: backend))
        }
        let chosen = cleanup.appBackend.flatMap { app in runs.first { $0.backend == app.name } }
        let cleaned = chosen?.delivered ?? raw
        // The app stops waiting at the deadline.
        let cleanupWait = chosen.map { min($0.ms, $0.deadlineMs) } ?? 0

        let (fitted, fit) = timed {
            InsertionRules.fit(
                cleaned, between: .init(before: "", after: ""), keepingCaseOf: clip.terms,
                language: language,
                isWord: { [language] in LowercaseWords.contains($0, language: language) })
        }

        return BenchRun(
            transcribeMs: transcribe.ms, cleanup: runs, appCleanupMs: cleanupWait,
            fitMs: fit.ms, totalMs: transcribe.ms + cleanupWait + fit.ms,
            raw: raw, final: fitted.text)
    }

    func transcribeOnly(_ clip: BenchClip) async throws -> UnbiasedRun {
        let (raw, transcribe) = try await measure {
            try await transcribeOrEmpty(clip.samples, prompt: nil)
        }
        return UnbiasedRun(transcribeMs: transcribe.ms, raw: raw)
    }

    private func transcribeOrEmpty(_ samples: [Float], prompt: String?) async throws -> String {
        do {
            return try await transcriber.transcribe(samples, prompt: prompt, language: language)
        } catch TranscriptionError.empty {
            return ""
        }
    }

    /// `PolishService.polish` with the deadline applied after the fact, so
    /// the time a backend really takes is visible even when the app gives up
    /// on it.
    private static func clean(_ text: String, with backend: any PolishBackend) async -> CleanupRun {
        let started = ContinuousClock.now
        let polished = try? await backend.polish(text)
        let ms = started.duration(to: .now).ms
        let deadlineMs = backend.deadline.ms

        let outcome: CleanupRun.Outcome =
            if polished == nil { .failed }
            else if ms > deadlineMs { .late }
            else if PolishGuard.echoes(backend.instructions, in: polished!) { .echoed }
            else if !PolishGuard.isPlausible(polished!, from: text) { .implausible }
            else { .used }

        return CleanupRun(
            backend: backend.name, ms: ms, deadlineMs: deadlineMs, outcome: outcome,
            output: polished ?? "", delivered: outcome == .used ? polished! : text)
    }
}

// MARK: - Results

struct BenchRun: Codable {
    let transcribeMs: Double
    let cleanup: [CleanupRun]
    /// How long the app would wait for cleanup: the chosen backend's time,
    /// capped at its deadline. Zero when nothing cleans up.
    let appCleanupMs: Double
    let fitMs: Double
    let totalMs: Double
    let raw: String
    let final: String
}

struct CleanupRun: Codable {
    enum Outcome: String, Codable { case used, late, echoed, implausible, failed }
    let backend: String
    let ms: Double
    let deadlineMs: Double
    let outcome: Outcome
    let output: String
    let delivered: String
}

struct UnbiasedRun: Codable {
    let transcribeMs: Double
    let raw: String
}

struct BenchReport: Codable {

    struct Machine: Codable {
        let model: String
        let chip: String
        let memoryGB: Int
        let os: String
    }

    struct Medians: Codable {
        let transcribeMs: Double
        let appCleanupMs: Double
        let fitMs: Double
        let totalMs: Double
    }

    struct Unbiased: Codable {
        let medianTranscribeMs: Double
        let raw: String
        let werRaw: WordErrorRate.Score
        let runs: [UnbiasedRun]
    }

    struct Fixture: Codable {
        let id: String
        let audioSeconds: Double
        let terms: [String]
        let expected: String
        let verbatim: String
        let cold: BenchRun
        let warm: [BenchRun]
        let warmMedian: Medians
        /// Raw transcript of the cold run against `verbatim`.
        let werRaw: WordErrorRate.Score
        /// Delivered text of the cold run against `expected`.
        let werFinal: WordErrorRate.Score
        /// Every run delivered the same text.
        let stable: Bool
        let unbiased: Unbiased?
    }

    struct Summary: Codable {
        let audioSeconds: Double
        let firstDictationMs: Double
        let werRaw: WordErrorRate.Score
        let werFinal: WordErrorRate.Score
        /// Over the clips with custom words only.
        let werRawWithTerms: WordErrorRate.Score?
        let werRawWithoutTerms: WordErrorRate.Score?
    }

    let date: String
    let machine: Machine
    let configuration: String
    let commit: String
    let speechModel: String
    let modelLoadMs: Double
    let language: String
    let cleanup: String
    let cleanupBackendUsedByApp: String?
    let cleanupModelLoadMs: Double?
    let warmRuns: Int
    let fixtures: [Fixture]
    let summary: Summary

    init(
        settings: BenchSettings, model: SpeechModel, loadMs: Double, cleanup: Cleanup,
        clips: [BenchClip], cold: [String: BenchRun], warm: [String: [BenchRun]],
        unbiased: [String: [UnbiasedRun]]
    ) {
        date = ISO8601DateFormatter().string(from: .now)
        machine = .current
        #if DEBUG
        configuration = "Debug"
        #else
        configuration = "Release"
        #endif
        commit = settings.commit
        speechModel = model.rawValue
        modelLoadMs = loadMs
        language = settings.language
        self.cleanup = cleanup.summary
        cleanupBackendUsedByApp = cleanup.appBackend?.name
        cleanupModelLoadMs = cleanup.localLoadMs
        warmRuns = settings.runs

        fixtures = clips.map { clip in
            let first = cold[clip.id]!
            let runs = warm[clip.id] ?? []
            let unbiasedRuns = unbiased[clip.id]
            return Fixture(
                id: clip.id, audioSeconds: clip.seconds, terms: clip.terms,
                expected: clip.expected, verbatim: clip.verbatim,
                cold: first, warm: runs,
                warmMedian: Medians(
                    transcribeMs: median(runs.map(\.transcribeMs)),
                    appCleanupMs: median(runs.map(\.appCleanupMs)),
                    fitMs: median(runs.map(\.fitMs)),
                    totalMs: median(runs.map(\.totalMs))),
                werRaw: WordErrorRate.score(first.raw, reference: clip.verbatim),
                werFinal: WordErrorRate.score(first.final, reference: clip.expected),
                stable: Set(([first] + runs).map(\.final)).count == 1,
                unbiased: unbiasedRuns.map { runs in
                    Unbiased(
                        medianTranscribeMs: median(runs.map(\.transcribeMs)),
                        raw: runs[0].raw,
                        werRaw: WordErrorRate.score(runs[0].raw, reference: clip.verbatim),
                        runs: runs)
                })
        }

        let withTerms = fixtures.filter { $0.unbiased != nil }
        summary = Summary(
            audioSeconds: clips.map(\.seconds).reduce(0, +),
            firstDictationMs: fixtures.first?.cold.totalMs ?? 0,
            werRaw: fixtures.map(\.werRaw).reduce(.zero, +),
            werFinal: fixtures.map(\.werFinal).reduce(.zero, +),
            werRawWithTerms: withTerms.isEmpty ? nil : withTerms.map(\.werRaw).reduce(.zero, +),
            werRawWithoutTerms: withTerms.isEmpty
                ? nil : withTerms.compactMap(\.unbiased?.werRaw).reduce(.zero, +))
    }

    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: directory.appending(path: "bench.json"))
        try markdown.write(to: directory.appending(path: "bench.md"), atomically: true, encoding: .utf8)
    }

    // MARK: Markdown

    var markdown: String {
        var lines: [String] = [
            "# Dictation bench — \(date)",
            "",
            "| | |",
            "|---|---|",
            "| Machine | \(machine.model) · \(machine.chip) · \(machine.memoryGB) GB |",
            "| macOS | \(machine.os) |",
            "| Build | \(configuration) · \(commit) |",
            "| Speech model | `\(speechModel)` · language `\(language)` |",
            "| Model load + prewarm | \(seconds(modelLoadMs)) s |",
            "| Cleanup | \(cleanup) |",
            "| Cleanup model load | \(cleanupModelLoadMs.map { "\(seconds($0)) s" } ?? "—") |",
            "| Runs | 1 cold + \(warmRuns) warm (median) |",
            "| First dictation after load | \(int(summary.firstDictationMs)) ms (`\(fixtures.first?.id ?? "")`, \(seconds((fixtures.first?.audioSeconds ?? 0) * 1000)) s of audio) |",
            "",
            "Times in ms. **Total** = transcribe + cleanup (as long as the app would wait) + fit; "
                + "recording, dictionary reads and the paste are not included. "
                + "**×RT** = audio length ÷ warm transcribe time. "
                + "**WER raw** = cold-run transcript vs what was said; **WER final** = delivered text vs `expected`.",
            "",
            "| Clip | Audio s | Transcribe cold | Transcribe warm | ×RT | Cleanup cold | Cleanup warm | Fit | Total cold | Total warm | WER raw | WER final |",
            "|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|",
        ]
        for fixture in fixtures {
            let median = fixture.warmMedian
            let speed = median.transcribeMs > 0 ? fixture.audioSeconds / (median.transcribeMs / 1000) : 0
            let cleanupCold = cleanupBackendUsedByApp == nil ? "—" : int(fixture.cold.appCleanupMs)
            let cleanupWarm = cleanupBackendUsedByApp == nil ? "—" : int(median.appCleanupMs)
            lines.append(
                "| \(fixture.id)\(fixture.stable ? "" : " ⚠︎") | \(String(format: "%.1f", fixture.audioSeconds)) "
                    + "| \(int(fixture.cold.transcribeMs)) | \(int(median.transcribeMs)) "
                    + "| \(String(format: "%.1f", speed)) | \(cleanupCold) | \(cleanupWarm) "
                    + "| \(String(format: "%.2f", median.fitMs)) "
                    + "| \(int(fixture.cold.totalMs)) | \(int(median.totalMs)) "
                    + "| \(percent(fixture.werRaw)) | \(percent(fixture.werFinal)) |")
        }
        lines.append(
            "| **All** | \(String(format: "%.1f", summary.audioSeconds)) "
                + "| \(int(fixtures.map(\.cold.transcribeMs).reduce(0, +))) "
                + "| \(int(fixtures.map(\.warmMedian.transcribeMs).reduce(0, +))) | | | | "
                + "| \(int(fixtures.map(\.cold.totalMs).reduce(0, +))) "
                + "| \(int(fixtures.map(\.warmMedian.totalMs).reduce(0, +))) "
                + "| \(percent(summary.werRaw)) | \(percent(summary.werFinal)) |")
        if fixtures.contains(where: { !$0.stable }) {
            lines.append("")
            lines.append("⚠︎ = not every run delivered the same text; WER is from the cold run.")
        }

        let backends = Set(fixtures.flatMap { $0.cold.cleanup.map(\.backend) }).sorted()
        for backend in backends {
            lines += [
                "",
                "## Cleanup: \(backend), without its deadline",
                "",
                "| Clip | Cold ms | Warm ms | Deadline ms | Warm runs past deadline | Cold outcome |",
                "|---|--:|--:|--:|--:|---|",
            ]
            for fixture in fixtures {
                guard let cold = fixture.cold.cleanup.first(where: { $0.backend == backend }) else { continue }
                let warm = fixture.warm.compactMap { $0.cleanup.first { $0.backend == backend } }
                let late = warm.filter { $0.ms > $0.deadlineMs }.count
                lines.append(
                    "| \(fixture.id) | \(int(cold.ms)) | \(int(median(warm.map(\.ms)))) "
                        + "| \(int(cold.deadlineMs)) | \(late)/\(warm.count) | \(cold.outcome.rawValue) |")
            }
        }

        let biased = fixtures.filter { $0.unbiased != nil }
        if !biased.isEmpty {
            lines += [
                "",
                "## Custom words (bias prompt)",
                "",
                "| Clip | Terms | WER raw with | WER raw without | Transcribe warm with | without |",
                "|---|---|--:|--:|--:|--:|",
            ]
            for fixture in biased {
                let unbiased = fixture.unbiased!
                lines.append(
                    "| \(fixture.id) | \(fixture.terms.joined(separator: ", ")) "
                        + "| \(percent(fixture.werRaw)) | \(percent(unbiased.werRaw)) "
                        + "| \(int(fixture.warmMedian.transcribeMs)) | \(int(unbiased.medianTranscribeMs)) |")
            }
        }

        lines += ["", "## Transcripts (cold run)", ""]
        for fixture in fixtures {
            lines.append("- **\(fixture.id)**")
            lines.append("  - expected: \(fixture.expected)")
            if fixture.verbatim != fixture.expected {
                lines.append("  - said: \(fixture.verbatim)")
            }
            lines.append("  - raw: \(shown(fixture.cold.raw))")
            if fixture.cold.final != fixture.cold.raw {
                lines.append("  - delivered: \(fixture.cold.final)")
            }
            if let unbiased = fixture.unbiased {
                lines.append("  - raw without custom words: \(shown(unbiased.raw))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func shown(_ text: String) -> String { text.isEmpty ? "*(empty)*" : text }
    private func int(_ value: Double) -> String { String(Int(value.rounded())) }
    private func seconds(_ ms: Double) -> String { String(format: "%.1f", ms / 1000) }
    private func percent(_ score: WordErrorRate.Score) -> String {
        String(format: "%.1f%%", score.rate * 100)
    }
}

extension BenchReport.Machine {
    static var current: Self {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let build = sysctl("kern.osversion")
        return Self(
            model: sysctl("hw.model"),
            chip: sysctl("machdep.cpu.brand_string"),
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(build))")
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - Word error rate

/// Word error rate: substitutions, deletions and insertions over the number of
/// reference words.
///
/// Both sides are normalised first so formatting that doesn't change the words
/// isn't counted: case, punctuation, "five" vs "5", "1,250" vs "1250",
/// "p.m." vs "PM", "14th" vs "14", and fillers. Formatting that does change
/// them is — "notch voice" for "NotchVoice", or an email spelled out.
enum WordErrorRate {

    struct Score: Codable, Equatable {
        let errors: Int
        let words: Int
        let rate: Double

        init(errors: Int, words: Int) {
            self.errors = errors
            self.words = words
            rate = words == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(words)
        }

        static let zero = Score(errors: 0, words: 0)

        /// Pooled over clips: total errors over total words, so a long clip
        /// counts for more than a short one.
        static func + (lhs: Score, rhs: Score) -> Score {
            Score(errors: lhs.errors + rhs.errors, words: lhs.words + rhs.words)
        }
    }

    static func score(_ hypothesis: String, reference: String) -> Score {
        let reference = words(reference)
        return Score(errors: distance(words(hypothesis), reference), words: reference.count)
    }

    static func words(_ text: String) -> [String] {
        let text = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "%", with: " percent")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "–", with: " ")

        var words: [String] = []
        for chunk in text.split(whereSeparator: \.isWhitespace) {
            // Hyphens split words — "follow-up" is "follow up" — but not
            // inside an address.
            let pieces = chunk.contains("@") ? [chunk] : chunk.split(separator: "-")
            for piece in pieces {
                let word = normalised(piece)
                if !word.isEmpty, !fillers.contains(word) { words.append(word) }
            }
        }
        return words
    }

    private static func normalised(_ piece: Substring) -> String {
        let isWordCharacter = { (c: Character) in c.isLetter || c.isNumber }
        var word = String(piece.drop { !isWordCharacter($0) }.reversed().drop { !isWordCharacter($0) }.reversed())

        // "1,250" → "1250"
        var characters = Array(word)
        characters = characters.indices.compactMap { index in
            let c = characters[index]
            let between = index > 0 && index < characters.count - 1
                && characters[index - 1].isNumber && characters[index + 1].isNumber
            return c == "," && between ? nil : c
        }
        word = String(characters)

        // "p.m" → "pm", "e.g" → "eg"
        let parts = word.split(separator: ".")
        if parts.count > 1, parts.allSatisfy({ $0.count == 1 && $0.first!.isLetter }) {
            word = parts.joined()
        }

        // "14th" → "14"
        for suffix in ["st", "nd", "rd", "th"] where word.hasSuffix(suffix) {
            let number = word.dropLast(2)
            if !number.isEmpty, number.allSatisfy(\.isNumber) { word = String(number) }
        }

        return numbers[word] ?? word
    }

    private static let fillers: Set<String> = ["um", "umm", "uh", "uhm", "erm", "hmm", "mm", "mhm"]

    private static let numbers: [String: String] = {
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                     "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                     "seventeen", "eighteen", "nineteen", "twenty"]
        let tens = ["thirty": "30", "forty": "40", "fifty": "50", "sixty": "60",
                    "seventy": "70", "eighty": "80", "ninety": "90"]
        var map = tens
        for (value, word) in units.enumerated() { map[word] = String(value) }
        return map
    }()

    /// Word-level Levenshtein distance.
    static func distance(_ hypothesis: [String], _ reference: [String]) -> Int {
        guard !hypothesis.isEmpty else { return reference.count }
        guard !reference.isEmpty else { return hypothesis.count }
        var previous = Array(0 ... reference.count)
        for (i, word) in hypothesis.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: reference.count)
            for (j, target) in reference.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + (word == target ? 0 : 1))
            }
            previous = current
        }
        return previous[reference.count]
    }
}

// MARK: - Helpers

/// Runs `body` on the caller's actor, so nothing crosses isolation.
private func measure<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async rethrows -> (T, Duration) {
    let started = ContinuousClock.now
    let value = try await body()
    return (value, started.duration(to: .now))
}

private func timed<T>(_ body: () throws -> T) rethrows -> (T, Duration) {
    let started = ContinuousClock.now
    let value = try body()
    return (value, started.duration(to: .now))
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

private extension Duration {
    var ms: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}

// MARK: - The metric itself

@Suite("Bench word error rate")
struct WordErrorRateTests {

    @Test("formatting that keeps the words is not an error",
          arguments: [
              ("Sounds good, see you at lunch.", "sounds good see you at lunch"),
              ("Let's meet at five.", "Let’s meet at 5"),
              ("It comes to $1,250.", "it comes to 1250"),
              ("Due by 3:30 p.m. on March 14.", "due by 3:30 PM on March 14th"),
              ("A 15% discount", "a 15 percent discount"),
              ("So, um, a follow-up", "so a follow up"),
          ])
    func formattingIsFree(_ reference: String, _ hypothesis: String) {
        #expect(WordErrorRate.score(hypothesis, reference: reference).errors == 0)
    }

    @Test("an email address stays one word")
    func emailIsOneWord() {
        #expect(WordErrorRate.words("Email priya.sharma@example.com.") == ["email", "priya.sharma@example.com"])
        #expect(WordErrorRate.score("priya dot sharma at example dot com",
                                    reference: "priya.sharma@example.com").errors == 7)
    }

    @Test("substitutions, deletions and insertions each count once")
    func editsCount() {
        #expect(WordErrorRate.score("a x c", reference: "a b c d") == .init(errors: 2, words: 4))
        #expect(WordErrorRate.score("a b c", reference: "a b") == .init(errors: 1, words: 2))
        #expect(WordErrorRate.score("notch voice", reference: "NotchVoice").errors == 2)
    }

    @Test("empty sides")
    func empty() {
        #expect(WordErrorRate.score("", reference: "") == .zero)
        #expect(WordErrorRate.score("", reference: "one two").rate == 1)
        #expect(WordErrorRate.score("extra", reference: "").rate == 1)
    }

    @Test("scores pool by words, not by clip")
    func pooling() {
        let pooled = WordErrorRate.Score(errors: 1, words: 2) + .init(errors: 0, words: 8)
        #expect(pooled.rate == 0.1)
    }
}
