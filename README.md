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

## Releasing

```
Tools/release.sh 0.1.1
```

Builds, signs, packages a `.dmg`, publishes a GitHub release, and adds an entry
to `appcast.xml` so copies already installed find it. The release is created
before the appcast that names its URL is pushed, so nothing ever points at a
download that does not exist yet.

Release notes come from `CHANGELOG.md` — a version with no section there cannot
be released, which is deliberate.

### The two secrets

Neither is in this repository and neither can be recovered from it.

| | Losing it means |
|---|---|
| The **Notch Voice Developer** certificate | A replacement changes the app's designated requirement. Microphone, Accessibility and Input Monitoring reset for every existing user, on the update that ships it, with no warning and no explanation |
| Sparkle's **EdDSA private key** | No future update can be signed in a way installed copies will accept. Everyone has to download the app by hand again |

Created once by `Tools/make-cert.sh`, exported by `Tools/backup-secrets.sh`.
`Tools/release.sh` prints the designated requirement on every run; it must match
the one recorded in [`docs/versioning.md`](docs/versioning.md) exactly.

### Updates are verified, first launch is not

Gatekeeper cannot check an app that was never notarized, which is why the first
launch needs **Open Anyway**. Every update after that is checked properly:
Sparkle verifies the download is signed by the same identity as the copy already
running, and refuses it otherwise. The weak moment is the first install only.

## Versioning

Semantic versioning, tracked with annotated git tags. See [CHANGELOG.md](CHANGELOG.md) and
[`docs/versioning.md`](docs/versioning.md).

## Prior art

Two open-source projects were studied during design; neither is forked.

- [jamiepine/voicebox](https://github.com/jamiepine/voicebox) (MIT) — dictation pipeline,
  clipboard-restore guard, permission gating.
- [BadRat-in/MacIsland](https://github.com/BadRat-in/MacIsland) (MPL-2.0) — notch geometry
  and overlay-window technique.
