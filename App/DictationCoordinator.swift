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
        /// whichever backend is running — see `PolishService`. Flashes past with
        /// Apple's model and sits there for seconds with the downloaded one,
        /// which is the honest depiction of the difference.
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
    /// `var` because changing the speech model means a new pipeline. The
    /// variant is `let` on the service so nothing can swap it underneath a
    /// decode already in flight.
    @ObservationIgnored private var transcriber = WhisperKitService()
    @ObservationIgnored private let polisher = PolishService()
    @ObservationIgnored private let store: CaptureStore
    @ObservationIgnored private var tap: ModifierTap?

    @ObservationIgnored private var buffer: LevelBuffer
    @ObservationIgnored private var focus: FocusSnapshot?
    /// Text that was in the target field when the key went down. Never stored,
    /// never sent anywhere — see `AXContextReader`. Filled in shortly after
    /// key-down, by a read that runs off the main thread.
    @ObservationIgnored private var screenContext: String?
    @ObservationIgnored private var maxDurationTimer: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?

    /// Mirrors `WhisperKitService.isReady`, which is actor-isolated and so
    /// cannot be read from a synchronous path like `armTap()`.
    @ObservationIgnored private var modelLoaded = false
    /// The model load that is currently allowed to update readiness. A model
    /// change cancels the old task and advances this generation so late
    /// callbacks cannot turn the new model green prematurely.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0

    /// True from the end of recording until delivery (or a processing error).
    /// The event tap uses this as a hard one-at-a-time gate.
    @ObservationIgnored private var isProcessing = false

    /// Bumped on every capture. The processing gate normally prevents a second
    /// capture, but keeping a session token also protects the UI if a late task
    /// completes after cancellation or a future gesture change.
    @ObservationIgnored private var session = 0

    /// The most recent delivered transcript, for Paste Last Transcript.
    ///
    /// Memory only: history is where transcripts are kept, and this is gone at
    /// quit. The tap takes ⌃⌘V only while there is something here to paste.
    @ObservationIgnored private var lastTranscript: String? {
        didSet { tap?.canPasteLast = lastTranscript != nil }
    }

    /// Read by the menu each time it opens, so it needs no observation.
    var canPasteLast: Bool { lastTranscript != nil }

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
        PasteKey.observeLayoutChanges()

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
        // Timestamps come from the tap, which saw the key move a hop before
        // this runs.
        tap.onKeyDown = { [weak self] at in
            guard let self else { return }
            onBindingKeyDown?()
            if isProcessing {
                showBusy()
                return
            }
            dispatch(.keyDown(at: at))
        }
        tap.onKeyUp = { [weak self] at in self?.dispatch(.keyUp(at: at)) }
        tap.onChord = { [weak self] in self?.dispatchIfActive(.chordPressed) }
        // Both of these fire far beyond our own gesture. Dropping them when idle
        // keeps the log readable; the machine ignores them there anyway.
        tap.onOtherKey = { [weak self] in self?.dispatchIfActive(.otherKeyPressed) }
        tap.onEscape = { [weak self] in self?.dispatchIfActive(.escapePressed) }
        tap.onPasteLast = { [weak self] in self?.pasteLast() }
        tap.onAvailabilityChange = { [weak self] in self?.tapAvailabilityChanged($0) }
        tap.canPasteLast = lastTranscript != nil

        guard tap.start() else {
            Log.input.error("Tap did NOT arm — Accessibility or Input Monitoring is missing")
            Log.input.error(
                "Signed as: \(PermissionChecker.signingRequirement(), privacy: .public)")
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

    /// The tap was lost and could not be rebuilt, or a retry brought it back.
    ///
    /// Shown the way a tap that never armed is — `.needsPermission` turns the
    /// menu bar glyph to ⚠️ — because the likeliest cause is the same: a
    /// permission revoked or reset while the app was running.
    private func tapAvailabilityChanged(_ available: Bool) {
        if available {
            Log.input.notice("Tap is back")
            if readiness == .needsPermission {
                readiness = modelLoaded ? .ready : .loadingModel
            }
            return
        }
        readiness = .needsPermission
        // Nothing can deliver the key-up or the stopping tap now. Finish what
        // was said rather than leave it recording to the cap.
        if machine.state != .idle { dispatch(.maxDurationReached) }
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

    /// How far along getting the speech model is. Drives the onboarding
    /// progress bar; the island only cares whether it is `.ready`.
    private(set) var modelPhase: ModelPhase = .loading

    /// Loads the speech model. No-ops if it is already resident.
    func loadModel() {
        guard loadTask == nil else { return }
        let generation = loadGeneration
        let service = transcriber
        loadTask = Task { [weak self] in
            defer {
                if let self, self.loadGeneration == generation {
                    self.loadTask = nil
                }
            }
            let startedAt = Self.now()
            Log.dictation.info("Loading model… (~12s; dictation is unavailable until ready)")
            do {
                try await service.prepare { [weak self] phase in
                    Task { @MainActor in
                        guard let self, self.loadGeneration == generation else { return }
                        self.modelPhase = phase
                    }
                }
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                Log.dictation.info("Model ready in \(Self.now() - startedAt, privacy: .public)s")
                modelLoaded = true
                if readiness != .needsPermission { readiness = .ready }
            } catch {
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                Log.dictation.error(
                    "Model FAILED to load: \(error.localizedDescription, privacy: .public)")
                readiness = .modelUnavailable(error.localizedDescription)
            }
        }
    }

    /// Switches speech model and loads the new one.
    ///
    /// The old service is dropped rather than reconfigured, so a decode already
    /// running finishes against the pipeline it started with. Dictation is
    /// unavailable until the new model is ready, which is why `readiness` goes
    /// back to `.loadingModel` rather than staying green through a swap that
    /// takes a download.
    func changeModel(to model: SpeechModel) {
        guard model != ModelPreference.current else { return }
        ModelPreference.current = model
        Log.dictation.info("Switching to \(model.title, privacy: .public)")

        loadTask?.cancel()
        loadTask = nil
        loadGeneration &+= 1
        transcriber = WhisperKitService(model: model)
        modelLoaded = false
        modelPhase = .loading
        if readiness != .needsPermission { readiness = .loadingModel }
        loadModel()
    }

    /// Whether Apple's cleanup model can run. Surfaced in Settings.
    nonisolated var polishAvailability: PolishAvailability {
        polisher.availability
    }

    /// Re-picks the cleanup backend and warms it.
    ///
    /// Called when the local-model switch is flipped. Without it the choice
    /// would take effect on the next dictation, which is also when the user
    /// would first discover the several seconds it takes to read 2.3GB off disk.
    func prepareCleanup() {
        Task { await polisher.prepare() }
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
        screenContext = nil
        resetWaveform()

        armMaxDurationTimer()

        // The microphone comes first. Anything ahead of it on this path — the
        // screen read below used to be — is speech clipped off the front of the
        // take, because people start talking the moment the key goes down.
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

        readFocusedField(for: session)
    }

    /// Finds the field being dictated into — and its text, if reading it is
    /// allowed — off the main thread.
    ///
    /// Still at key-down, because by the time transcription finishes the user
    /// has often clicked elsewhere — the field being dictated into is only
    /// knowable now. After the island is shown is fine: it never becomes key,
    /// so it cannot take focus from that field.
    ///
    /// Bounded by `AXContextReader`'s budget, which is shorter than the hold
    /// threshold, so the result is normally in hand by key-up. If a wedged app
    /// makes it later than that, the take is transcribed unbiased and pasted
    /// wherever the app's focus is by then.
    private func readFocusedField(for session: Int) {
        let includingText = ContextPreference.isEnabled
        Task {
            let field = await Task.detached(priority: .userInitiated) {
                AXContextReader.read(includingText: includingText)
            }.value
            guard session == self.session else { return }
            screenContext = field?.text
            // The keyboard can belong to another process than the frontmost
            // app — a panel that takes keys without activating, as Spotlight
            // does. That field is not where the paste is going, and raising
            // it at delivery would be wrong.
            if let field, field.element.pid == focus?.pid {
                focus?.element = field.element
                focus?.selection = field.selection
            }
        }
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

        isProcessing = true
        setPhase(.transcribing)
        // After the minimum-duration guard, so a too-short take stays silent.
        // Decoding runs for a second or two and the loop needs a sound in it.
        Cues.play(.stop)
        let target = focus
        let session = self.session
        // A model or language change while this task is suspended must apply to
        // the next dictation only. Capture these values before the first await.
        let transcriber = self.transcriber
        let language = LanguagePreference.current.code ?? "auto"
        let modelVariant = transcriber.modelVariant
        // Read here rather than inside the Task: by the time transcription
        // returns the user may have switched headphones, and the row should say
        // which microphone actually heard this take.
        let micDevice = MicRecorder.currentInputName
        let context = screenContext

        Task {
            let startedAt = Self.now()
            do {
                // Built inside the Task so a slow store read cannot delay the
                // island appearing. Failing to read it is not an error — the
                // dictation just goes ahead unbiased.
                let prompt = await biasPrompt(context: context)
                let raw = try await transcriber.transcribe(
                    samples, prompt: prompt, language: language == "auto" ? nil : language)
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

                // Corrections run **before** polish. Polish is told to preserve
                // the user's wording; handing it a transcript that still says
                // "cuber netties" means it tidies around the error.
                let corrected = await rewrite(raw, .corrections)

                // Only the live dictation shows a polishing state; a late one
                // still polishes and delivers, it just does not touch the island.
                if session == self.session { setPhase(.polishing) }
                let polished = await polisher.polish(corrected)

                // Snippets run **after** it. An expansion is text the user
                // wrote out in advance — an address, a sign-off, a link — and
                // polish would reword or reformat it like speech.
                let text = await rewrite(polished, .snippets)

                let outcome = await Paster.deliver(text, to: target)
                Log.deliver.info(
                    "Delivery: \(String(describing: outcome), privacy: .public) (target \(target?.bundleID ?? "none", privacy: .public))")
                lastTranscript = text

                // After delivery, so a row means the words reached the user.
                // `rawText` only when polish changed something — nil otherwise
                // answers "was this misheard, or tidied into something I did
                // not say?" without storing the same string twice.
                record(
                    CaptureDraft(
                        text: text,
                        rawText: text == raw ? nil : raw,
                        durationSeconds: duration,
                        language: language,
                        targetBundleID: outcome == .pasted ? target?.bundleID : nil,
                        targetAppName: outcome == .pasted ? target?.appName : nil,
                        micDevice: micDevice,
                        modelVariant: modelVariant
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

    /// Pastes the most recent transcript again, into whatever has focus now.
    ///
    /// For recovering from a paste that went somewhere unexpected, or only
    /// reached the clipboard. Ignored while a dictation is recording or
    /// processing: that one owns the clipboard and the keyboard until it is
    /// delivered.
    func pasteLast() {
        guard let text = lastTranscript, machine.state == .idle, !isProcessing else { return }
        let session = self.session
        let target = FocusSnapshot.capture()

        Task {
            let outcome = await Paster.deliver(text, to: target)
            Log.deliver.info(
                "Paste last: \(String(describing: outcome), privacy: .public) (target \(target?.bundleID ?? "none", privacy: .public))")

            // A paste that landed is its own feedback; a miss needs saying. A
            // dictation started meanwhile owns the island.
            guard session == self.session, machine.state == .idle else { return }
            switch outcome {
            case .copiedOnly:
                setPhase(.copied)
                scheduleCollapse(after: Self.errorDwell)
            case .pasted where phase == .copied:
                // The panel still says "press ⌘V", which is now wrong.
                setPhase(.done)
                scheduleCollapse(after: Self.doneDwell)
            case .pasted:
                break
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
        isProcessing = false
        setPhase(phase)
        // Only success is sounded. A failed dictation is announced by the panel
        // dropping out of the notch instead.
        if phase == .done || phase == .copied { Cues.play(.done) }
        scheduleCollapse(after: dwell)
    }

    /// Custom words plus whatever was on screen, as one prompt for the decoder.
    ///
    /// Never throws upward: an unreadable store means an unbiased dictation,
    /// which is exactly what the app did before this existed.
    private func biasPrompt(context: String?) async -> String? {
        let terms: [String]
        do {
            terms = try await store.biasTerms()
        } catch {
            Log.data.error(
                "Bias terms unavailable: \(error.localizedDescription, privacy: .public)")
            terms = []
        }
        return BiasPrompt.build(terms: terms, context: context)
    }

    /// Applies dictionary corrections or snippet expansions.
    ///
    /// Counting which rules fired is deliberately not awaited — a statistic must
    /// never be on the path between the user's words and their document.
    private func rewrite(_ text: String, _ kind: RewriteKind) async -> String {
        do {
            let rules = try await store.rewriteRules(kind)
            guard !rules.isEmpty else { return text }

            let result = TranscriptRewriter.apply(rules, to: text)
            if result.didChange {
                Log.dictation.info(
                    "Rewrote \(result.applied.count, privacy: .public) phrase(s)")
                Task { [store] in try? await store.noteRewrites(result.applied) }
            }
            return result.text
        } catch {
            Log.data.error(
                "Rewrite rules unavailable: \(error.localizedDescription, privacy: .public)")
            return text
        }
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

    /// Gives feedback for a key press that arrived while the previous result
    /// was still being decoded or delivered.
    private func showBusy() {
        setPhase(.error(.stillProcessing))
        scheduleCollapse(after: .seconds(1.4))
    }
}
