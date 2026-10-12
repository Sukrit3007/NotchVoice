import AVFoundation
import Foundation
import NotchVoiceCore
import Testing
@testable import NotchVoice

/// The installed speech model transcribing with a bias prompt, through
/// `WhisperKitService` as the app calls it.
///
/// Guards the regression where any prompt — custom words or on-screen text —
/// came back as an empty transcript (WhisperKit 0.x, argmax-oss-swift #501).
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
