import AppKit
import IOKit.hid
import NotchVoiceCore

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
}

/// Watches the global keyboard for the bound key, and takes the few events that
/// belong to this app.
///
/// **This tap consumes.** `.defaultTap`, so returning `nil` destroys the event
/// before any app sees it. That is what makes the fn binding possible: where the
/// Globe key is set to "Show Emoji & Symbols" (`AppleFnUsageType = 2`, common),
/// an observed-but-not-consumed fn opens the emoji picker on every dictation.
///
/// The cost, stated plainly: this callback runs inside the path of **every
/// keystroke on the machine**. If it blocks, typing stops everywhere until macOS
/// disables the tap — which the re-arm below recovers from. Everything in
/// `handle` is therefore branch-only: no allocation, no I/O, no logging.
///
/// **Exactly three things are taken:**
///
/// 1. The binding key's own `flagsChanged`, only when the binding is `fn`. A
///    right-hand modifier passes through — swallowing ⌥ would break every
///    ⌥-composed character.
/// 2. `Space` while the binding is held — the hands-free chord. Without taking
///    it, locking a session also types a space.
/// 3. `Escape`, only while a dictation is in flight.
///
/// Everything else returns untouched. `fn` in combination — `fn`+`Delete`,
/// `fn`+arrows — still reaches apps: those carry the fn flag in their own
/// `flags` field, and only the bare `flagsChanged` is swallowed.
@MainActor
final class ModifierTap {

    private static let escapeKeyCode: Int64 = 53
    private static let spaceKeyCode: Int64 = 49

    /// `let`, not `var`. A tap is built for one binding and thrown away when it
    /// changes — `DictationCoordinator.rebind(to:)` creates a fresh one rather
    /// than mutating this.
    private let binding: ModifierKey
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isBindingKeyDown = false

    /// Set while a Space key-down has been swallowed, so its matching key-up can
    /// be swallowed too. An orphaned key-up is not fatal, but some text engines
    /// track key state and a stray release is the kind of thing that surfaces as
    /// a bug in one app a year from now.
    private var swallowedChord = false

    /// Same idea for Escape, and load-bearing for a different reason: cancelling
    /// clears `isDictating` synchronously, so by the time the key-up arrives the
    /// condition that justified swallowing the key-down is already false.
    private var swallowedEscape = false

    /// Whether a dictation is in flight, maintained by the coordinator.
    ///
    /// Escape is only taken while this is true. Swallowing it unconditionally
    /// would break Escape everywhere on the Mac — closing dialogs, leaving full
    /// screen, exiting insert mode in vim — for an app that is doing nothing at
    /// the time.
    var isDictating = false

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    /// Space arrived while the binding was held — the hands-free chord.
    var onChord: (() -> Void)?
    var onOtherKey: (() -> Void)?
    var onEscape: (() -> Void)?

    init(binding: ModifierKey = BindingStore.binding) {
        self.binding = binding
    }

    /// `isolated` because a nonisolated deinit cannot touch the CF handles at
    /// all — `CFMachPort`/`CFRunLoopSource` are not Sendable, so Swift 6
    /// rejects reading them there. Teardown therefore runs on the MainActor,
    /// possibly slightly after the last reference drops.
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
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // <- consuming; nil return destroys
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<ModifierTap>.fromOpaque(refcon)
                    .takeUnretainedValue()
                // The run loop source lives on the main run loop, so this
                // callback always arrives on the main thread.
                let swallow = MainActor.assumeIsolated {
                    tap.handle(type: type, event: event)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        runLoopSource = source

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

        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Without this the Mach port stays live for the process lifetime,
            // leaking once per stop()/start() cycle (binding changes).
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
        isBindingKeyDown = false
        swallowedChord = false
        swallowedEscape = false
        isDictating = false
    }

    /// Returns whether to destroy the event.
    ///
    /// Every path returns `false` unless the event is one of the three this app
    /// owns. Read the `return true`s as the complete list of what this app takes
    /// from the rest of the system.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables a tap that takes too long in its callback. Re-arm
        // rather than silently dying — the user would just see the hotkey stop
        // working with no explanation. More important now than it was when this
        // tap only observed: a disabled tap here also stops suppressing fn, so
        // the emoji picker would come back.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.input.error("Tap disabled (type \(type.rawValue, privacy: .public)) — re-arming")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        // Kept as Int64 deliberately. This runs on every keystroke in every
        // app, and `UInt16(someInt64)` traps on an out-of-range value; a
        // malformed or synthetic event must not be able to kill the process
        // from inside the system input path.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let bindingCode = Int64(binding.rawValue)

        switch type {
        case .flagsChanged:
            // Derived from the event's own flags, never from a toggle.
            // flagsChanged carries no up/down bit, but it does report the full
            // modifier state *after* the change, so reading the bit is both
            // exact and self-correcting: any event we miss (tap disabled and
            // re-armed, key already held at launch) is repaired by the next
            // flagsChanged instead of inverting down/up for the rest of the
            // session.
            let isDown = (event.flags.rawValue & binding.deviceFlagMask) != 0

            if isDown != isBindingKeyDown {
                isBindingKeyDown = isDown
                if isDown { onKeyDown?() } else { onKeyUp?() }
            } else if isBindingKeyDown, keyCode != bindingCode {
                // Our key is still held and a different modifier moved. Only
                // counts as interference while our key is actually held.
                onOtherKey?()
            }

            // Taken only for fn. A right-hand modifier has to reach apps — it
            // is half of every shortcut and every composed character the user
            // types with it.
            return binding.needsFnKey && keyCode == bindingCode

        case .keyDown:
            if keyCode == Self.escapeKeyCode {
                guard isDictating else { return false }
                onEscape?()
                swallowedEscape = true
                return true
            }
            if isBindingKeyDown, keyCode == Self.spaceKeyCode {
                onChord?()
                swallowedChord = true
                return true
            }
            if isBindingKeyDown { onOtherKey?() }
            return false

        case .keyUp:
            // Paired with the key-downs above so no app sees a release without
            // its press. Nothing else is inspected here.
            if keyCode == Self.spaceKeyCode, swallowedChord {
                swallowedChord = false
                return true
            }
            if keyCode == Self.escapeKeyCode, swallowedEscape {
                swallowedEscape = false
                return true
            }
            return false

        default:
            return false
        }
    }
}
