import Foundation
import FoundationModels

/// Cleanup through the system's own on-device model.
///
/// The default, and free in every sense: nothing to download, nothing resident
/// that the OS was not already holding, and fast enough that the paste does not
/// visibly wait for it.
///
/// Unavailability is permanent rather than transient — Apple Intelligence off,
/// an ineligible Mac, a model still downloading. All of them mean "paste the raw
/// transcript", which is always a correct answer.
actor AppleIntelligencePolish: PolishBackend {

    nonisolated let name = "Apple Intelligence"

    /// Short on purpose. This model is quick, and every millisecond here is
    /// added to every dictation between the last word and the text appearing.
    /// Past it the raw transcript goes out and the rewrite is abandoned.
    nonisolated let deadline = Duration.milliseconds(400)

    nonisolated let instructions = PolishInstructions.light

    /// Low, because this is a rewrite and not a composition. Anything higher
    /// invents phrasing the user did not say, which is the one failure mode that
    /// matters when the output goes straight into their document.
    private static let options = GenerationOptions(temperature: 0.2)

    nonisolated var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Read live rather than cached — Apple Intelligence can be switched off,
    /// and a model that was downloading can finish, while the app is running.
    nonisolated var availability: PolishAvailability {
        PolishAvailability(SystemLanguageModel.default.availability)
    }

    /// Builds the session up front so the first dictation does not pay for it.
    /// Foundation Models sessions retain their transcript, so there is no
    /// reusable session to warm: each dictation gets a clean context below.
    func prepare() {
        // Availability is still checked here so the warm-up path has the same
        // behavior as the first real request.
        guard isAvailable else { return }
    }

    func polish(_ text: String) async throws -> String {
        prepare()
        guard isAvailable else { throw PolishError.unavailable }
        // A session is a conversation. Dictations are independent documents,
        // so sharing one would carry previous speech into the next rewrite and
        // eventually exhaust the session context window.
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text, options: Self.options)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PolishError: Error {
    case unavailable
}
