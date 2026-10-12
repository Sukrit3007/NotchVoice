# Changelog

All notable changes to NotchVoice are recorded here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- An optional local cleanup model, offered in Settings → Cleanup. A 2.3GB
  download that runs entirely on this Mac and formats better than Apple
  Intelligence does — paragraphs where you change subject, lists where you list
  things — at the cost of a couple of seconds per dictation. Off by default,
  removable, and the switch is independent of the download so turning it off
  does not mean fetching it again to change your mind.
- Hold `fn` to dictate; release to transcribe and paste at the cursor.
- `fn`+`Space` locks a hands-free session; `fn` again to finish.
- Transcripts are tidied up on-device (Apple Foundation Models) before pasting,
  under a deadline — past it the raw transcript is delivered rather than the
  paste being held up.
- A panel drops out of the notch to explain a failure in a full sentence, which
  the island's wing has never had room for.
- VoiceOver support for the island and the panel.
- An app icon — 🗣️ on a white rounded-rect. The app had none, which showed as a
  grey placeholder in the Privacy & Security lists it sends you to.
- The app is now called **Notch Voice** — display name, `.app` filename and
  executable. The bundle identifier stays `com.sukrit.notchvoice`: reverse-DNS
  identifiers do not take spaces, and it keys both the TCC grants and the saved
  preferences. Renaming the bundle around a stable identifier kept the
  Microphone, Accessibility and Input Monitoring grants intact.
- Status UI in the MacBook notch, with a system-HUD-style fallback on displays
  without one.
- Live waveform driven by real microphone amplitude.
- On-device transcription via WhisperKit, model resident for instant starts.
- Clipboard-safe delivery — the original clipboard is restored unless something
  else wrote to it during the paste.
- The paste is verified rather than assumed: the text is staged as a pasteboard
  promise, so "Done" now means an app actually read it, and "⌘V" means it did not.

### Changed

- The event tap consumes the events it owns, where it previously only observed.
  This is what reserves `fn` — without it, holding the Globe key would also open
  the emoji picker on most Macs. It takes exactly three things: `fn` itself,
  `Space` while `fn` is held, and `Escape` during a dictation.
- **Accessibility is now required.** A consuming tap needs it, so without it the
  hotkey does nothing at all — where before it degraded to copy-only.
- The island appears the instant the key goes down. The old 150ms delay existed
  because right-⌥ also types `ø`; `fn` types nothing, so it was pure latency.
- Feedback cues are generated, not recorded. Four originals synthesised by
  `Tools/SoundGen` as one family — A4/D5/E5/A5, all under 0.08 peak and 210ms —
  so there is no third-party audio anywhere in the app.
- Transcripts are no longer written to the system log in the clear. Logging moved
  from `NSLog` to `os.Logger`, and anything derived from speech is `.private`.
- Menu bar glyph is 🗣️, and ⚠️ when a permission is missing or the model failed.
  Emoji cannot carry a badge the way `waveform.badge.exclamationmark` did, so the
  whole glyph swaps instead — the always-visible warning survives, by a different
  mechanism.
- App Nap no longer throttles the app while it waits for the dictation key. It
  holds a user-initiated activity for its lifetime, which still lets the Mac
  sleep when idle. After wake, the event tap is checked straight away.

### Removed

- The failure sound. A dictation that failed is explained in words by the panel
  dropping out of the notch, which a tone cannot do.
- Menu bar item showing permission state, with links into System Settings.
- Launch at login.
- Design spec for the notch-based dictation app.
- Repository scaffolding: gitignore, readme, versioning convention.

### Fixed

- The first words of a dictation are no longer clipped when the app being
  dictated into is slow to answer. The microphone starts the instant the key
  goes down; reading the field for context now happens after it, off the main
  thread, and every Accessibility call in that read shares one quarter-second
  budget instead of each getting its own.
- The event tap runs on a thread of its own instead of the main one, so nothing
  else the app does can sit in the path of keystrokes. A tap macOS switches off
  is re-enabled — at once when macOS says so, within two seconds when it does
  not — and rebuilt if it keeps happening. A key release lost while that
  happened no longer leaves a dictation recording until the five-minute cap.
- Pasting works on Dvorak and other layouts that move the V key. The synthetic
  ⌘V used to press whichever key sits where QWERTY's V is — ⌘K on Dvorak. It
  now presses the key that types "v" with ⌘ held on the current layout.
- A dictation pastes into the field it started in, even if focus moved to
  another field or tab of the same app while it was transcribing. The focused
  element is remembered at key-down and focused again before ⌘V; if it is gone,
  the paste goes wherever focus is, as before.
- Dictations no longer land in clipboard-manager history. The text staged for a
  paste is marked transient and concealed, the nspasteboard.org convention that
  clipboard managers honour. Copy-only results stay unmarked, since that text is
  meant to stay on the clipboard.
- "Done" no longer appears for a paste that was read but never arrived — a
  field that cannot take text, or a clipboard manager answering in the target's
  place. Where the field exposes its length and selection, both are compared
  before and after for up to half a second; if neither moved, the text stays on
  the clipboard and the notch says so. The field's text is never read for this.

## [0.1.0] - 2026-09-08

### Added

- Notch-first dictation with an invisible idle state, connected notch panel, and
  temporary external-display HUD fallback.
- Target-safe clipboard delivery, one-at-a-time processing, persistent history,
  and visible temporary-store warnings.
- Release checks for Core, app-hosted, and SoundGen tests, stable Xcode 26.6,
  signing identity, semantic versions, and resumable Sparkle publishing.

### Changed

- Apple cleanup uses a fresh Foundation Models session for every dictation and
  cleanup deadlines return the raw transcript when they expire.

<!--
The public 0.1.0 tag still requires the physical MacBook acceptance matrix in
docs/acceptance.md. Automated checks are necessary but do not replace the
microphone, notch, permission, sleep/wake, and reduced-motion pass.
-->
