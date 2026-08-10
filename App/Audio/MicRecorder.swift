import AVFoundation
import NotchVoiceCore

enum MicRecorderError: Error {
    case engineFailed(String)
    case converterUnavailable
}

/// Captures microphone audio into a 16 kHz mono Float32 buffer, which is the
/// format Whisper expects.
///
/// The hardware runs at whatever rate it likes (usually 48 kHz), so every tap
/// buffer is converted before being accumulated. Conversion happens on the
/// audio thread, which is acceptable because `AVAudioConverter` on a small
/// buffer is cheap and the alternative — shipping raw buffers to another
/// thread — costs more in allocation than it saves.
@MainActor
final class MicRecorder {

    /// Whisper's required input rate.
    private static let targetSampleRate: Double = 16_000
    /// How many level callbacks per second the waveform gets.
    private static let levelsPerSecond: Double = 20

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var isRunning = false
    private var startedAt: Date?

    /// Fires with an RMS level in `0...1` roughly 20 times a second.
    var onLevel: ((Float) -> Void)?

    var duration: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    func start() throws {
        guard !isRunning else { return }
        samples.removeAll(keepingCapacity: true)

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MicRecorderError.converterUnavailable
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw MicRecorderError.converterUnavailable
        }
        self.converter = converter

        // Tap buffer sized so one callback is roughly one waveform bar.
        let tapFrames = AVAudioFrameCount(
            hardwareFormat.sampleRate / Self.levelsPerSecond
        )

        input.installTap(onBus: 0, bufferSize: tapFrames, format: hardwareFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            let converted = Self.convert(buffer, using: converter, to: targetFormat)
            guard !converted.isEmpty else { return }
            let level = LevelBuffer.rms(converted)
            Task { @MainActor in
                self.samples.append(contentsOf: converted)
                self.onLevel?(min(level * 4, 1))  // ×4 so speech fills the bars
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicRecorderError.engineFailed(error.localizedDescription)
        }

        isRunning = true
        startedAt = Date()
    }

    /// Stops capture and hands back everything recorded.
    func stop() -> [Float] {
        teardown()
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        return captured
    }

    /// Stops capture and throws the audio away.
    func discard() {
        teardown()
        samples.removeAll(keepingCapacity: false)
    }

    private func teardown() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
        startedAt = nil
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: capacity
        ) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
