# Notch Voice

On-device voice dictation for macOS, living in the MacBook notch.

> The app is **Notch Voice**, `.app` filename and executable included. The
> repository, Xcode target and bundle identifier stay `NotchVoice` /
> `com.sukrit.notchvoice` — reverse-DNS identifiers do not take spaces, and that
> identifier keys both the TCC grants and `UserDefaults`. Renaming the bundle
> without moving the identifier turned out to preserve the permission grants.

Hold `fn`, speak, release — the transcribed text is tidied up and pasted into whatever text
field had focus. Status shows in the notch, expanding and collapsing like the iPhone
Dynamic Island, with a panel dropping out of it when there is more to say than a wing can
hold. Every display draws the same silhouette.

**Your voice never leaves your Mac.** Audio is transcribed on-device and discarded;
transcripts are stored locally and never uploaded. There is no account, no telemetry and
no server.

The app uses the network to fetch models from Hugging Face, and for nothing else. The
speech model (~630MB) comes down on first launch; the optional cleanup model (2.3GB) only
if you ask for it in Settings. Both are file downloads that carry nothing about you, and
both land under `~/Library/Application Support/com.sukrit.notchvoice/`. Between
downloads the app works offline forever.

## Status

Core dictation loop built and awaiting hardware acceptance.

| | |
|---|---|
| Dictate | hold `fn` |
| Hands-free | `fn`+`Space`, then `fn` again to finish |
| Cancel | `Escape` |

Every automated check passes — 152 unit tests and a clean Release build. The
acceptance matrix in the milestone plan has not been run: nothing here has been
driven by a human speaking into a microphone. `v0.1.0` is tagged when it has.

**`fn` is reserved while the app runs.** Holding it starts a dictation instead of
doing whatever macOS would otherwise do with the Globe key, because the event tap
consumes it. `fn` in combination — `fn`+`Delete`, `fn`+arrows — is untouched. The
binding can be changed to a right-hand modifier in Settings, and falls back to one
automatically on keyboards with no `fn` key.

Next: a library window (history, custom words, snippets, stats), first-run onboarding,
and a signed `.dmg` with auto-update. See
[`docs/superpowers/specs/2026-08-06-notch-dictation-design.md`](docs/superpowers/specs/2026-08-06-notch-dictation-design.md).

## Stack

| Layer | Technology |
|---|---|
| App shell | Swift, SwiftUI, AppKit |
| Speech-to-text | WhisperKit (CoreML / Apple Neural Engine) |
| Transcript cleanup | Apple Foundation Models (on-device, system-provided) |
| Better cleanup, optional | Qwen3-4B via MLX — downloaded on request, see Cleanup in Settings |
| Hotkey | `CGEventTap`, consuming — see below |
| Text delivery | `NSPasteboard` round-trip + synthetic ⌘V |
| Feedback cues | Generated, not recorded — `Tools/SoundGen` |

## Requirements

- macOS 26 or later
- Apple Silicon
- Xcode 26+, plus the Metal Toolchain component:
  `xcodebuild -downloadComponent MetalToolchain` (839MB, one-time)

MLX compiles its Metal shaders from source, and Xcode 26 no longer ships that
compiler by default. Builds also need `-skipPackagePluginValidation`, because
`mlx-swift` carries a build-tool plugin Xcode declines to run unattended:

```
xcodebuild build -scheme NotchVoice -skipPackagePluginValidation
```

## Permissions

| Permission | Needed for | Without it |
|---|---|---|
| Microphone | Recording | Hard requirement |
| Input Monitoring | Seeing the hotkey | Hotkey never fires |
| Accessibility | Reserving the hotkey, and pasting | Hotkey never fires |
| Apple Intelligence | Transcript cleanup | Raw transcript is pasted, unless the local cleanup model is installed |

Accessibility is required, not optional. A tap that only *observes* events needs
Input Monitoring alone, but reserving `fn` means **consuming** the keypress, and
macOS only permits that with Accessibility.

## Tests

| Suite | Runs with | Covers |
|---|---|---|
| `Core/Tests` | `cd Core && swift test` | Pure logic — state machine, geometry, clipboard guard, island metrics, cleanup guards |
| `AppTests` | `xcodebuild test -scheme NotchVoice -skipPackagePluginValidation` | Anything needing AppKit, SwiftData or the built bundle — the store, cue assets, failure copy against the wing it has to fit |
| `Tools/SoundGen/Tests` | `cd Tools/SoundGen && swift test` | The cue synthesiser — click-freedom, envelope, level bounds |

`AppTests` is hosted in the app so `Bundle.main` is the real bundle. The app
detects it is hosting tests and skips starting its pipeline — otherwise every
test run would arm a consuming `fn` tap and download the speech model.

Two launch flags for working on the UI, neither of which starts the pipeline:

- `--window-only` opens the library window without arming the tap or loading the model.
- `--onboarding` replays the first-run flow without marking it complete.

## Note for the download page

The first thing a new user meets is **not** in this app — it is macOS refusing to
open it, because the build is self-signed rather than notarized. That explanation
belongs on the download page, before the first launch:

> macOS will say it can't verify the app. Open **System Settings → Privacy &
> Security**, scroll down, and click **Open Anyway**.

Deliberately not an onboarding screen: by the time any code in the app runs, the
user is already past Gatekeeper, and explaining a dialog they cleared thirty
seconds ago teaches them nothing.

## Versioning

Semantic versioning, tracked with annotated git tags. See [CHANGELOG.md](CHANGELOG.md) and
[`docs/versioning.md`](docs/versioning.md).

## Prior art

Two open-source projects were studied during design; neither is forked.

- [jamiepine/voicebox](https://github.com/jamiepine/voicebox) (MIT) — dictation pipeline,
  clipboard-restore guard, permission gating.
- [BadRat-in/MacIsland](https://github.com/BadRat-in/MacIsland) (MPL-2.0) — notch geometry
  and overlay-window technique.
