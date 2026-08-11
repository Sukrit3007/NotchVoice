import AppKit
import Combine
import NotchVoiceCore

/// Wires the tap, the state machine, the recorder, transcription, and delivery
/// into one flow. The only object that knows the whole pipeline.
@MainActor
final class DictationCoordinator: ObservableObject {

    enum Phase: Equatable {
        case dormant
        case recording
        case locked
        case transcribing
        case done
        case tooShort
        case error(String)
    }

    /// Below this, there is not enough audio to transcribe usefully.
    ///
    /// Tied to the hold threshold rather than set independently. As two free
    /// literals — hold 0.4, minimum 0.5 — every press lasting between them was
    /// accepted by the state machine as a deliberate push-to-talk and then
    /// binned by this guard, so a quick but intentional press recorded, showed
    /// "Too short" for 900ms, and pasted nothing. Observed in practice: a real
    /// press measured 0.427s and vanished. The machine decides what counts as
    /// a hold; anything it accepts must be long enough to transcribe.
    private static var minimumDuration: TimeInterval { thresholds.hold }
    /// Locked sessions would otherwise run unbounded. Spec §5.
    private static let maximumDuration: TimeInterval = 300
    /// How many bars the waveform shows.
    private static let waveformBarCount = 28
    /// How long a terminal phase stays on screen before collapsing.
    private static let doneDwell = Duration.milliseconds(900)
    private static let errorDwell = Duration.seconds(4)
    /// One source of truth for the gesture windows: the machine decides whether
    /// a second tap was in time, and the timer below decides when to tell it the
    /// window closed. Two literals would drift apart silently.
    private static let thresholds = RecordingStateMachine.Thresholds()

    @Published private(set) var phase: Phase = .dormant
    @Published private(set) var levels: [Float]

    var onPhaseChange: ((Phase) -> Void)?

    private var machine: RecordingStateMachine
    private let recorder = MicRecorder()
    private let transcriber = WhisperKitService()
    private var tap: ModifierTap?

    private var buffer: LevelBuffer
    private var focus: FocusSnapshot?
    private var doubleTapTimer: Task<Void, Never>?
    private var maxDurationTimer: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?

    /// Bumped on every capture. Transcription is async and the state machine has
    /// no transcribing state, so a second dictation can begin while the first is
    /// still decoding; the late result must not stamp `.done` over the phase of
    /// the recording that is now in progress. Its text is still delivered — the
    /// user said those words — only the phase update is dropped.
    private var session = 0

    init() {
        let buffer = LevelBuffer(capacity: Self.waveformBarCount)
        self.buffer = buffer
        self.levels = buffer.levels
        self.machine = RecordingStateMachine(thresholds: Self.thresholds)
    }

    func start() {
        // Before anything can start a capture: MicRecorder reads `onLevel` once,
        // when start() installs the audio tap, so a later assignment is ignored.
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            buffer.append(level)
            levels = buffer.levels
        }

        let binding = BindingStore.binding
        NSLog("[NotchVoice] binding: %@ (keycode %d)",
              binding.displayName, Int(binding.rawValue))

        let tap = ModifierTap(binding: binding)
        tap.onKeyDown = { [weak self] in self?.dispatch(.keyDown(at: Self.now())) }
        tap.onKeyUp = { [weak self] in self?.dispatch(.keyUp(at: Self.now())) }
        // Both of these fire far beyond our own gesture — `onEscape` on every
        // Escape anywhere in the system, `onOtherKey` on modifier traffic that
        // only means interference while the binding is held. Dropping them when
        // idle keeps the log readable; the machine ignores them there anyway.
        tap.onOtherKey = { [weak self] in self?.dispatchIfActive(.otherKeyPressed) }
        tap.onEscape = { [weak self] in self?.dispatchIfActive(.escapePressed) }

        guard tap.start() else {
            // Not a crash and not a hang. ModifierTap returns false only when
            // Input Monitoring is ungranted, and there is no way to arm later
            // without a relaunch, so say so instead of sitting there dead.
            NSLog("[NotchVoice] tap did NOT arm — Input Monitoring is not granted.")
            NSLog("[NotchVoice] Grant it in System Settings > Privacy & Security >")
            NSLog("[NotchVoice] Input Monitoring, then relaunch this binary.")
            NSLog("[NotchVoice] Skipping model load: nothing can trigger a dictation.")
            setPhase(.error("Input Monitoring permission needed"))
            return
        }
        self.tap = tap
        NSLog("[NotchVoice] tap armed")

        if !Paster.isAccessibilityTrusted() {
            // Not fatal: Paster falls back to leaving the transcript on the
            // clipboard. Logged because "text did not appear at the cursor" is
            // otherwise indistinguishable from a broken pipeline.
            NSLog("[NotchVoice] Accessibility NOT granted — transcripts will be")
            NSLog("[NotchVoice] copied to the clipboard instead of pasted.")
        }

        Task {
            let startedAt = Self.now()
            NSLog("[NotchVoice] loading model… (~12s; dictation is unavailable until ready)")
            do {
                try await transcriber.prepare { _ in }
                NSLog("[NotchVoice] model ready in %.1fs", Self.now() - startedAt)
            } catch {
                NSLog("[NotchVoice] model FAILED to load: %@", error.localizedDescription)
                setPhase(.error("Model failed to load: \(error.localizedDescription)"))
            }
        }
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func dispatch(_ event: RecordingStateMachine.Event) {
        let effect = machine.handle(event)
        NSLog("[NotchVoice] %@ -> %@ (state: %@)",
              String(describing: event),
              String(describing: effect),
              String(describing: machine.state))
        apply(effect)
    }

    /// Only forwards while a dictation is actually in flight.
    private func dispatchIfActive(_ event: RecordingStateMachine.Event) {
        guard machine.state != .idle else { return }
        dispatch(event)
    }

    private func apply(_ effect: RecordingStateMachine.Effect) {
        switch effect {
        case .none:
            break

        case .startCapture:
            beginCapture()

        case .restartCapture:
            // A second tap arrived too late to lock, so the first tap's audio
            // is stale. Drop it before starting over — MicRecorder.start()
            // no-ops while already running, so without this the stale samples
            // would be prepended to the new dictation and pasted.
            recorder.discard()
            beginCapture()

        case .armDoubleTapTimer:
            armDoubleTapTimer()

        case .enterLocked:
            cancelDoubleTapTimer()
            setPhase(.locked)

        case .stopAndTranscribe:
            cancelTimers()
            finishAndTranscribe()

        case .discard:
            cancelTimers()
            recorder.discard()
            resetWaveform()
            setPhase(.dormant)
        }
    }

    private func beginCapture() {
        collapseTask?.cancel()
        session &+= 1
        // Captured before any window is shown — see FocusSnapshot's note.
        focus = FocusSnapshot.capture()
        resetWaveform()

        do {
            try recorder.start()
        } catch {
            NSLog("[NotchVoice] recorder failed to start: %@", String(describing: error))
            setPhase(.error("Microphone unavailable"))
            scheduleCollapse(after: Self.errorDwell)
            return
        }

        setPhase(.recording)
        armMaxDurationTimer()
    }

    private func finishAndTranscribe() {
        let duration = recorder.duration
        let samples = recorder.stop()
        resetWaveform()

        // Peak and RMS are logged alongside the sample count because "Nothing
        // heard" has two completely different causes that look identical from
        // outside: the user did not speak, or the microphone captured silence
        // while they did. A peak near zero means no signal ever arrived and
        // the problem is the input device or its volume, not the model.
        let peak = samples.reduce(0 as Float) { max($0, abs($1)) }
        let rms = LevelBuffer.rms(samples)
        NSLog("[NotchVoice] captured %.2fs, %d samples (%.2fs of audio), peak %.4f rms %.4f",
              duration, samples.count, Double(samples.count) / 16_000, peak, rms)
        if peak < 0.01 {
            NSLog("[NotchVoice] audio is effectively SILENT — check the input device and its volume")
        }

        guard duration >= Self.minimumDuration else {
            setPhase(.tooShort)
            scheduleCollapse(after: Self.doneDwell)
            return
        }

        setPhase(.transcribing)
        let target = focus
        let session = self.session

        Task {
            let startedAt = Self.now()
            do {
                let text = try await transcriber.transcribe(samples)
                NSLog("[NotchVoice] transcribed in %.2fs: \"%@\"",
                      Self.now() - startedAt, text)

                // Silence does NOT come back empty. Measured: a take with no
                // speech transcribes as ".", which sails past the service's
                // is-it-empty check and would be pasted into the user's
                // document. Anything with no letter and no digit in it is not
                // something the user said, so it is never delivered.
                guard Self.hasSpeech(text) else {
                    NSLog("[NotchVoice] no alphanumeric content — treating as silence, not pasting")
                    finish(session, with: .error("Nothing heard"), dwell: Self.errorDwell)
                    return
                }

                let outcome = await Paster.deliver(text, to: target)
                NSLog("[NotchVoice] delivery: %@ (target %@)",
                      String(describing: outcome), target?.bundleID ?? "none")
                finish(session, with: .done, dwell: Self.doneDwell)
            } catch TranscriptionError.empty {
                NSLog("[NotchVoice] transcription empty")
                finish(session, with: .error("Nothing heard"), dwell: Self.errorDwell)
            } catch TranscriptionError.notReady {
                // The model takes ~12s to load at launch; a hotkey pressed in
                // that window lands here. The audio is gone, but nothing hangs
                // and the next dictation works.
                NSLog("[NotchVoice] model not ready yet — dictation dropped")
                finish(session, with: .error("Still loading model…"), dwell: Self.errorDwell)
            } catch {
                NSLog("[NotchVoice] transcription failed: %@", String(describing: error))
                finish(session, with: .error(error.localizedDescription), dwell: Self.errorDwell)
            }
        }
    }

    /// Applies a terminal phase, unless a newer dictation has already started.
    private func finish(_ session: Int, with phase: Phase, dwell: Duration) {
        guard session == self.session else {
            NSLog("[NotchVoice] session %d finished late (now %d) — phase left alone",
                  session, self.session)
            return
        }
        setPhase(phase)
        scheduleCollapse(after: dwell)
    }

    /// Whisper punctuates silence rather than returning nothing, so emptiness
    /// is not a usable test. A transcript with no letter and no digit anywhere
    /// carries no words — `.`, `...`, `?!` — and must not reach the clipboard.
    /// `isLetter`/`isNumber` are Unicode-aware, so non-Latin scripts survive.
    private static func hasSpeech(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: - Timers

    private func armDoubleTapTimer() {
        cancelDoubleTapTimer()
        doubleTapTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.thresholds.doubleTap))
            guard !Task.isCancelled else { return }
            self?.dispatch(.doubleTapWindowExpired)
        }
    }

    private func armMaxDurationTimer() {
        maxDurationTimer?.cancel()
        maxDurationTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumDuration))
            guard !Task.isCancelled else { return }
            self?.dispatch(.maxDurationReached)
        }
    }

    private func cancelDoubleTapTimer() {
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
    }

    private func cancelTimers() {
        cancelDoubleTapTimer()
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
    }

    private func scheduleCollapse(after delay: Duration) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.setPhase(.dormant)
        }
    }

    // MARK: - Helpers

    private func resetWaveform() {
        buffer.reset()
        levels = buffer.levels
    }

    private func setPhase(_ next: Phase) {
        phase = next
        onPhaseChange?(next)
    }
}
