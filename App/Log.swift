import NotchVoiceCore
import os

/// Loggers for the app, one category per area.
///
/// `Logger` rather than `NSLog`, and not for tidiness: `NSLog` writes every
/// argument in the clear, where anything that can run `log show` reads it — and
/// this app handles speech that may contain a password or an address.
///
/// `Logger` can log a transcript's *shape* while redacting its content.
/// Interpolate any transcript, or anything derived from one, as
/// `\(text, privacy: .private)`. Everything else stays public, because timings
/// and state transitions are what make a failure diagnosable.
enum Log {
    private static let subsystem = NotchVoice.bundleID

    static let dictation = Logger(subsystem: subsystem, category: "dictation")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let deliver = Logger(subsystem: subsystem, category: "deliver")
    static let polish = Logger(subsystem: subsystem, category: "polish")
    static let island = Logger(subsystem: subsystem, category: "island")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let data = Logger(subsystem: subsystem, category: "data")
}
