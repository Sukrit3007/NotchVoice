import AppKit
import Carbon.HIToolbox
import Observation

/// Notices when another app has turned on Secure Event Input, and which app.
///
/// While it is on, macOS keeps keystrokes away from event taps — this one
/// included — so the hands-free chord and Escape cannot arrive, and the
/// dictation key may not either. Without this the hotkey just stops working
/// with no explanation.
///
/// A focused password field turns it on, which is brief and expected; the case
/// worth a warning is an app that keeps it on — Terminal's Secure Keyboard
/// Entry, or a password manager that never turned it off. Hence the delay
/// before it is mentioned.
///
/// Polled, because macOS announces no change. Once a second is one cheap call,
/// plus a session lookup only while it is on.
@MainActor
@Observable
final class SecureInputMonitor {

    private static let pollInterval = Duration.seconds(1)
    /// Polls in a row with Secure Input on before it is mentioned — longer
    /// than it takes to type a password.
    private static let mentionAfter = 5

    /// True once another app has held Secure Input for long enough to explain.
    private(set) var isBlocking = false
    /// That app's name, when it could be found.
    private(set) var holderName: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pollsOn = 0

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                poll()
            }
        }
    }

    private func poll() {
        let enabled = IsSecureEventInputEnabled()
        let pid = enabled ? Self.holderPID() : nil

        guard enabled, pid != getpid() else {
            pollsOn = 0
            if isBlocking {
                isBlocking = false
                holderName = nil
                Log.input.info("Secure Input is off again")
            }
            return
        }

        pollsOn += 1
        guard pollsOn >= Self.mentionAfter, !isBlocking else { return }
        holderName = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        isBlocking = true
        Log.input.notice(
            "Secure Input held by \(self.holderName ?? "an unknown process", privacy: .public) (pid \(pid ?? -1, privacy: .public)) — keystrokes cannot reach the tap")
    }

    /// The process holding Secure Input, from the login session's dictionary.
    /// The key is undocumented but long-stable, and the lookup is read-only.
    private static func holderPID() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? Int
        else { return nil }
        return pid_t(pid)
    }
}
