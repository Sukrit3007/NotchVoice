# NotchVoice

On-device voice dictation for macOS, living in the MacBook notch.

Hold a modifier key, speak, release — the transcribed text is pasted into whatever text
field had focus. Status shows in the notch, expanding and collapsing like the iPhone
Dynamic Island. On displays without a notch it renders as a HUD matching the system volume
meter.

Everything runs locally. No network calls at runtime.

## Status

Core dictation loop built and awaiting hardware acceptance. Hold right-Option,
speak, release.

Every automated check passes — 39 unit tests, clean Release build, and the
runtime pieces that can be measured from outside the process (window placement,
permission state, model load, notch geometry). The acceptance matrix in the
milestone plan has not been run yet: nothing here has been driven by a human
speaking into a microphone. `v0.1.0` is tagged when it has.

Next: transcript cleanup via Foundation Models (0.2.0), custom vocabulary bias
(0.3.0), transcript history (0.4.0). See
[`docs/superpowers/specs/2026-08-06-notch-dictation-design.md`](docs/superpowers/specs/2026-08-06-notch-dictation-design.md).

## Stack

| Layer | Technology |
|---|---|
| App shell | Swift, SwiftUI, AppKit |
| Speech-to-text | WhisperKit (CoreML / Apple Neural Engine) |
| Transcript cleanup | Apple Foundation Models (on-device, system-provided) |
| Hotkey | `CGEventTap`, observe-only |
| Text delivery | `NSPasteboard` round-trip + synthetic ⌘V |
| History | SwiftData |

## Requirements

- macOS 26 or later
- Apple Silicon
- Xcode 26+

## Permissions

| Permission | Needed for | Without it |
|---|---|---|
| Microphone | Recording | Hard requirement |
| Input Monitoring | Noticing the hotkey | Hotkey never fires |
| Accessibility | Auto-paste | Falls back to copy-only |
| Apple Intelligence | Transcript cleanup | Raw transcript is pasted |

## Versioning

Semantic versioning, tracked with annotated git tags. See [CHANGELOG.md](CHANGELOG.md) and
[`docs/versioning.md`](docs/versioning.md).

## Prior art

Two open-source projects were studied during design; neither is forked.

- [jamiepine/voicebox](https://github.com/jamiepine/voicebox) (MIT) — dictation pipeline,
  clipboard-restore guard, permission gating.
- [BadRat-in/MacIsland](https://github.com/BadRat-in/MacIsland) (MPL-2.0) — notch geometry
  and overlay-window technique.
