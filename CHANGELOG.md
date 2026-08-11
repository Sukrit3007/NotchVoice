# Changelog

All notable changes to NotchVoice are recorded here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Hold right-Option to dictate; release to transcribe and paste at the cursor.
- Double-tap to lock a hands-free session; tap again to finish.
- Status UI in the MacBook notch, with a system-HUD-style fallback on displays
  without one.
- Live waveform driven by real microphone amplitude.
- On-device transcription via WhisperKit, model resident for instant starts.
- Clipboard-safe delivery — the original clipboard is restored unless something
  else wrote to it during the paste.
- Copy-only fallback when Accessibility has not been granted.
- Menu bar item showing permission state, with links into System Settings.
- Launch at login.
- Design spec for the notch-based dictation app.
- Repository scaffolding: gitignore, readme, versioning convention.

<!--
Held under [Unreleased] on purpose. The 0.1.0 heading and its tag go on only
once the acceptance matrix in the milestone plan has actually been worked
through on hardware — dictating into real apps, the two non-interference and
clipboard gates, and the display cases. Every automated check passes, but
nothing above has been driven by a human yet, and a version number is a claim
that it has.
-->

