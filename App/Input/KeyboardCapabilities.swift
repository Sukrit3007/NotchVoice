import IOKit.hid
import NotchVoiceCore

/// Whether the keyboards attached to this Mac have an fn key.
///
/// The default binding is fn, and an external non-Apple keyboard does not have
/// one — binding to a key that cannot physically be pressed is an app that is
/// silently dead.
///
/// Detected by vendor and transport, not by looking for the key's HID element:
/// reading a device's elements requires opening it, which requires Input
/// Monitoring — the very permission that may not be granted when this runs.
/// Vendor ID and transport are readable without opening anything.
enum KeyboardCapabilities {

    /// Apple's USB vendor ID. Apple keyboards report this whether they are the
    /// built-in one or an external Magic Keyboard.
    private static let appleVendorID = 0x05AC

    /// Whether any attached keyboard can produce an fn key press.
    ///
    /// Deliberately "any", not "the active one": there is no way to know which
    /// keyboard the user is about to type on, and offering fn when at least one
    /// attached keyboard has it is the answer that is right more often. A user
    /// on a laptop with an external keyboard plugged in can still reach for the
    /// built-in one.
    static func hasFnKey() -> Bool {
        guard let keyboards = attachedKeyboards() else {
            // The manager itself failed, which is not the same as "no fn key".
            // Assume the key exists rather than silently rebinding the app out
            // from under someone whose keyboard we simply could not enumerate.
            Log.input.warning("Could not enumerate keyboards — assuming fn is available")
            return true
        }

        if keyboards.isEmpty {
            // No keyboard at all usually means the matching ran before the
            // system finished enumerating. Same reasoning as above.
            Log.input.notice("No keyboards matched — assuming fn is available")
            return true
        }

        for device in keyboards {
            let vendor = intProperty(device, kIOHIDVendorIDKey)
            let transport = stringProperty(device, kIOHIDTransportKey)
            let product = stringProperty(device, kIOHIDProductKey) ?? "unknown"

            // The built-in keyboard is on SPI on Apple Silicon. Some report no
            // vendor ID at all, which is the "missing metadata" case.
            let isBuiltIn = transport == "SPI" || transport == "FIFO"
            let isApple = vendor == appleVendorID

            if isBuiltIn || isApple {
                Log.input.info(
                    "fn available via \(product, privacy: .public) (transport \(transport ?? "none", privacy: .public))")
                return true
            }
        }

        Log.input.notice("Only non-Apple keyboards attached — assuming no fn key")
        return false
    }

    /// The binding to use, downgrading away from fn when there is no fn key.
    ///
    /// Called with whatever the user has stored, so a deliberate choice of a
    /// right-hand modifier is never overridden — only a binding that depends on
    /// hardware which is not present.
    static func resolve(_ preferred: ModifierKey) -> ModifierKey {
        guard preferred.needsFnKey, !hasFnKey() else { return preferred }
        Log.input.notice(
            "\(preferred.displayName, privacy: .public) needs an fn key this keyboard lacks — using \(ModifierKey.fallback.displayName, privacy: .public)")
        return .fallback
    }

    // MARK: - HID

    private static func attachedKeyboards() -> [IOHIDDevice]? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Matching only — the manager is never opened, so this needs no
        // permission and cannot block.
        let criteria: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return nil
        }
        return Array(devices)
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
