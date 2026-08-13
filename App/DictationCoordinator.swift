import AppKit
import NotchVoiceCore
import Observation

/// Wires the tap, the state machine, the recorder, transcription, polish and
/// delivery into one flow. The only object that knows the whole pipeline.
@MainActor
@Observable
final class DictationCoordinator {

    enum Phase: Equatable {
        case dormant
        case recording
        case locked
        case transcribing
        /// The transcript is being tidied by the on-device model. Bounded by
        /// `polishDeadline` — see `PolishService`.
        case polishing
        case done
        /// Transcribed, but only reached the clipboard — the target app never
        /// consumed the paste. Separate from `.done` because nothing appeared at
        /// the cursor and the user needs to know the text is on the clipboard.
        case copied
        case tooShort
        case error(DictationFailure)

        /// The sentence to show in the panel below the notch, if this phase has
        /// something to say that will not fit in the island's wing.
        var panelMessage: String? {
            switch self {
            case let .error(failure): failure.message
            case .tooShort: "That was too brief to transcribe. Hold the key while you speak."
            case .copied: "Text copied. Press ⌘V to paste it where you want it."
            default: nil
            }
        }
    }

    /// Whether a dictation could start at all, as distinct from what one is
    /// doing right now.
    ///
    /// A phase is transient; "Input Monitoring was never granted" is not.
    /// Permanent conditions belong to Settings — the island only tints its
    /// resting glyph to say something is wrong.
    enum Readiness: Equatable {
        /// ~12s at launch. Dictation fails until it finishes.
        case loadingModel
        case ready
        case needsPermission
        case modelUnavailable(String)

        var canDictate: Bool { self == .ready }
    }

    /// Below this, there is not enough audio to transcribe usefully.
    ///
    /// Derived from the hold threshold, not set independently: anything the
    /// state machine accepts as a deliberate hold must be long enough to
    /// transcribe, or it is accepted and then binned.
    private static var minimumDuration: TimeInterval { thresholds.hold }
    /// Locked sessions would otherwise run unbounded. Spec §5.
    private static let maximumDuration: TimeInterval = 300
    /// Ring buffer capacity. One slot per bar, so this must match the view —
    /// and the wing that holds them is sized in Core, where a test checks it.
    private static let waveformBarCount = IslandMetrics.waveformBarCount

    /// Level below which a take will not transcribe.
    ///
    /// Levels arrive pre-scaled as `min(rms * 4, 1)` (MicRecorder). Measured on
    /// real takes: failures came in at 0.031 and 0.060, successes at 0.310 and
    /// 0.564. This floor sits in that gap.
    private static let quietFloor: Float = 0.12

    /// How long to listen before deciding a take is too quiet.
    ///
    /// Load-bearing: `LevelBuffer` starts zero-padded, so without this the
    /// warning fires on the first frame of every dictation.
    private static let quietGrace: TimeInterval = 0.8

    /// How long a terminal phase stays on screen before collapsing.
    private static let doneDwell = Duration.milliseconds(900)
    /// Longer than `doneDwell` because these phases put a sentence in the panel,
    /// and a sentence has to be readable before it leaves.
    private static let errorDwell = Duration.seconds(4)

    /// How long the polish step may take before the raw transcript is delivered.
    ///
    /// A guess, not a measurement. Tune against real dictations: too low and
    /// polish never lands, too high and every dictation pays for it.
    private static let polishDeadline = Duration.milliseconds(400)

    /// One source of truth for the gesture window.
    private static let thresholds = RecordingStateMachine.Thresholds()

    // The four properties a view reads. Everything below is `@ObservationIgnored`
    // so that bumping a session counter or swapping a timer does not invalidate
    // the island.
    private(set) var phase: Phase = .dormant
    private(set) var readiness: Readiness = .loadingModel
    private(set) var levels: [Float]
    /// True once the microphone has been reading near-silence for long enough
    /// that this take will not transcribe. Surfaced while the user can still do
    /// something about it, rather than as "Didn't hear anything" after the fact.
    private(set) var inputTooQuiet = false

    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?

    /// Fired on every binding key-down, alongside normal dispatch. Settings'
    /// live test is the only consumer — an event arriving here is proof the tap
    /// is delivering, which `IOHIDCheckAccess` cannot tell us.
    @ObservationIgnored var onBindingKeyDown: (() -> Void)?

    @ObservationIgnored private var machine: RecordingStateMachine
    @ObservationIgnored private let recorder = MicRecorder()
    @ObservationIgnored private let transcriber = WhisperKitService()
    @ObservationIgnored private let polisher = PolishService()
    @ObservationIgnored private let store: CaptureStore
    @ObservationIgnored private var tap: ModifierTap?

    @ObservationIgnored private var buffer: LevelBuffer
    @ObservationIgnored private var focus: FocusSnapshot?
    @ObservationIgnored private var maxDurationTimer: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?

    /// Mirrors `WhisperKitService.isReady`, which is actor-isolated and so
    /// cannot be read from a synchronous path like `armTap()`.
    @ObservationIgnored private var modelLoaded = false

    /// Bumped on every capture. A second dictation can begin while the first is
    /// still decoding, and the late result must not stamp `.done` over the
    /// recording now in progress. Its text is still delivered — the user said
    /// those words — only the phase update is dropped.
    @ObservationIgnored private var session = 0

    init(stack: DataStack = .shared) {
        let buffer = LevelBuffer(capacity: Self.waveformBarCount)
        self.buffer = buffer
        self.levels = buffer.levels
        self.machine = RecordingStateMachine(thresholds: Self.thresholds)
        self.store = CaptureStore(modelContainer: stack.container)
    }

    func start() {
        // Before anything can start a capture: MicRecorder reads `onLevel` once,
        // when start() installs the audio tap, so a later assignment is ignored.
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            buffer.append(level)
            levels = buffer.levels

            // Gated on elapsed time, not on the buffer alone: LevelBuffer is
            // zero-padded from construction, so "every level is low" is true
            // for the first second of every take regardless of the speaker.
            guard recorder.duration >= Self.quietGrace else {
                inputTooQuiet = false
                return
            }
            inputTooQuiet = (buffer.levels.max() ?? 0) < Self.quietFloor
        }

        Cues.prewarm()

        guard armTap() else {
            // Not a crash and not a hang: nothing can trigger a dictation, so
            // loading a 632MB model would be a waste. Settings owns the recovery
            // from here.
            Log.dictation.notice("Skipping model load: nothing can trigger a dictation")
            return
        }

        loadModel()
        Task { await polisher.prepare() }
    }

    /// Creates the event tap and reports whether it can actually deliver events.
    ///
    /// Separate from `start()` and safe to call again, because Settings needs
    /// to retry it the moment a permission is granted — and again on every
    /// rebind.
    @discardableResult
    func armTap() -> Bool {
        tap?.stop()
        tap = nil

        // Resolved, not taken as stored: an external non-Apple keyboard has no
        // fn key, and binding to a key that cannot be pressed is an app that
        // looks fine and does nothing.
        let stored = BindingStore.binding
        let binding = KeyboardCapabilities.resolve(stored)
        if binding != stored { BindingStore.binding = binding }

        Log.input.info(
            "Binding: \(binding.displayName, privacy: .public) (keycode \(binding.rawValue, privacy: .public))")

        let tap = ModifierTap(binding: binding)
        tap.onKeyDown = { [weak self] in
            guard let self else { return }
            onBindingKeyDown?()
            dispatch(.keyDown(at: Self.now()))
        }
        tap.onKeyUp = { [weak self] in self?.dispatch(.keyUp(at: Self.now())) }
        tap.onChord = { [weak self] in self?.dispatchIfActive(.chordPressed) }
        // Both of these fire far beyond our own gesture. Dropping them when idle
        // keeps the log readable; the machine ignores them there anyway.
        tap.onOtherKey = { [weak self] in self?.dispatchIfActive(.otherKeyPressed) }
        tap.onEscape = { [weak self] in self?.dispatchIfActive(.escapePressed) }

        guard tap.start() else {
            Log.input.error("Tap did NOT arm — Accessibility or Input Monitoring is missing")
            readiness = .needsPermission
            return false
        }

        self.tap = tap
        Log.input.info("Tap armed")
        // Deliberately not `.ready`: the tap is only half of it, and the model
        // may still be 12 seconds from transcribing anything.
        if readiness == .needsPermission {
            readiness = modelLoaded ? .ready : .loadingModel
        }
        return true
    }

    /// Changes the dictation key and re-arms the tap against it.
    ///
    /// Not `BindingStore.binding = key; armTap()` at the call site: `armTap()`
    /// tears the old tap down, and if the old key is *held* at that moment its
    /// `keyUp` never arrives — the machine strands in `.holding`, the recorder
    /// keeps running, and the next press reads as a release. The in-flight
    /// gesture has to be abandoned first, and `machine` is private.
    ///
    /// The session counter is left alone: a transcription already in flight
    /// still delivers its text. Only the gesture is cancelled.
    @discardableResult
    func rebind(to key: ModifierKey) -> Bool {
        cancelTimers()
        collapseTask?.cancel()
        recorder.discard()
        machine = RecordingStateMachine(thresholds: Self.thresholds)
        resetWaveform()
        setPhase(.dormant)

        BindingStore.binding = key
        Log.input.info("Rebound to \(key.displayName, privacy: .public)")
        return armTap()
    }

    /// Loads the speech model. No-ops if it is already resident.
    func loadModel() {
        Task {
            let startedAt = Self.now()
            Log.dictation.info("Loading model… (~12s; dictation is unavailable until ready)")
            do {
                try await transcriber.prepare { _ in }
                Log.dictation.info("Model ready in \(Self.now() - startedAt, privacy: .public)s")
                modelLoaded = true
                if readiness != .needsPermission { readiness = .ready }
            } catch {
                Log.dictation.error(
                    "Model FAILED to load: \(error.localizedDescription, privacy: .public)")
                readiness = .modelUnavailable(error.localizedDescription)
            }
        }
    }

    /// Whether the on-device cleanup model can run. Surfaced in Settings.
    nonisolated var polishAvailability: PolishAvailability {
        polisher.availability
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func dispatch(_ event: RecordingStateMachine.Event) {
        let effect = machine.handle(event)
        Log.dictation.debug(
            "\(String(describing: event), privacy: .public) -> \(String(describing: effect), privacy: .public) (state: \(String(describing: self.machine.state), privacy: .public))")
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

        case .enterLocked:
            setPhase(.locked)
            Cues.play(.lock)

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

        armMaxDurationTimer()

        do {
            try recorder.start()
        } catch {
            Log.audio.error(
                "Recorder failed to start: \(String(describing: error), privacy: .public)")
            fail(with: .noMicrophone)
            return
        }

        // On the key-down itself, with no settling delay: the tap consumes fn,
        // so it cannot compose a character the island would flash on.
        setPhase(.recording)
        Cues.play(.start)
    }

    private func finishAndTranscribe() {
        let duration = recorder.duration
        let samples = recorder.stop()

        // The meter is deliberately NOT cleared — it holds its last frame and
        // dims. See `WaveformView.dimmed`.

        // Peak and RMS separate the two causes of a silent take, which look
        // identical from outside: the user did not speak, or the microphone
        // captured silence while they did. A peak near zero means no signal ever
        // arrived, so the problem is the input device rather than the model.
        let peak = samples.reduce(0 as Float) { max($0, abs($1)) }
        let rms = LevelBuffer.rms(samples)
        Log.audio.info(
            "Captured \(duration, privacy: .public)s, \(samples.count, privacy: .public) samples, peak \(peak, privacy: .public) rms \(rms, privacy: .public)")
        if peak < 0.01 {
            Log.audio.notice("Audio is effectively SILENT — check the input device and its volume")
        }

        guard duration >= Self.minimumDuration else {
            setPhase(.tooShort)
            scheduleCollapse(after: Self.doneDwell)
            return
        }

        setPhase(.transcribing)
        // After the minimum-duration guard, so a too-short take stays silent.
        // Decoding runs for a second or two and the loop needs a sound in it.
        Cues.play(.stop)
        let target = focus
        let session = self.session
        // Read here rather than inside the Task: by the time transcription
        // returns the user may have switched headphones, and the row should say
        // which microphone actually heard this take.
        let micDevice = MicRecorder.currentInputName

        Task {
            let startedAt = Self.now()
            do {
                let raw = try await transcriber.transcribe(samples)
                // `.private` on the transcript, public on its shape: the log is
                // readable by anything that can run `log show`. See `Log`.
                Log.dictation.info(
                    "Transcribed in \(Self.now() - startedAt, privacy: .public)s: \(raw, privacy: .private)")

                // Silence does NOT come back empty. Measured: a take with no
                // speech transcribes as ".", which passes the service's
                // is-it-empty check and would be pasted into the user's
                // document.
                guard Self.hasSpeech(raw) else {
                    Log.dictation.notice("No alphanumeric content — treating as silence")
                    finish(session, with: .error(.silent), dwell: Self.errorDwell)
                    return
                }

                // Only the live dictation shows a polishing state; a late one
                // still polishes and delivers, it just does not touch the island.
                if session == self.session { setPhase(.polishing) }
                let text = await polisher.polish(raw, within: Self.polishDeadline)

                let outcome = await Paster.deliver(text, to: target)
                Log.deliver.info(
                    "Delivery: \(String(describing: outcome), privacy: .public) (target \(target?.bundleID ?? "none", privacy: .public))")

                // After delivery, so a row means the words reached the user.
                // `rawText` only when polish changed something — nil otherwise
                // answers "was this misheard, or tidied into something I did
                // not say?" without storing the same string twice.
                record(
                    CaptureDraft(
                        text: text,
                        rawText: text == raw ? nil : raw,
                        durationSeconds: duration,
                        language: WhisperKitService.language,
                        targetBundleID: outcome == .pasted ? target?.bundleID : nil,
                        targetAppName: outcome == .pasted ? target?.appName : nil,
                        micDevice: micDevice,
                        modelVariant: transcriber.modelVariant
                    ))
                finish(session,
                       with: outcome == .pasted ? .done : .copied,
                       dwell: outcome == .pasted ? Self.doneDwell : Self.errorDwell)
            } catch TranscriptionError.empty {
                Log.dictation.notice("Transcription empty")
                finish(session, with: .error(.silent), dwell: Self.errorDwell)
            } catch TranscriptionError.notReady {
                // The model takes ~12s to load at launch; a hotkey pressed in
                // that window lands here. The audio is gone, but nothing hangs
                // and the next dictation works.
                Log.dictation.notice("Model not ready yet — dictation dropped")
                finish(session, with: .error(.modelLoading), dwell: Self.errorDwell)
            } catch {
                Log.dictation.error(
                    "Transcription failed: \(String(describing: error), privacy: .public)")
                finish(session, with: .error(.transcriptionFailed), dwell: Self.errorDwell)
            }
        }
    }

    /// Applies a terminal phase, unless a newer dictation has already started.
    private func finish(_ session: Int, with phase: Phase, dwell: Duration) {
        guard session == self.session else {
            Log.dictation.notice(
                "Session \(session, privacy: .public) finished late (now \(self.session, privacy: .public)) — phase left alone")
            return
        }
        setPhase(phase)
        // Only success is sounded. A failed dictation is announced by the panel
        // dropping out of the notch instead.
        if phase == .done || phase == .copied { Cues.play(.done) }
        scheduleCollapse(after: dwell)
    }

    /// Files a delivered dictation into history, or complains and moves on.
    ///
    /// Deliberately not awaited by the caller and deliberately not throwing
    /// upward. The transcript is already in the user's document by this point;
    /// a store that will not write is a broken history, not a broken dictation,
    /// and blocking on it would make every take wait for a disk.
    private func record(_ draft: CaptureDraft) {
        Task { [store] in
            do {
                try await store.record(draft)
            } catch {
                Log.data.error(
                    "Capture not recorded: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Shows a failure immediately, outside the async pipeline.
    private func fail(with failure: DictationFailure) {
        setPhase(.error(failure))
        scheduleCollapse(after: Self.errorDwell)
    }

    /// Whisper punctuates silence rather than returning nothing, so emptiness
    /// is not a usable test. A transcript with no letter and no digit anywhere
    /// carries no words — `.`, `...`, `?!` — and must not reach the clipboard.
    /// `isLetter`/`isNumber` are Unicode-aware, so non-Latin scripts survive.
    private static func hasSpeech(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: - Timers

    private func armMaxDurationTimer() {
        maxDurationTimer?.cancel()
        maxDurationTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumDuration))
            guard !Task.isCancelled else { return }
            self?.dispatch(.maxDurationReached)
        }
    }

    private func cancelTimers() {
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
        inputTooQuiet = false
    }

    private func setPhase(_ next: Phase) {
        phase = next
        // The tap suppresses Escape only while something is actually running.
        // Taking it the rest of the time would break Escape everywhere on the
        // Mac for an app that is doing nothing.
        tap?.isDictating = next != .dormant
        onPhaseChange?(next)
    }
}
