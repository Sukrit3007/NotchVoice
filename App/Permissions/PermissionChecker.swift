import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid   // IOHIDCheckAccess — Input Monitoring status

struct PermissionStatus: Equatable {
    let microphone: Bool
    let inputMonitoring: Bool
    let accessibility: Bool

    /// All three are hard requirements, Accessibility included.
    ///
    /// macOS grants a `.listenOnly` tap on Input Monitoring alone, but a tap
    /// that *destroys* events needs Accessibility — and the fn binding depends
    /// on destroying the fn keypress before it opens the emoji picker. Without
    /// this permission the hotkey does not fire at all.
    var canDictate: Bool { microphone && inputMonitoring && accessibility }

    func isGranted(_ kind: PermissionChecker.Kind) -> Bool {
        switch kind {
        case .microphone: microphone
        case .inputMonitoring: inputMonitoring
        case .accessibility: accessibility
        }
    }
}

enum PermissionChecker {

    enum Kind: Hashable, CaseIterable, Identifiable {
        case microphone
        case inputMonitoring
        case accessibility

        var id: Self { self }

        /// Copy lives here so the menu bar and the Settings window cannot drift
        /// apart describing the same permission.
        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .inputMonitoring: "Input Monitoring"
            case .accessibility: "Accessibility"
            }
        }

        var purpose: String {
            switch self {
            case .microphone: "Recording what you say."
            case .inputMonitoring: "Noticing the key you hold to dictate."
            // Two jobs, and the first is why it is mandatory: reserving the fn
            // key needs a tap that can consume events, which macOS only allows
            // with Accessibility.
            case .accessibility: "Reserving the dictation key, and pasting at your cursor."
            }
        }

        var whenMissing: String? {
            self == .accessibility
                ? "Without this, the dictation key does nothing."
                : nil
        }

        var symbol: String {
            switch self {
            case .microphone: "mic.fill"
            case .inputMonitoring: "keyboard.fill"
            case .accessibility: "cursorarrow.rays"
            }
        }

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
