import FoundationModels

/// Whether the on-device cleanup model can run, in this app's own terms.
///
/// Exists so that `FoundationModels` stops at the `Polish` folder. The framework
/// type is an enum with an associated `UnavailableReason` that gains cases as
/// Apple adds them; mapping it once here means Settings and the coordinator
/// depend on four stable cases instead, and a new reason from the OS lands in
/// exactly one switch rather than three.
enum PolishAvailability: Equatable {
    case available
    /// Apple Intelligence is switched off in System Settings.
    case notEnabled
    /// This Mac cannot run it at all.
    case notSupported
    /// Downloading, or otherwise not ready yet. Resolves on its own.
    case notReady

    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(.appleIntelligenceNotEnabled):
            self = .notEnabled
        case .unavailable(.deviceNotEligible):
            self = .notSupported
        case .unavailable(.modelNotReady):
            self = .notReady
        case .unavailable:
            // A reason this build does not know about. Treated as "not ready"
            // rather than "not supported", because the honest thing to tell the
            // user is that it might work later, not that their Mac cannot.
            self = .notReady
        }
    }

    /// What Settings says about it. Nil when there is nothing to report.
    var explanation: String? {
        switch self {
        case .available:
            nil
        case .notEnabled:
            "Turn on Apple Intelligence to have transcripts tidied up before they're pasted."
        case .notSupported:
            "This Mac can't run on-device cleanup. Transcripts are pasted as they're heard."
        case .notReady:
            "The cleanup model isn't ready yet. Transcripts are pasted as they're heard for now."
        }
    }
}
