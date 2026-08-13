import AVFoundation

/// Short sounds for the moments the island cannot reach.
///
/// While dictating the user is looking at the text field, not at a 32pt strip
/// along the top edge — and peripheral vision resolves motion and brightness,
/// not 12pt glyphs. Sound is the channel that needs no looking at.
///
/// The files are generated, not recorded — see `Tools/SoundGen`.
///
/// **There is deliberately no failure cue.** A sound that only ever means "that
/// didn't work" is one the user learns to dread; `NotchPanelView` says it in
/// words instead.
@MainActor
enum Cues {

    enum Cue: String, CaseIterable, Identifiable {
        /// Capture is live. Fires before the user has started speaking.
        case start = "cue-start"
        /// The key was released and decoding has begun.
        ///
        /// Transcription takes a second or two, and without this the loop has a
        /// silent hole in the middle of it — the user lets go and hears nothing
        /// until the text lands.
        case stop = "cue-processing"
        /// A hands-free session began — otherwise indistinguishable from a
        /// normal hold without looking up.
        case lock = "cue-locked"
        /// Transcript delivered.
        case done = "cue-delivered"

        var id: Self { self }

        /// The bundled file, named for the cue's own raw value so the two
        /// cannot drift apart.
        var fileName: String { rawValue }

        /// What the Sound pane calls this cue.
        ///
        /// Named for the moment, not the case: a user previewing sounds is
        /// matching them to points in a dictation, and "Processing" tells them
        /// where `.stop` lands where "Stop" would suggest the opposite.
        var title: String {
            switch self {
            case .start: "Recording starts"
            case .stop: "Processing"
            case .lock: "Hands-free locked"
            case .done: "Text delivered"
            }
        }
    }

    /// Loaded once and reused. Building a player decodes audio, which is not
    /// work to do on the path of a key press.
    private static var players: [Cue: AVAudioPlayer] = [:]

    static func play(_ cue: Cue) {
        guard SoundPreference.isEnabled else { return }
        guard let player = player(for: cue) else { return }
        // Rewind rather than stop-then-play: a player already running ignores
        // `play()` outright, so two quick dictations would drop the second cue.
        player.currentTime = 0
        player.play()
    }

    /// Warms the cache so the first dictation of a session is not the one that
    /// pays for decoding.
    static func prewarm() {
        for cue in Cue.allCases { _ = player(for: cue) }
    }

    private static func player(for cue: Cue) -> AVAudioPlayer? {
        if let cached = players[cue] { return cached }
        guard let url = Bundle.main.url(forResource: cue.fileName, withExtension: "wav") else {
            Log.audio.error("Cue asset missing: \(cue.fileName, privacy: .public).wav")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            players[cue] = player
            return player
        } catch {
            // Not fatal — dictation still works, it is just silent.
            Log.audio.error(
                "Could not build cue \(cue.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
