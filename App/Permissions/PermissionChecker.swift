import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid   // IOHIDCheckAccess — Input Monitoring status

struct PermissionStatus {
    let microphone: Bool
    let inputMonitoring: Bool
    let accessibility: Bool

    /// Only microphone and input monitoring are hard requirements —
    /// accessibility degrades to copy-only rather than breaking the app.
    var canDictate: Bool { microphone && inputMonitoring }
    var allGranted: Bool { microphone && inputMonitoring && accessibility }
}

enum PermissionChecker {

    enum Kind {
        case microphone
        case inputMonitoring
        case accessibility

        var settingsURL: URL {
            let base = "x-apple.systempreferences:com.apple.preference.security"
            switch self {
            case .microphone:
                return URL(string: "\(base)?Privacy_Microphone")!
            case .inputMonitoring:
                return URL(string: "\(base)?Privacy_ListenEvent")!
            case .accessibility:
                return URL(string: "\(base)?Privacy_Accessibility")!
            }
        }
    }

    /// Read live every time rather than cached. The user can revoke any of
    /// these in System Settings while the app is running, and a cached answer
    /// would leave the menu asserting something false.
    static func status() -> PermissionStatus {
        PermissionStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
            accessibility: AXIsProcessTrusted()
        )
    }

    static func openSettings(for kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
