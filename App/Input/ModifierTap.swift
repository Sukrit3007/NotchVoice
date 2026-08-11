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
        case .rightCommand: 0x0000_0010  // NX_DEVICERCMDKEYMASK
        case .rightShift:   0x0000_0004  // NX_DEVICERSHIFTKEYMASK
        case .rightOption:  0x0000_0040  // NX_DEVICERALTKEYMASK
        case .rightControl: 0x0000_2000  // NX_DEVICERCTLKEYMASK
        }
    }
}

/// Watches the global keyboard for the bound modifier.
///
/// **Observe-only.** The tap is created with `.listenOnly`, which means the
/// system ignores the callback's return value outright — this tap *cannot*
/// swallow, delay, or rewrite an event even if the callback were wrong. The
/// callback still returns every event unmodified on every path, so that the
/// guarantee does not rest on one initialiser argument alone.
///
/// That is also why the binding is restricted to modifiers: holding a bare
/// modifier does nothing in any app, so letting it through is harmless.
/// Binding to a normal key would require a consuming tap and put this code in
/// the path of every keystroke the user types.
///
/// Modifiers do not produce keyDown/keyUp events; they produce `.flagsChanged`
/// with the raw keycode identifying *which* modifier, including whether it is
/// the left or right one. That is why the binding is stored as a keycode
/// rather than an `NSEvent.ModifierFlags`.
@MainActor
final class ModifierTap {

    private var binding: ModifierKey
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isBindingKeyDown = false

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
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

    func updateBinding(_ key: ModifierKey) {
        binding = key
        isBindingKeyDown = false
    }

    /// Returns false when Input Monitoring has not been granted.
    ///
    /// Creating the tap is *not* how you find out, despite the usual advice. A
    /// `.listenOnly` tap is created successfully whether or not the permission
    /// exists — it simply never receives an event. Measured on this machine:
    /// `CGEvent.tapCreate` returned a valid port in a process where
    /// `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` reported `.denied`.
    /// Trusting the non-nil port would report success and then sit there dead,
    /// which is the failure this whole class is meant to avoid.
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // <- observe-only, cannot swallow
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<ModifierTap>.fromOpaque(refcon)
                    .takeUnretainedValue()
                // The run loop source lives on the main run loop, so this
                // callback always arrives on the main thread.
                MainActor.assumeIsolated {
                    tap.handle(type: type, event: event)
                }
                // Always hand the event straight back, untouched.
                return Unmanaged.passUnretained(event)
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

        // Checked only after creating the tap, deliberately: attempting a tap
        // is what gets the app listed under Privacy & Security > Input
        // Monitoring, so the user has a switch to turn on. Then tear it back
        // down rather than leaving a port that can never deliver anything.
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        guard access == kIOHIDAccessTypeGranted else {
            NSLog("[NotchVoice] Input Monitoring not granted (IOHIDCheckAccess=%d)",
                  Int(access.rawValue))
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
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables a tap that takes too long in its callback. Re-arm
        // rather than silently dying — the user would just see the hotkey
        // stop working with no explanation.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("[NotchVoice] modifier tap disabled (type %d) — re-arming",
                  Int(type.rawValue))
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
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
            // re-armed, key already held at launch, key released while the
            // tap was off) is repaired by the next flagsChanged instead of
            // inverting down/up for the rest of the session.
            let isDown = (event.flags.rawValue & binding.deviceFlagMask) != 0

            #if DEBUG
            if keyCode == bindingCode {
                NSLog("[NotchVoice] binding flagsChanged flags=0x%llx mask=0x%llx -> %@",
                      event.flags.rawValue, binding.deviceFlagMask,
                      isDown ? "down" : "up")
            }
            #endif

            if isDown != isBindingKeyDown {
                isBindingKeyDown = isDown
                if isDown { onKeyDown?() } else { onKeyUp?() }
            } else if isBindingKeyDown, keyCode != bindingCode {
                // Our key is still held and a different modifier moved. Only
                // counts as interference while our key is actually held.
                onOtherKey?()
            }

        case .keyDown:
            let escapeKeyCode: Int64 = 53
            if keyCode == escapeKeyCode {
                onEscape?()
            } else if isBindingKeyDown {
                onOtherKey?()
            }

        default:
            break
        }
    }
}
