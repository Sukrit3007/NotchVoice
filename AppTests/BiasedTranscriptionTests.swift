import AVFoundation
import Foundation
import NotchVoiceCore
import Testing
@testable import NotchVoice

/// The installed speech model transcribing with a bias prompt, through
/// `WhisperKitService` as the app calls it.
///
/// Guards the regression where any prompt — custom words or on-screen text —
/// came back as an empty transcript (WhisperKit 0.x, argmax-oss-swift #501),
/// and the opposite one: silence coming back as words.
/// Needs the real model, so it is skipped where the app has not downloaded
/// one; it never downloads.
@Suite("Biased transcription")
struct BiasedTranscriptionTests {

    static let model = ModelPreference.current

    /// Where `WhisperKit.download` puts the variant, or nil when it is absent.
    static let folder: URL? = {
        let folder = AppPaths.models
            .appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
            .appending(path: model.rawValue, directoryHint: .isDirectory)
        let encoder = folder.appending(path: "AudioEncoder.mlmodelc").path
        return FileManager.default.fileExists(atPath: encoder) ? folder : nil
    }()

    @Test("custom words and screen text bias the transcript instead of emptying it",
          .enabled(if: folder != nil, "Speech model not installed; open Notch Voice once to download it"),
          .timeLimit(.minutes(5)))
    func biasedTranscriptIsNotEmpty() async throws {
        let service = WhisperKitService(model: Self.model)
        try await service.load(from: try #require(Self.folder))

        // One custom word, spoken as three: "fetch user profile".
        let code = try Self.samples("code-term")
        let custom = try await service.transcribe(
            code, prompt: BiasPrompt.build(terms: ["fetchUserProfile"]), language: "en")
        #expect(custom.contains("fetchUserProfile"), "got: \(custom)")

        // Custom words plus text from the field, with the language forced.
        let names = try Self.samples("names")
        let screen = "Release checklist. Ping Arjun about the TestFlight build before Friday."
        let withContext = try await service.transcribe(
            names,
            prompt: BiasPrompt.build(terms: ["Propsoch", "NotchVoice"], context: screen),
            language: "en")
        #expect(withContext.contains("Propsoch"), "got: \(withContext)")
        #expect(withContext.contains("NotchVoice"), "got: \(withContext)")

        // The same with the language left to the decoder.
        let detected = try await service.transcribe(
            code, prompt: BiasPrompt.build(terms: ["fetchUserProfile"]), language: nil)
        #expect(detected.contains("fetchUserProfile"), "got: \(detected)")
    }

    @Test("a silent take comes back empty, prompt or not",
          .enabled(if: folder != nil, "Speech model not installed; open Notch Voice once to download it"),
          .timeLimit(.minutes(5)))
    func silentTakeIsEmpty() async throws {
        // Whisper answers silence with words: "you" on its own, and with a
        // prompt "Thank you.", "S." or the custom words. None of that may
        // reach the document.
        let service = WhisperKitService(model: Self.model)
        try await service.load(from: try #require(Self.folder))
        let terms = ["Priya", "Propsoch", "Arjun", "NotchVoice", "TestFlight"]
        let prompts: [(String, String?)] = [
            ("no prompt", nil),
            ("custom words", BiasPrompt.build(terms: terms)),
            ("custom words and screen text", BiasPrompt.build(terms: terms, context: Self.screenText)),
        ]

        for (take, samples) in [("silence", Self.silence), ("faint noise", Self.faintNoise)] {
            for (label, prompt) in prompts {
                for language in ["en", nil] as [String?] {
                    let text = try await Self.transcript(service, samples, prompt: prompt, language: language)
                    #expect(text.isEmpty,
                            "\(take), \(label), \(language ?? "auto"): got \"\(text)\"")
                }
            }
        }
    }

    /// Two seconds of digital silence.
    static let silence = [Float](repeating: 0, count: 32_000)

    /// Two seconds of noise peaking at 0.003, the same on every run.
    static let faintNoise: [Float] = {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        return (0 ..< 32_000).map { _ in
            // SplitMix64.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return (Float(z >> 40) / Float(1 << 24) - 0.5) * 0.006
        }
    }()

    /// A field's worth of text, about as much as `BiasPrompt` takes from one.
    static let screenText = """
        The new onboarding flow is nearly ready, but I want to tidy a few things \
        before we ship it. The permissions screen still asks for accessibility \
        before it explains why, which feels backwards. The model download takes \
        too long on a slow connection, so we should show its size up front. Once \
        that is done, I will record a short video for the release notes.
        """

    /// The transcript, or "" where the service reports an empty one.
    static func transcript(
        _ service: WhisperKitService, _ samples: [Float], prompt: String?, language: String?
    ) async throws -> String {
        do {
            return try await service.transcribe(samples, prompt: prompt, language: language)
        } catch TranscriptionError.empty {
            return ""
        }
    }

    /// A clip from `Tools/Bench/Fixtures`: 16 kHz mono, as `MicRecorder` hands
    /// audio over.
    static func samples(_ id: String) throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Tools/Bench/Fixtures/\(id).wav")
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        #expect(file.processingFormat.sampleRate == 16_000)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
