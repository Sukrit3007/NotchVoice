# AGENTS.md

Notch Voice is a local macOS dictation app that lives in the MacBook notch. Hold
`fn`, speak, release. WhisperKit transcribes on-device. Apple Foundation Models, or
an optional local Qwen model via MLX, tidies the transcript. The text is then
pasted into the app that had focus when dictation started. It has no account,
no server and no telemetry. `App/` is the AppKit/SwiftUI app, `Core/` is a pure
Swift package with the logic, and `Tools/` holds the cue synthesiser, the
benchmark and the release scripts.

Read [`CONTEXT.md`](CONTEXT.md) first: it defines the domain terms (Dictation,
Notch Surface, Processing, Copy-only Delivery, …) that the code and the docs use.

## Build, test, run

```sh
# one-time
xcodebuild -downloadComponent MetalToolchain       # MLX shaders, ~839 MB

# generate + build (project.yml is the source of truth; the .xcodeproj is generated)
xcodegen generate
xcodebuild build -scheme NotchVoice -skipPackagePluginValidation
#   add -derivedDataPath build/dd → app at "build/dd/Build/Products/Debug/Notch Voice.app"

# tests
swift test --package-path Core
swift test --package-path Tools/SoundGen
xcodebuild test -scheme NotchVoice -skipPackagePluginValidation
xcodebuild test -scheme NotchVoice -skipPackagePluginValidation \
  -only-testing:NotchVoiceTests/CaptureStoreTests      # one suite

# pipeline latency + accuracy (speech model installed, app quit)
Tools/Bench/run.sh

# run without the pipeline
"…/Notch Voice.app/Contents/MacOS/Notch Voice" --window-only   # library window only
"…/Notch Voice.app/Contents/MacOS/Notch Voice" --onboarding    # replay first run

# logs (speech-derived text is .private)
log stream --predicate 'subsystem == "com.sukrit.notchvoice"'

# release
Tools/release.sh --dry-run 0.1.1   # validate version + CHANGELOG only
Tools/release.sh 0.1.1
```

CI (`.github/workflows/ci.yml`) runs only the Core and SoundGen tests. Run the
app build and AppTests locally.

Gotchas:
- Never run `xcodegen generate` while the project is open in Xcode. If you do,
  `xcodebuild` hangs.
- Keep signing as `project.yml` sets it. TCC grants are keyed to it, and ad-hoc
  signing resets them.
- AppTests are hosted in the app, which skips starting its pipeline under test.

## Rules

- Commit and push straight to `main`. No branches, no PRs.
- Use conventional commits (`feat(scope): …`, `fix:`, `docs:`, `ci:`) with no
  `Co-Authored-By` trailer.
- After adding or removing files, run `xcodegen generate` with Xcode closed.
- On-device by default. Cloud is only ever an opt-in that uses the user's own
  API key, and it is never the default.
- Pure logic lives in `Core`, with swift-testing tests. `App/` keeps the
  AppKit, Accessibility and I/O glue thin.
- Add an entry under `CHANGELOG.md` `[Unreleased]` for every user-visible
  change, in the existing style.
- Pipeline changes cover audio, transcription, cleanup, rewrites and delivery.
  For any of them, re-run `Tools/Bench/run.sh` and update `docs/benchmarks/`.
- Record architectural decisions as numbered ADRs in `docs/adr/`.
- Never touch `Vendor/`.
- Text read from other apps is never stored, sent or logged, and password
  fields are never read.
- A failed enhancement (context, cleanup, rewrites) must never block or fail a
  dictation. Fall back to the raw transcript.
