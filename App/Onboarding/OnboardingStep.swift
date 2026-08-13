import Foundation

/// The first-run flow, in order.
///
/// **There is deliberately no "macOS will say it can't verify this app" step.**
/// The plan called for one, and it is in the wrong place: by the time any code
/// here runs, Gatekeeper has already been satisfied. A screen explaining a
/// dialog the user got past thirty seconds ago teaches them nothing. That
/// explanation belongs on the download page, *before* the first launch — see
/// the note in README.
enum OnboardingStep: Int, CaseIterable, Identifiable, Comparable {
    case welcome
    case microphone
    case inputMonitoring
    case accessibility
    case model
    case tryIt
    case done

    var id: Int { rawValue }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The permission this step is about, if it is about one.
    var permission: PermissionChecker.Kind? {
        switch self {
        case .microphone: .microphone
        case .inputMonitoring: .inputMonitoring
        case .accessibility: .accessibility
        default: nil
        }
    }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    var previous: OnboardingStep? {
        rawValue > 0 ? OnboardingStep(rawValue: rawValue - 1) : nil
    }

    /// Steps shown as dots. `done` is excluded — a progress indicator that still
    /// has a step left on the final screen reads as unfinished.
    static var progressSteps: [OnboardingStep] {
        allCases.filter { $0 != .done }
    }
}

/// Whether the first-run flow has been completed.
///
/// Keyed on completion rather than on "has launched before", so a flow abandoned
/// halfway is offered again instead of being lost. Someone who quits at the
/// Accessibility step has not been onboarded, whatever the launch count says.
enum OnboardingPreference {
    private static let key = "onboardingCompleted"

    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
