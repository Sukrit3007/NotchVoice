import AppKit
import NotchVoiceCore
import Observation

/// State behind the window: which pane is showing, whether the permissions it
/// needs are granted, and the live hotkey test.
///
/// One description of "can this app work right now", so a wizard and a menu
/// cannot disagree about it.
@MainActor
@Observable
final class SettingsModel {

    enum TestState: Equatable {
        /// A permission required to dictate is missing, so there is nothing to
        /// test yet.
        case blocked
        /// Everything needed is granted and no test is running. The pane offers
        /// a button.
        ///
        /// This state is what stopped the test running on every open. It used
        /// to start by itself whenever the window appeared, which was right for
        /// a one-time wizard and wrong the moment this became Settings: opening
        /// it to mute a sound began a hotkey test that then "failed" after
        /// eight seconds of reading. That is the app inventing a problem.
        case idle
        /// Waiting for the user to press the key.
        case waiting
        /// A real keystroke reached the tap.
        case passed
        /// Nothing arrived in the window we waited.
        ///
        /// Deliberately distinct from `needsRestart`: the overwhelmingly likely
        /// cause is that the user was reading rather than pressing, and
        /// announcing "restart required" because somebody took ten seconds
        /// would be the app inventing a diagnosis. This state says only what is
        /// true — nothing has been seen yet — and offers both a retry and the
        /// restart.
        case notSeenYet
        /// The tap refused to arm at all. `ModifierTap.start()` returns false
        /// only when Input Monitoring is not granted to *this* copy, which is a
        /// real signal rather than an inference from silence.
        case needsRestart
    }

    var pane: LibraryPane = .history
    private(set) var status: PermissionStatus
    private(set) var test: TestState = .blocked

    /// Mirrored rather than read through to `BindingStore` on every access.
    ///
    /// A computed property over `UserDefaults` is invisible to SwiftUI — the
    /// picker would write a new binding and then redraw showing the old one.
    private(set) var binding: ModifierKey

    /// How long to wait for a keystroke before concluding the tap is dead.
    ///
    /// Generous: it covers the user reading the instruction, not just pressing
    /// the key. Concluding "needs a restart" wrongly is the expensive error —
    /// it costs the user a relaunch they did not need.
    private static let testTimeout = Duration.seconds(8)

    /// The permission panes can be changed while this window sits open, and
    /// nothing notifies us. Polling is the only way the ticks flip without the
    /// user having to close and reopen something to see the truth.
    private static let pollInterval = Duration.milliseconds(700)

    @ObservationIgnored private let coordinator: DictationCoordinator
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        self.status = PermissionChecker.status()
        self.binding = BindingStore.binding
    }

    // MARK: - Lifecycle

    func startPolling() {
        refresh()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        endTest()
    }

    // MARK: - Permission state

    private func refresh() {
        let latest = PermissionChecker.status()
        // Either of these can be the one that unblocks the tap. Input Monitoring
        // was the only one worth watching while the tap merely observed;
        // consuming events needs Accessibility as well, so a grant there is
        // equally a moment the tap that failed at launch might now arm.
        let gainedTapPermission =
            (!status.inputMonitoring && latest.inputMonitoring)
            || (!status.accessibility && latest.accessibility)
        status = latest

        guard latest.canDictate else {
            // A revocation while the window is open drops us back to blocked,
            // so the test cannot report "passed" about a permission that has
            // since been taken away.
            if test != .blocked { endTest(); test = .blocked }
            return
        }

        if gainedTapPermission {
            // The one moment worth acting on unasked. Trying is the only way to
            // find out whether the tap works now.
            beginTest()
        } else if test == .blocked {
            // Unblocked by something we did not watch land — Microphone, or the
            // window opening after the fact. Offer the test; do not start it.
            test = .idle
        }
    }

    // MARK: - The binding

    /// Switches the dictation key, then proves the new one arrives.
    ///
    /// The test runs unasked here for the same reason it does after a grant:
    /// the user has just changed the one thing that can silently stop the app
    /// working, and no other signal would tell them. Everywhere else it is a
    /// button.
    func rebind(to key: ModifierKey) {
        guard key != binding else { return }
        binding = key

        guard coordinator.rebind(to: key) else {
            Log.settings.error("Tap would not arm after rebind")
            endTest()
            test = .needsRestart
            return
        }
        // `startWaiting()`, not `beginTest()`: `rebind` has already armed a tap
        // against the new key. Arming again would tear that one down and build
        // a third a moment later, which is both wasted work and a second chance
        // to strand a gesture — the exact thing `rebind` sequences to avoid.
        startWaiting()
    }

    // MARK: - The live test

    /// Re-creates the event tap and waits for a real keystroke.
    ///
    /// This is the whole point of the window. `IOHIDCheckAccess` reporting
    /// "granted" does not prove events will arrive, and the codebase carried an
    /// unverified assumption that Input Monitoring could never arm without a
    /// relaunch. Rather than build a mandatory restart on that assumption, the
    /// app tries, and only offers a restart when the attempt produces nothing.
    func beginTest() {
        endTest()

        guard status.canDictate else {
            test = .blocked
            return
        }

        guard coordinator.armTap() else {
            Log.settings.error("Tap would not arm after grant — restart needed")
            test = .needsRestart
            return
        }

        startWaiting()
    }

    /// Listens for one real keystroke on an already-armed tap.
    ///
    /// Split out from `beginTest()` so a rebind can wait on the tap it just
    /// created instead of replacing it first.
    ///
    /// Clears the previous test itself rather than trusting the caller to.
    /// Reassigning `timeoutTask` drops the reference but does not cancel the
    /// task, so an abandoned timer would still be running and would stamp
    /// `.notSeenYet` over a test that had only just started.
    private func startWaiting() {
        endTest()
        test = .waiting
        coordinator.onBindingKeyDown = { [weak self] in
            guard let self, test == .waiting else { return }
            Log.settings.info("Keystroke received — tap is live")
            test = .passed
            endTest()
            // The model was skipped at launch when nothing could trigger a
            // dictation. Now something can.
            coordinator.loadModel()
        }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.testTimeout)
            guard !Task.isCancelled, let self, test == .waiting else { return }
            Log.settings.notice("No keystroke yet — offering retry and restart")
            test = .notSeenYet
            endTest()
        }
    }

    private func endTest() {
        timeoutTask?.cancel()
        timeoutTask = nil
        coordinator.onBindingKeyDown = nil
    }

    // MARK: - Actions

    func grant(_ kind: PermissionChecker.Kind) {
        switch kind {
        case .microphone:
            // The system dialog is the only thing that can actually grant this;
            // Settings alone just shows a switch that is already off.
            Task { _ = await PermissionChecker.requestMicrophone() }

        case .accessibility:
            // The prompt is what gets the app *listed* in the Accessibility
            // pane. Opening System Settings alone can land the user on a list
            // with nothing to switch on.
            Paster.promptForAccessibility()

        case .inputMonitoring:
            // Same shape: attempting a tap is what registers the app in the
            // Input Monitoring pane, so do that before sending the user there.
            coordinator.armTap()
        }

        PermissionChecker.openSettings(for: kind)
    }

    func restart() {
        ApplicationRelauncher.restart()
    }
}
