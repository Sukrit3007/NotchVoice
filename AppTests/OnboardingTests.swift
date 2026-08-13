import Testing
import Foundation
@testable import NotchVoice

@Suite("Onboarding flow")
struct OnboardingStepTests {

    @Test("the flow starts at welcome and ends at done")
    func endpoints() {
        #expect(OnboardingStep.allCases.first == .welcome)
        #expect(OnboardingStep.allCases.last == .done)
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.done.next == nil)
    }

    @Test("stepping forward then back returns to where it started")
    func navigationRoundTrips() {
        for step in OnboardingStep.allCases {
            guard let next = step.next else { continue }
            #expect(next.previous == step)
        }
    }

    @Test("all three permissions are asked for, one screen each")
    func everyPermissionHasAStep() {
        // A permission with no step is one the user is never asked for and the
        // app then silently fails on.
        let asked = OnboardingStep.allCases.compactMap(\.permission)
        #expect(Set(asked) == Set(PermissionChecker.Kind.allCases))
        #expect(asked.count == PermissionChecker.Kind.allCases.count)
    }

    @Test("permissions come before the model download")
    func permissionsPrecedeTheModel() {
        // Deliberate: a 630MB download is a bad thing to make someone wait
        // through before finding out the app cannot work on their Mac.
        for step in OnboardingStep.allCases where step.permission != nil {
            #expect(step < .model)
        }
    }

    @Test("trying it out comes after everything it depends on")
    func tryItIsLast() {
        // Dictating needs all three permissions and a loaded model.
        #expect(OnboardingStep.tryIt > .model)
        #expect(OnboardingStep.tryIt > .accessibility)
    }

    @Test("the final screen is not counted as a step to complete")
    func doneIsNotAProgressStep() {
        // A dot still unfilled on the last screen reads as unfinished.
        #expect(!OnboardingStep.progressSteps.contains(.done))
        #expect(OnboardingStep.progressSteps.count == OnboardingStep.allCases.count - 1)
    }

    @Test("every permission step explains itself at length")
    func permissionsAreExplained() {
        for kind in PermissionChecker.Kind.allCases {
            // `purpose` is a fragment for a settings row; onboarding is a whole
            // screen and these are the two scariest permissions on the Mac.
            #expect(kind.onboardingExplanation.count > 80)
            #expect(kind.onboardingExplanation != kind.purpose)
        }
    }

    @Test("Input Monitoring names the thing people are afraid of")
    func inputMonitoringIsHonest() {
        // Saying "keylogger" out loud and then explaining why this isn't one
        // beats hoping nobody wonders.
        let text = PermissionChecker.Kind.inputMonitoring.onboardingExplanation
        #expect(text.localizedCaseInsensitiveContains("keylogger"))
    }
}

@Suite("Onboarding preference")
struct OnboardingPreferenceTests {

    @Test("completion round-trips")
    func roundTrips() {
        let original = OnboardingPreference.isComplete
        defer { OnboardingPreference.isComplete = original }

        OnboardingPreference.isComplete = false
        #expect(!OnboardingPreference.isComplete)
        OnboardingPreference.isComplete = true
        #expect(OnboardingPreference.isComplete)
    }

    @Test("an absent preference means not yet onboarded")
    func defaultsToIncomplete() {
        let original = OnboardingPreference.isComplete
        defer { OnboardingPreference.isComplete = original }

        // A fresh install must get the flow. Defaulting the other way would skip
        // it for everyone who has never run the app.
        UserDefaults.standard.removeObject(forKey: "onboardingCompleted")
        #expect(!OnboardingPreference.isComplete)
    }
}
