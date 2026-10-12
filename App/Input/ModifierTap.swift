import AppKit
import IOKit.hid
import NotchVoiceCore
import Synchronization

/// The device-dependent flag bit CoreGraphics sets while this exact key is
/// physically held.
///
/// The public `CGEventFlags` constants are family-wide — `.maskAlternate` is
/// set for either Option key — but the raw flags also carry the per-side bits
/// declared in `<IOKit/hidsystem/IOLLEvent.h>`. Those are what let us tell
/// "right-⌥ released" from "right-⌥ released but left-⌥ still held".
private extension ModifierKey {
    /// Values taken from `IOLLEvent.h` in the current macOS SDK.
    var deviceFlagMask: UInt64 {
        switch self {
        case .fn:           0x0080_0000  // NX_SECONDARYFNMASK
        case .rightCommand: 0x0000_0010  // NX_DEVICERCMDKEYMASK
        case .rightShift:   0x0000_0004  // NX_DEVICERSHIFTKEYMASK
        case .rightOption:  0x0000_0040  // NX_DEVICERALTKEYMASK
        case .rightControl: 0x0000_2000  // NX_DEVICERCTLKEYMASK
        }
    }

    /// The family-wide flag, set while *either* side is held.
    ///
    /// Used where a false "released" would be costly: this bit being clear
    /// proves the key is up, which a per-side bit some source fails to report
    /// would not.
    var familyFlag: CGEventFlags {
        switch self {
        case .fn:           .maskSecondaryFn
        case .rightCommand: .maskCommand
        case .rightShift:   .maskShift
        case .rightOption:  .maskAlternate
        case .rightControl: .maskControl
        }
    }
}

/// Watches the global keyboard for the bound key, and takes the few events that
/// belong to this app.
///
/// **This tap consumes.** `.defaultTap`, so returning `nil` destroys the event
/// before any app sees it. That is what makes the fn binding possible: where the
/// Globe key is set to "Show Emoji & Symbols" (`AppleFnUsageType = 2`, common),
/// an observed-but-not-consumed fn opens the emoji picker on every dictation.
///
/// The cost, stated plainly: the callback runs inside the path of **every
/// keystroke on the machine**. It therefore runs on a thread of its own — see
/// `TapThread` — where nothing else on this app's main thread can stall it, and
/// everything in `TapState.handle` is branch-only: no I/O, no logging, nothing
/// that waits. Anything worth acting on is handed to the main actor after the
/// decision is made.
///
/// **Exactly four things are taken:**
///
/// 1. The binding key's own `flagsChanged`, only when the binding is `fn`. A
///    right-hand modifier passes through — swallowing ⌥ would break every
///    ⌥-composed character.
/// 2. `Space` while the binding is held — the hands-free chord. Without taking
///    it, locking a session also types a space.
/// 3. `Escape`, only while a dictation is in flight.
/// 4. `⌃⌘V` — Paste Last Transcript — only once there is a transcript to
///    paste. Before that the shortcut belongs to whichever app is in front.
///
/// Everything else returns untouched. `fn` in combination — `fn`+`Delete`,
/// `fn`+arrows — still reaches apps: those carry the fn flag in their own
/// `flags` field, and only the bare `flagsChanged` is swallowed.
///
/// **Keeping it alive.** macOS can switch a tap off — announced with an event,
/// or occasionally not — and a dead tap is a hotkey that silently does nothing
/// while fn opens the emoji picker again. A disable is re-armed on the spot, a
/// watchdog catches the unannounced kind, and a tap that keeps being disabled
/// is rebuilt. A key-up lost while any of that happened is repaired by asking
/// the hardware whether the key is really still down.
@MainActor
final class ModifierTap {

    /// How often to confirm macOS has not quietly switched the tap off.
    private static let watchdogInterval = Duration.seconds(2)

    /// How often to ask the hardware whether the binding is really still held,
    /// while the tap believes it is.
    private static let heldKeyCheckInterval = Duration.seconds(1)

    /// `let`, not `var`. A tap is built for one binding and thrown away when it
    /// changes — `DictationCoordinator.rebind(to:)` creates a fresh one rather
    /// than mutating this.
    private let binding: ModifierKey
    private let state: TapState
    private var port: CFMachPort?
    private var thread: TapThread?
    private var watchdog: Task<Void, Never>?
    private var heldKeyCheck: Task<Void, Never>?
    private var disables = TapDisableTracker()
    private var wakeObserver: (any NSObjectProtocol)?

    /// Whether a dictation is in flight, maintained by the coordinator.
    ///
    /// Escape is only taken while this is true. Swallowing it unconditionally
    /// would break Escape everywhere on the Mac — closing dialogs, leaving full
    /// screen, exiting insert mode in vim — for an app that is doing nothing at
    /// the time.
    var isDictating: Bool {
        get { state.isDictating }
        set { state.isDictating = newValue }
    }

    /// Whether there is a transcript to paste again, maintained by the
    /// coordinator. ⌃⌘V is only taken while this is true.
    var canPasteLast: Bool {
        get { state.canPasteLast }
        set { state.canPasteLast = newValue }
    }

    /// Key-down and key-up carry the moment the tap saw them. The events reach
    /// the main actor a hop later, and a busy main thread must not stretch or
    /// shrink a hold that the state machine measures.
    var onKeyDown: ((TimeInterval) -> Void)?
    var onKeyUp: ((TimeInterval) -> Void)?
    /// Space arrived while the binding was held — the hands-free chord.
    var onChord: (() -> Void)?
    var onOtherKey: (() -> Void)?
    var onEscape: (() -> Void)?
    var onPasteLast: (() -> Void)?

    init(binding: ModifierKey = BindingStore.binding) {
        self.binding = binding
        let relay = TapRelay()
        self.state = TapState(binding: binding) { event in
            // The main queue rather than a Task: it is FIFO, so a key-up can
            // never be handled ahead of the key-down it follows.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { relay.tap?.receive(event) }
            }
        }
        relay.tap = self
    }

    /// `isolated` because a nonisolated deinit cannot touch the CF handles at
    /// all — `CFMachPort` is not Sendable, so Swift 6 rejects reading it there.
    /// Teardown therefore runs on the MainActor, possibly slightly after the
    /// last reference drops.
    isolated deinit {
        stop()
    }

    /// Returns false when the tap cannot deliver events.
    ///
    /// A consuming tap needs **Accessibility**, where the old observe-only one
    /// needed Input Monitoring. Both are checked: `CGEvent.tapCreate` can return
    /// a valid port that never receives anything, so a non-nil port is not proof
    /// of anything on its own.
    func start() -> Bool {
        guard port == nil else { return true }
        guard installTap() else { return false }

        // Checked only after creating the tap, deliberately: attempting one is
        // what gets the app listed under Privacy & Security, so the user has a
        // switch to turn on. Then tear it back down rather than leaving a port
        // that can never deliver anything.
        guard AXIsProcessTrusted() else {
            Log.input.error("Accessibility not granted — a consuming tap cannot run")
            stop()
            return false
        }

        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        guard access == kIOHIDAccessTypeGranted else {
            Log.input.error(
                "Input Monitoring not granted (IOHIDCheckAccess=\(access.rawValue, privacy: .public))")
            stop()
            return false
        }

        startWatchdog()
        observeWake()
        return true
    }

    func stop() {
        removeTap()
        watchdog?.cancel()
        watchdog = nil
        heldKeyCheck?.cancel()
        heldKeyCheck = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        state.reset()
    }

    // MARK: - The tap itself

    /// Creates the port and the thread that runs it.
    ///
    /// Separate from `start()` because a tap that keeps being disabled is
    /// rebuilt with this, and `state` — whether the key is held, whether a
    /// dictation is running — carries across the swap untouched.
    private func installTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // <- consuming; nil return destroys
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let state = Unmanaged<TapState>.fromOpaque(refcon).takeUnretainedValue()
                return state.handle(type: type, event: event)
                    ? nil : Unmanaged.passUnretained(event)
            },
            // Unretained: `TapThread` holds `state` for as long as the run
            // loop that calls back with it is running.
            userInfo: Unmanaged.passUnretained(state).toOpaque()
        ) else {
            return false
        }

        state.setPort(port)
        let thread = TapThread(port: port, state: state)
        thread.run()
        CGEvent.tapEnable(tap: port, enable: true)

        self.port = port
        self.thread = thread
        return true
    }

    private func removeTap() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            // Without this the Mach port stays live for the process lifetime,
            // leaking once per rebind or rebuild. It also removes the port's
            // source, which is what ends the thread's run loop.
            CFMachPortInvalidate(port)
        }
        thread?.finish()
        state.setPort(nil)
        port = nil
        thread = nil
    }

    private func receive(_ event: TapEvent) {
        // A stopped tap can still have events queued behind it — a rebind
        // throws one away mid-keystroke. Nothing it reports matters any more.
        guard port != nil else { return }

        switch event {
        case let .keyDown(at):
            watchHeldKey()
            onKeyDown?(at)
        case let .keyUp(at):
            heldKeyCheck?.cancel()
            onKeyUp?(at)
        case .chord:
            onChord?()
        case .otherKey:
            onOtherKey?()
        case .escape:
            onEscape?()
        case .pasteLast:
            onPasteLast?()
        case .disabled:
            // Already re-armed on the tap thread; this is only the count.
            Log.input.error("Tap was disabled by macOS — re-armed")
            noteDisable()
        }
    }

    // MARK: - Health

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogInterval)
                guard let self, !Task.isCancelled else { return }
                reenableIfDisabled()
            }
        }
    }

    /// Re-enables a tap that macOS switched off without sending the event that
    /// normally says so.
    private func reenableIfDisabled() {
        guard let port, !CGEvent.tapIsEnabled(tap: port) else { return }
        Log.input.error("Tap found disabled — re-enabling")
        CGEvent.tapEnable(tap: port, enable: true)
        noteDisable()
    }

    private func noteDisable() {
        guard disables.noteDisable(at: ProcessInfo.processInfo.systemUptime) else { return }
        Log.input.error("Tap keeps being disabled — rebuilding it")
        removeTap()
        if !installTap() {
            Log.input.error("Tap rebuild FAILED — the hotkey is dead until it is re-armed")
        }
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    /// Checks the tap straight away rather than up to a watchdog interval
    /// later, and stops counting the disables a waking machine tends to cause.
    private func didWake() {
        disables.noteWake(at: ProcessInfo.processInfo.systemUptime)
        reenableIfDisabled()
    }

    /// Repairs a key-up the tap never saw.
    ///
    /// The tap knows the key's state only from events, so a release that
    /// happens while it is disabled or being rebuilt is simply missed — and the
    /// hold then runs on to the 300s cap. While the key is believed held, this
    /// asks the hardware instead.
    ///
    /// Cautious on purpose, because cutting a real hold short loses the user's
    /// words: it reads the family flag, whose absence proves the key is up, and
    /// acts only on two such readings in a row.
    private func watchHeldKey() {
        heldKeyCheck?.cancel()
        heldKeyCheck = Task { [weak self] in
            var releasedReadings = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heldKeyCheckInterval)
                guard let self, !Task.isCancelled else { return }
                let flags = CGEventSource.flagsState(.hidSystemState)
                releasedReadings = flags.contains(binding.familyFlag) ? 0 : releasedReadings + 1
                guard releasedReadings >= 2 else { continue }
                if let at = state.forceRelease() {
                    Log.input.notice(
                        "\(self.binding.displayName, privacy: .public) is up but its release never arrived — releasing")
                    onKeyUp?(at)
                }
                return
            }
        }
    }
}

// MARK: - Tap thread

/// What the tap thread hands to the main actor.
private enum TapEvent: Sendable {
    case keyDown(TimeInterval)
    case keyUp(TimeInterval)
    case chord
    case otherKey
    case escape
    case pasteLast
    case disabled
}

/// Lets events from the tap thread find the tap without that thread keeping it
/// alive.
@MainActor
private final class TapRelay {
    weak var tap: ModifierTap?
}

/// `CFMachPort` is not Sendable, so it cannot sit behind the lock as itself.
/// The port is safe to use from any thread — enabling and invalidating it are
/// Mach calls.
private final class PortRef: @unchecked Sendable {
    let port: CFMachPort
    init(_ port: CFMachPort) { self.port = port }
}

/// The half of the tap that runs on the tap thread, inside the path of every
/// keystroke on the Mac.
///
/// One lock, because two threads touch this state: the tap thread on every
/// keystroke, and the main actor when it sets `isDictating` or repairs a lost
/// key-up. Uncontended in practice. Anything worth reporting is handed off
/// after the lock is released.
private final class TapState: Sendable {

    private static let escapeKeyCode: Int64 = 53
    private static let spaceKeyCode: Int64 = 49

    /// The modifiers that decide whether V is the paste-last chord: ⌃ and ⌘
    /// down, ⌥ and ⇧ up — so ⌥⌃⌘V and friends still reach apps.
    private static let pasteLastMask = CGEventFlags([
        .maskControl, .maskCommand, .maskAlternate, .maskShift,
    ]).rawValue
    private static let pasteLastFlags = CGEventFlags([.maskControl, .maskCommand]).rawValue

    private struct Fields {
        var port: PortRef?
        var isBindingKeyDown = false
        /// Set while a Space key-down has been swallowed, so its matching
        /// key-up can be swallowed too. An orphaned key-up is not fatal, but
        /// some text engines track key state and a stray release is the kind of
        /// thing that surfaces as a bug in one app a year from now.
        var swallowedChord = false
        /// Same idea for Escape, and load-bearing for a different reason:
        /// cancelling clears `isDictating` before the key-up arrives, so by
        /// then the condition that justified swallowing the key-down is
        /// already false.
        var swallowedEscape = false
        /// Same pairing for the paste-last chord's V.
        var swallowedPasteLast = false
        var isDictating = false
        var canPasteLast = false
    }

    let binding: ModifierKey
    private let fields = Mutex(Fields())
    private let emit: @Sendable (TapEvent) -> Void

    init(binding: ModifierKey, emit: @escaping @Sendable (TapEvent) -> Void) {
        self.binding = binding
        self.emit = emit
    }

    var isDictating: Bool {
        get { fields.withLock { $0.isDictating } }
        set { fields.withLock { $0.isDictating = newValue } }
    }

    var canPasteLast: Bool {
        get { fields.withLock { $0.canPasteLast } }
        set { fields.withLock { $0.canPasteLast = newValue } }
    }

    func setPort(_ port: CFMachPort?) {
        let ref = port.map(PortRef.init)
        fields.withLock { $0.port = ref }
    }

    func reset() {
        fields.withLock { $0 = Fields() }
    }

    /// Marks the binding released if it was believed held, and says when.
    ///
    /// Exactly one key-up gets reported — this one or the tap's own, whichever
    /// takes the lock first.
    func forceRelease() -> TimeInterval? {
        fields.withLock { fields in
            guard fields.isBindingKeyDown else { return nil }
            fields.isBindingKeyDown = false
            return ProcessInfo.processInfo.systemUptime
        }
    }

    /// Returns whether to destroy the event.
    ///
    /// Every path returns `false` unless the event is one of the four this app
    /// owns. Read the `return true`s as the complete list of what this app takes
    /// from the rest of the system.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables a tap that takes too long in its callback, and can on
        // user input. Re-armed here and now rather than via the main actor: a
        // disabled tap also stops suppressing fn, so the emoji picker would be
        // back for as long as the main thread took to get round to it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let ref = fields.withLock({ $0.port }) {
                CGEvent.tapEnable(tap: ref.port, enable: true)
            }
            emit(.disabled)
            return false
        }

        // Our own ⌘V passes through untouched. Otherwise the paste-last
        // chord's pairing swallows its key-up while the user still holds V,
        // and a binding believed held would count it as another key.
        if event.getIntegerValueField(.eventSourceUserData) == Paster.syntheticEventMarker {
            return false
        }

        // Kept as Int64 deliberately. This runs on every keystroke in every
        // app, and `UInt16(someInt64)` traps on an out-of-range value; a
        // malformed or synthetic event must not be able to kill the process
        // from inside the system input path.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        let bindingCode = Int64(binding.rawValue)
        let binding = binding
        let pasteKeyCode = Int64(PasteKey.cached)
        // Held down, a chord auto-repeats. One paste per press.
        let isRepeat = type == .keyDown
            && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        var report: TapEvent?

        let swallow = fields.withLock { fields -> Bool in
            switch type {
            case .flagsChanged:
                // Derived from the event's own flags, never from a toggle.
                // flagsChanged carries no up/down bit, but it does report the
                // full modifier state *after* the change, so reading the bit is
                // both exact and self-correcting: any event we miss (tap
                // disabled and re-armed, key already held at launch) is repaired
                // by the next flagsChanged instead of inverting down/up for the
                // rest of the session.
                let isDown = (flags & binding.deviceFlagMask) != 0

                if isDown != fields.isBindingKeyDown {
                    fields.isBindingKeyDown = isDown
                    let at = ProcessInfo.processInfo.systemUptime
                    report = isDown ? .keyDown(at) : .keyUp(at)
                } else if fields.isBindingKeyDown, keyCode != bindingCode {
                    // Our key is still held and a different modifier moved.
                    // Only counts as interference while our key is actually
                    // held.
                    report = .otherKey
                }

                // Taken only for fn. A right-hand modifier has to reach apps —
                // it is half of every shortcut and every composed character the
                // user types with it.
                return binding.needsFnKey && keyCode == bindingCode

            case .keyDown:
                if keyCode == Self.escapeKeyCode {
                    guard fields.isDictating else { return false }
                    fields.swallowedEscape = true
                    report = .escape
                    return true
                }
                if fields.isBindingKeyDown, keyCode == Self.spaceKeyCode {
                    fields.swallowedChord = true
                    report = .chord
                    return true
                }
                if fields.canPasteLast, keyCode == pasteKeyCode,
                   flags & Self.pasteLastMask == Self.pasteLastFlags {
                    fields.swallowedPasteLast = true
                    if !isRepeat { report = .pasteLast }
                    return true
                }
                if fields.isBindingKeyDown { report = .otherKey }
                return false

            case .keyUp:
                // Paired with the key-downs above so no app sees a release
                // without its press. Nothing else is inspected here.
                if keyCode == Self.spaceKeyCode, fields.swallowedChord {
                    fields.swallowedChord = false
                    return true
                }
                if keyCode == Self.escapeKeyCode, fields.swallowedEscape {
                    fields.swallowedEscape = false
                    return true
                }
                // By key alone: ⌃ and ⌘ are often let go before V.
                if keyCode == pasteKeyCode, fields.swallowedPasteLast {
                    fields.swallowedPasteLast = false
                    return true
                }
                return false

            default:
                return false
            }
        }

        if let report { emit(report) }
        return swallow
    }
}

/// Runs the tap's run loop on a thread of its own.
///
/// On the main run loop, any stall on the main thread — a slow view update, a
/// busy store, a synchronous call into another app — sat in the path of every
/// keystroke on the Mac, and a long enough one made macOS disable the tap.
/// This thread does nothing else.
private final class TapThread: Thread, @unchecked Sendable {

    private let source: CFRunLoopSource
    /// Held so the callback's unretained `refcon` stays valid until this run
    /// loop has stopped, which can be after the tap that made it is gone.
    private let state: TapState
    private let started = DispatchSemaphore(value: 0)
    /// Written once in `main()` before `started` is signalled, read only after
    /// `run()` has waited on it.
    private var runLoop: CFRunLoop?

    init(port: CFMachPort, state: TapState) {
        self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.state = state
        super.init()
        name = "Notch Voice event tap"
        qualityOfService = .userInteractive
    }

    override func main() {
        let runLoop = CFRunLoopGetCurrent()
        self.runLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        started.signal()
        CFRunLoopRun()
    }

    /// Starts the thread and returns once its run loop holds the tap's source,
    /// so the tap is never enabled with nothing to call back on.
    func run() {
        start()
        started.wait()
    }

    func finish() {
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}
