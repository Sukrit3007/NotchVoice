# Changelog

All notable changes to NotchVoice are recorded here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Dictation fits the text around the cursor. Mid-sentence it arrives with a
  space in front and without a full stop when the sentence carries on past the
  cursor, and a selection is replaced without doubled spaces. Nothing is spaced
  inside a word or after `#`, `$`, `@` or `/`. In English, a first word that is
  only capitalised for starting a sentence is lowered — "I think that's fine.",
  not "I thinkThat's fine." — but only when the system spell checker knows it
  in lower case and it is not a month, weekday or language, so "Monday",
  "Sarah" and "English" keep their capitals, as do "I", acronyms, your custom
  words and snippet expansions. Other languages, and automatic detection, keep
  every capital. Done by fixed rules, not the cleanup model, using a little of
  the text either side of the cursor read at key-down; it is never stored or
  logged. Skipped — the text pastes as before — for password fields, apps that
  don't expose their text, a cursor at the very start of a field (an empty
  editor can report its placeholder as text), a cursor that moved during a
  hands-free take, or with "Use what's on screen" off.
- Paste Last Transcript: `⌃⌘V`, or the menu bar item, pastes the most recent
  dictation again into whatever has focus — for a paste that went somewhere
  unexpected or only reached the clipboard. Kept in memory only, and the tap
  takes `⌃⌘V` only once there is a transcript to paste. Fixed rather than
  rebindable: the existing hotkey setting picks one modifier key and has no
  shortcut recorder to reuse.
- The menu bar explains when Secure Input is blocking the keyboard. While
  another app holds it — Terminal's Secure Keyboard Entry, a password manager
  that never let go — macOS keeps keystrokes from the app and the hotkey just
  stopped responding. After five seconds the glyph turns ⚠️ and the menu names
  the app holding it. A password field's brief hold is not mentioned.
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
  the emoji picker on most Macs. It takes exactly four things: `fn` itself,
  `Space` while `fn` is held, `Escape` during a dictation, and `⌃⌘V` once there
  is a transcript to paste again.
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
- When the hotkey cannot arm, the log records the designated requirement the
  app is signed with. Permission grants are keyed to it, so a build signed by a
  different identity — granted in System Settings, refused anyway — can now be
  told apart from a real denial in Console.
- Snippets expand after cleanup instead of before it, so an address, a sign-off
  or a link arrives exactly as you wrote it rather than tidied like speech. A
  trigger still matches when cleanup has put a comma or a dash between its
  words — "best regards sukrit" is found in "Best regards, Sukrit." — but never
  across a sentence end or a line break, and punctuation that is part of the
  trigger itself (":shrug:", "--sig") is still required. Dictionary
  corrections still run first, and still match exactly, so cleanup works on
  the right words.

### Removed

- The failure sound. A dictation that failed is explained in words by the panel
  dropping out of the notch, which a tone cannot do.
- Menu bar item showing permission state, with links into System Settings.
- Launch at login.
- Design spec for the notch-based dictation app.
- Repository scaffolding: gitignore, readme, versioning convention.

### Fixed

- Dictation no longer comes back empty when you have custom words, or when
  "Use what's on screen" finds text in the field. Either one gives the speech
  model a prompt, and the speech library (WhisperKit 0.x) could end a prompted
  transcript before its first word; it is now WhisperKit 1.1, which fixes that.
  Custom words are also handed over the way Whisper expects, so
  `fetchUserProfile` lands as written rather than as "FetchUserProfile".
- A take the microphone heard nothing in now says so, instead of pasting the
  "you" or "Thank you." the speech model invents for silence — words it was
  more likely to invent with custom words or screen text to lean on. Below
  the level the app already logs as effectively silent, a take is not
  transcribed at all.
- The first words of a dictation are no longer clipped when the app being
  dictated into is slow to answer. The microphone starts the instant the key
  goes down; reading the field for context now happens after it, off the main
  thread, and every Accessibility call in that read shares one quarter-second
  budget instead of each getting its own.
- The event tap runs on a thread of its own instead of the main one, so nothing
  else the app does can sit in the path of keystrokes. A tap macOS switches off
  is re-enabled — at once when macOS says so, within two seconds when it does
  not — and rebuilt if it keeps happening. A rebuild that fails is retried with
  backoff and shows ⚠️ in the menu bar until it succeeds, instead of leaving the
  hotkey silently dead. After a disable, a rebuild or wake — when a key release
  could have been missed — the hardware is asked whether the key is still down,
  so a lost release no longer leaves a dictation recording until the
  five-minute cap. Ordinary holds are never second-guessed.
- Pasting works on Dvorak and other layouts that move the V key. The synthetic
  ⌘V used to press whichever key sits where QWERTY's V is — ⌘K on Dvorak. It
  now presses the key that types "v" with ⌘ held on the current layout.
- A dictation pastes into the field it started in, even if focus moved to
  another field or tab of the same app while it was transcribing. The focused
  element and its caret are remembered at key-down; before ⌘V the field is
  focused again and the caret put back, because focusing a single-line field
  selects all of it and the paste would replace it. If the caret is unknown or
  the field is gone, focus is left where it is and the paste goes there; if the
  field will not take focus or the caret will not go back, the selection is
  collapsed and the text stays on the clipboard instead.
- Dictations no longer land in clipboard-manager history. The text staged for a
  paste is marked transient and concealed, the nspasteboard.org convention that
  clipboard managers honour. Copy-only results stay unmarked, since that text is
  meant to stay on the clipboard.
- "Done" no longer appears for a paste that was read but never arrived — a
  field that cannot take text, or a clipboard manager answering in the target's
  place. The field the paste was aimed at is measured — its length and
  selection, before and after, for up to half a second, and only while it holds
  the app's focus. If neither moved, the text stays on the clipboard and the
  notch says so. Anything uncertain — an empty field, a field that lost focus,
  one that cannot be read — counts as pasted, since a false "copied" invites a
  second paste. The field's text is never read for this.

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
