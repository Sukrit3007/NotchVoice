import Foundation
import NotchVoiceCore

/// Tidies a raw transcript into written prose, on-device, or gets out of the way.
///
/// Whisper transcribes what was said, disfluencies and all — "um", false starts,
/// a repeated word, no punctuation past what the acoustic model guessed. This
/// step turns that into something you would have typed.
///
/// Two backends can do it and this picks between them. Everything that keeps the
/// step *safe* lives here rather than in either one: the deadline, the
/// plausibility check, and the rule that any failure whatsoever resolves to the
/// raw transcript. A backend is only asked to be good, never to be careful.
actor PolishService {

    private let apple = AppleIntelligencePolish()
    private let local = LocalModelPolish()

    /// Which backend a dictation would use right now, or nil for none.
    ///
    /// Computed per call rather than chosen once at launch: the preference can
    /// be toggled, the model can be deleted, and Apple Intelligence can be
    /// switched off, all while the app is running.
    private var backend: (any PolishBackend)? {
        if LocalPolishPreference.isEnabled, local.isAvailable { return local }
        if apple.isAvailable { return apple }
        return nil
    }

    /// What Settings says about Apple's model specifically. The local one
    /// reports through `LocalModelInstaller` instead, which knows about bytes.
    nonisolated var availability: PolishAvailability {
        apple.availability
    }

    /// True when something will tidy the next dictation.
    nonisolated var isAvailable: Bool {
        (LocalPolishPreference.isEnabled && local.isAvailable) || apple.isAvailable
    }

    /// Warms whichever backend is going to be used, so the first dictation does
    /// not pay for it. Safe to call again.
    func prepare() async {
        guard let backend else {
            // Said out loud rather than returned from silently. "Transcripts are
            // never tidied" and "the polish step is broken" look identical from
            // outside the process, and this is the line that tells them apart —
            // the failure this whole service degrades into is also the one that
            // is hardest to distinguish from a bug.
            Log.polish.notice(
                "Polish unavailable (\(String(describing: self.availability), privacy: .public)) — transcripts will be pasted as heard")
            return
        }

        if backend is LocalModelPolish {
            // Loading 2.3GB is worth doing off the launch path, but it must not
            // be able to take the app down: the model may have been deleted
            // outside the app since the preference was set.
            try? await local.prepare()
        } else {
            await apple.prepare()
        }
        Log.polish.info("Polish ready — \(backend.name, privacy: .public)")
    }

    /// Returns polished text, or the original if that cannot be done in time.
    ///
    /// Never throws and never returns empty: every failure path — no backend,
    /// too slow, model error, implausible output, the model answering itself —
    /// resolves to the raw transcript. A dictation must always deliver the words
    /// the user said, and a cleanup step is not permitted to be the reason one
    /// doesn't.
    func polish(_ text: String) async -> String {
        guard let backend else { return text }

        let started = ContinuousClock.now
        let polished = await race(backend, on: text)
        let elapsed = started.duration(to: .now)

        guard let polished else {
            Log.polish.notice(
                "Polish skipped after \(elapsed.milliseconds, privacy: .public)ms — delivering raw")
            return text
        }

        // Checked before length, because it is the more specific failure and
        // the one whose log line actually tells you what went wrong. A model
        // that repeats its prompt is a prompt problem, not a slow model.
        guard !PolishGuard.echoes(backend.instructions, in: polished) else {
            Log.polish.error(
                "\(backend.name, privacy: .public) echoed its instructions — delivering raw")
            return text
        }

        guard PolishGuard.isPlausible(polished, from: text) else {
            Log.polish.notice(
                "Polish returned an implausible rewrite — delivering raw")
            return text
        }

        Log.polish.info(
            "Polished by \(backend.name, privacy: .public) in \(elapsed.milliseconds, privacy: .public)ms")
        return polished
    }

    /// Runs the backend against its own deadline. Nil if it lost, or threw.
    private func race(_ backend: any PolishBackend, on text: String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    return try await backend.polish(text)
                } catch {
                    Log.polish.error(
                        "Polish failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: backend.deadline)
                return nil
            }

            // Whichever finishes first wins; the loser is cancelled rather than
            // left running against the next dictation.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private extension Duration {
    /// Whole milliseconds, for logging.
    var milliseconds: Int {
        Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
