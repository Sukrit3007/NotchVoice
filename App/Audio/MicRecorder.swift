import AVFoundation
import NotchVoiceCore
import Synchronization

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

    /// Samples are accumulated under a lock, straight from the audio thread,
    /// rather than hopped onto the main actor with `Task { @MainActor in … }`.
    /// The hop clipped the tail off every take: `stop()` is synchronous, so it
    /// never suspends, and any append still queued on the main actor could not
    /// have run yet. Measured: 2-3 buffers (100-150 ms of speech) lost with the
    /// main actor merely busy at 60fps, and the entire take lost when it was
    /// blocked. The stranded appends then landed *after* `stop()` cleared the
    /// array and turned into the head of the next recording. Keep this on the
    /// lock; do not route it back through the main actor.
    private nonisolated let store = Mutex<[Float]>([])

    private var isRunning = false
    private var startedAt: Date?

    /// Fires with an RMS level in `0...1` roughly 20 times a second. Read once
    /// when `start()` installs the tap, so set it before starting.
    ///
    /// Main-actor isolated because every caller drives UI with it — the
    /// waveform's sample buffer lives on the main actor, and a plain `@Sendable`
    /// closure could not touch it.
    var onLevel: (@MainActor @Sendable (Float) -> Void)?

    var duration: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    func start() throws {
        guard !isRunning else { return }
        store.withLock { $0.removeAll(keepingCapacity: true) }

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

        // Grabbed here so the audio thread never reaches for main-actor state.
        let onLevel = self.onLevel

        input.installTap(
            onBus: 0,
            bufferSize: tapFrames,
            format: hardwareFormat,
            block: Self.makeTap(
                for: self,
                converter: converter,
                targetFormat: targetFormat,
                onLevel: onLevel
            )
        )

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
        return store.withLock { captured in
            let samples = captured
            captured.removeAll(keepingCapacity: false)
            return samples
        }
    }

    /// Stops capture and throws the audio away.
    func discard() {
        teardown()
        store.withLock { $0.removeAll(keepingCapacity: false) }
    }

    private func teardown() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
        startedAt = nil
    }

    /// Builds the tap block from a `nonisolated` context so the closure inherits
    /// nonisolated too. Written inline in `start()`, the closure inherited this
    /// class's `@MainActor` isolation, and Swift emitted a dynamic isolation
    /// check at its entry — CoreAudio then called it on the audio thread and
    /// `dispatch_assert_queue(main)` aborted the process on the first buffer.
    /// `@Sendable` does not help: `@MainActor @Sendable` is a valid pair.
    /// Keeping the block nonisolated also means the compiler now rejects any
    /// main-actor access from the tap instead of letting it crash on device.
    private nonisolated static func makeTap(
        for recorder: MicRecorder,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        onLevel: (@MainActor @Sendable (Float) -> Void)?
    ) -> AVAudioNodeTapBlock {
        return { [weak recorder] buffer, _ in
            guard let recorder else { return }
            let converted = convert(buffer, using: converter, to: targetFormat)
            guard !converted.isEmpty else { return }
            recorder.store.withLock { $0.append(contentsOf: converted) }

            // The level is only a waveform bar, so it can afford the hop —
            // a late or dropped bar costs nothing, a late sample costs audio.
            guard let onLevel else { return }
            let level = LevelBuffer.rms(converted)
            Task { @MainActor in
                onLevel(min(level * 4, 1))  // ×4 so speech fills the bars
            }
        }
    }

    private nonisolated static func convert(
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
