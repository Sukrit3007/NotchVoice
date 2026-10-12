import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid   // IOHIDCheckAccess — Input Monitoring status
import Security

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

        /// The same permission, explained to someone who has never used the app.
        ///
        /// Longer than `purpose`, which is a fragment sitting next to a tick in
        /// a settings list. Here it is the whole screen, and each one says what
        /// macOS is about to ask *and* what the app does with it — because these
        /// are the two most invasive-sounding permissions on the Mac and
        /// "Notch Voice would like to control your computer" deserves an answer.
        var onboardingExplanation: String {
            switch self {
            case .microphone:
                "So it can hear you. Audio is only captured while you hold the "
                + "dictation key, and it is transcribed on this Mac and then "
                + "thrown away — never saved, never uploaded."
            case .inputMonitoring:
                "So it can tell when you're holding the dictation key. macOS calls "
                + "this Input Monitoring because it's the same permission a "
                + "keylogger would need. Notch Voice looks at one key and ignores "
                + "everything else you type."
            case .accessibility:
                "Two things: reserving the dictation key so it doesn't also do "
                + "whatever macOS normally does with it, and pasting the text at "
                + "your cursor when you're done. Without it the key does nothing "
                + "at all."
            }
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

    /// The designated requirement this build is signed with, for the log line
    /// next to a permission failure.
    ///
    /// TCC keys every grant to it. A build signed by a different identity shows
    /// as granted in System Settings and is refused anyway — the "granted but
    /// broken" state that is otherwise very hard to tell apart from a real
    /// denial. See `docs/versioning.md` for the requirement releases must keep.
    static func signingRequirement() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return "unavailable" }
        return text as String
    }
}
