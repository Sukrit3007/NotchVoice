import AppKit
import Observation

/// State behind the first-run flow.
///
/// Polls permissions for the same reason the Settings window does: they are
/// changed in System Settings, in another process, and nothing notifies us. On
/// a screen whose entire job is "grant this", a tick that only updates when the
/// user clicks something would be the app appearing not to notice.
@MainActor
@Observable
final class OnboardingModel {

    private(set) var step: OnboardingStep = .welcome
    private(set) var status: PermissionStatus

    /// Text the user dictates on the "try it" step. Bound to a real text field
    /// so the demo runs through the actual paste path rather than a simulation
    /// of it — if delivery is broken, this is where it shows.
    var scratch = ""

    @ObservationIgnored private let coordinator: DictationCoordinator
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private static let pollInterval = Duration.milliseconds(600)

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        self.status = PermissionChecker.status()
    }

    var modelPhase: ModelPhase { coordinator.modelPhase }
    var canDictate: Bool { coordinator.readiness.canDictate }

    /// Whether the current step is satisfied and the flow can move on.
    ///
    /// The permission steps gate on the grant, because "Continue" past an
    /// ungranted permission leads to an app that silently does nothing. The
    /// model step gates on readiness. Everything else is free to skip.
    var canContinue: Bool {
        switch step {
        case .microphone: status.microphone
        case .inputMonitoring: status.inputMonitoring
        case .accessibility: status.accessibility
        case .model: coordinator.modelPhase == .ready
        default: true
        }
    }

    /// True once the user has actually dictated something into the scratch
    /// field. The only proof in the whole flow that the pipeline works.
    var hasDictated: Bool {
        !scratch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Navigation

    func advance() {
        guard let next = step.next else { return }
        step = next
        if step == .model { coordinator.loadModel() }
    }

    func goBack() {
        guard let previous = step.previous else { return }
        step = previous
    }

    func finish() {
        OnboardingPreference.isComplete = true
        stopPolling()
    }

    // MARK: - Permissions

    func request(_ kind: PermissionChecker.Kind) {
        switch kind {
        case .microphone:
            // The system dialog is the only thing that can grant this. Settings
            // alone just shows a switch that is already off.
            Task { _ = await PermissionChecker.requestMicrophone() }
        case .accessibility:
            // The prompt is what gets the app *listed*. Opening System Settings
            // first can land the user on a list with nothing to switch on.
            Paster.promptForAccessibility()
            PermissionChecker.openSettings(for: kind)
        case .inputMonitoring:
            // Same shape: attempting a tap is what registers the app.
            coordinator.armTap()
            PermissionChecker.openSettings(for: kind)
        }
    }

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
    }

    private func refresh() {
        let latest = PermissionChecker.status()
        // Re-arming when Input Monitoring or Accessibility lands is what makes
        // the tap live without a relaunch — the same reason Settings does it.
        let gainedTapPermission =
            (!status.inputMonitoring && latest.inputMonitoring)
            || (!status.accessibility && latest.accessibility)
        status = latest
        if gainedTapPermission { coordinator.armTap() }
    }
}
