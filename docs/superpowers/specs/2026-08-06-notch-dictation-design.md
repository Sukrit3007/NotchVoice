# NotchVoice — Design

**Date:** 2026-08-06
**Status:** Approved, ready for planning

---

## 1. What this is

A background macOS app for voice dictation. Hold a modifier key, speak, release — the
transcribed text is pasted into whatever text field had focus.

The differentiator is placement. Wispr Flow and voicebox both put their status UI in a
floating panel (bottom of screen, top-center overlay). This app puts it **in the MacBook
notch**, expanding and collapsing like the iPhone Dynamic Island. On displays without a
notch it renders as a HUD matching the system volume meter.

Everything runs on-device. No network calls at runtime.

## 2. Non-goals

- Text-to-speech, voice cloning, agent voice output — voicebox's other half. Out of scope.
- Live/streaming transcription. Batch only (see §4).
- Cross-platform. macOS 26+ only.
- Distribution to other users. Personal tool; no notarization, Sparkle updater, or
  onboarding polish beyond the permission gates.
- A general-purpose island hosting music/battery/AirDrop. Dictation only.

## 3. Reference implementations

Two open-source projects were read in detail. Neither is forked; specific techniques are
reused.

**jamiepine/voicebox** (MIT) — the dictation pipeline. Reused: focus-capture-before-UI
ordering, the clipboard save → write → paste → conditional-restore sequence with its
`changeCount` guard, and the permission-gating structure. Not reused: its Python/FastAPI
sidecar (needed only because it also ships 7 TTS engines), its webview-based mic capture,
and its Rust `keytap` crate.

**BadRat-in/MacIsland** (MPL-2.0) — notch geometry and window technique only, ~150 lines
worth, rewritten rather than copied:

- Notch rect from `NSScreen.safeAreaInsets.top` plus `auxiliaryTopLeftArea` /
  `auxiliaryTopRightArea` widths.
- Borderless transparent `NSWindow`, `level = .statusBar + 8`, `collectionBehavior =
  [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]` — sits above the
  menu bar and follows the user across Spaces and fullscreen apps.
- A fixed-height strip window across the top of the screen; the island is a SwiftUI shape
  inside it that animates size and corner radius.

MacIsland's approach of faking a notch on external displays is **explicitly rejected** —
see §7.

## 4. Decisions

Each was chosen deliberately; rationale recorded so they can be revisited knowingly.

| Decision | Choice | Why |
|---|---|---|
| Speech engine | WhisperKit (`argmaxinc/argmax-oss-swift`) | Native Swift, CoreML/ANE accelerated, in-process. No Python sidecar. |
| Transcription mode | Batch — record while held, transcribe on release | Simpler and more accurate than streaming. ~1.5s wait is acceptable. |
| Model residency | Always loaded | Every dictation is fast, no exceptions. Costs ~1GB resident permanently. Accepted. |
| Activation | Single modifier key, hold to talk | Modifiers alone are inert in every app, so the key tap can be observe-only. |
| Lock mode | Double-tap the same key | Hands-free for long-form without a second binding to learn. |
| Key tap | Observe-only `CGEventTap` on `.flagsChanged` | Never intercepts or swallows a keystroke. Cannot wedge system typing. |
| Bindable keys | Modifiers only | Consequence of observe-only. Arbitrary keys would require a consuming tap. |
| Text delivery | Clipboard round-trip + synthetic ⌘V | Works in Electron, terminals, and custom text engines where AX insertion fails. |
| Delivery fallback | Copy-only when Accessibility not granted | App stays useful before the permission is granted. |
| Refinement LLM | Apple Foundation Models | On-device, system-provided. Zero download, zero bundle size, no second runtime. |
| Non-notch display | Match the system volume HUD | Native-feeling. Faking a notch on a notchless screen looks wrong. |
| Process model | Single process, no XPC split | Crash isolation isn't worth the complexity for a personal tool. |

### Note on the model-residency choice

~1GB held permanently on a 16GB machine that also runs Xcode. This was chosen with the
tradeoff stated. If memory pressure becomes a real problem in daily use, the fallback is
idle eviction (unload after N minutes without a dictation, reload on next use) — a
contained change to `ModelManager`, not a redesign.

## 5. Interaction model

```
right-⌥ held ─────────────────────────► island expands, live waveform
       released ──────────────────────► "transcribing…"  ~1.5s
                                      ► text pasted at the cursor

right-⌥ double-tapped ────────────────► recording LOCKS (hands-free)
       tapped again ──────────────────► stop, transcribe, paste
```

Default binding: **right-Option**. Rebindable in Settings to right-⌘, right-⇧, right-⌃, or
a combination. Left- and right-hand variants are distinguished by reading the raw keyCode
from the `.flagsChanged` event (right-⌘ 54, right-⇧ 60, right-⌥ 61, right-⌃ 62).

### State machine

Audio capture starts on **key-down, always** — deciding the gesture first would clip the
first word. The gesture is resolved on key-up:

| Gesture | Resolution |
|---|---|
| Held ≥ 400ms, then released | Push-to-talk. Stop, transcribe, paste. |
| Tapped < 400ms, second tap within 300ms | Lock. Continue recording hands-free. |
| Tapped < 400ms, no second tap | Discard. No transcription, no UI beyond a brief collapse. |
| Any other key pressed while held | **Cancel silently.** Discard audio, hide island. |
| Locked, then key tapped | Stop, transcribe, paste. |
| `Esc` while recording or locked | Cancel. Discard audio. |

**Maximum recording length: 5 minutes.** Locked mode makes it easy to start a session and
walk away; without a cap that becomes an unbounded buffer and a very slow transcription.
On hitting the cap the recording stops itself and transcribes normally, as though the key
had been tapped. The island shows the cap was reached rather than failing silently.

The cancel-on-other-key rule is what makes binding to ⌥ safe: `⌥ + o` still types `ø`,
`⌥ + ←` still jumps a word, and neither produces a stray dictation.

## 6. UI states

| State | Notch display | Non-notch display |
|---|---|---|
| dormant | invisible; notch looks normal | nothing on screen |
| recording | expanded, mic icon + live waveform | volume-HUD-style capsule, same contents |
| locked | as recording, plus a lock indicator | as recording, plus a lock indicator |
| transcribing | spinner | spinner |
| done | ✓, then collapses | ✓, then fades |
| error / permission needed | tappable message, opens System Settings | same |

### Recording indicator

```
╭──────────────────────────────╮
│   ◉   ▎▊▅▉▂▇▆▊▃▉▅▂▇▎        │
╰──────────────────────────────╯
    ↑         ↑
  mic      live waveform — no timer
```

Mic icon left, waveform filling the remainder. **No numeric timer.**

The bars are driven by real microphone amplitude, not a decorative animation: each bar is a
recent RMS sample, scrolling right to left. Silence reads flat, speech reads tall. This
doubles as the "is it actually hearing me?" signal.

Exact bar count, spacing, corner radius and material are to be matched visually against the
reference screenshot and the live system volume HUD during implementation, rather than
guessed from a description.

## 7. Display handling

- **Screen has a notch** → use the real notch. Geometry from `safeAreaInsets` and the
  auxiliary top areas.
- **Screen has no notch** → render a HUD matching the running macOS version's volume meter
  in position, size, corner radius, material, and animation curve.

Explicitly not doing: drawing a fake notch on a notchless display.

The look must be verified against the real system HUD during implementation (trigger a
volume change, screenshot, match) — not reproduced from memory.

Island follows the screen the user is working on. Display connect/disconnect and
`NSApplication.didChangeScreenParametersNotification` rebuild the window against the new
screen set.

## 8. Pipeline

```
right-⌥ down
  │
  ├─ FocusSnapshot: capture target PID + bundle id  ◄── BEFORE any UI appears
  │
  ├─ MicRecorder: AVAudioEngine → 16kHz mono Float32
  │    └─ LevelMeter taps the same buffer → drives waveform bars
  │
  └─ on release / lock-stop:
       │
       ├─ WhisperKitService.transcribe(audioArray:)          ~1.5s
       │    └─ DecodingOptions carries the vocabulary bias prompt
       │
       ├─ FoundationModelRefiner.refine(text)                ~0.3s
       │    └─ skipped if Apple Intelligence unavailable
       │
       ├─ Paster.deliver(text, focus)
       │    ├─ Accessibility granted → clipboard round-trip + ⌘V
       │    └─ not granted          → copy only, island shows "press ⌘V"
       │
       └─ CaptureStore.save(audio, raw, refined)
```

Focus is captured **before** the island is shown. Showing a window first risks the AX
focus reading resolving to the wrong target.

### Clipboard round-trip

1. Activate the captured PID, brief settle delay.
2. Snapshot the full multi-type pasteboard (every UTI plus raw data, not just plain text).
3. Write the transcript; record `NSPasteboard.changeCount`.
4. Post synthetic ⌘V via `CGEventPost`; wait for the target to consume it.
5. Restore the original clipboard **only if `changeCount` is unchanged.** If something else
   wrote in the interim — the user's own ⌘C, a clipboard manager, Universal Clipboard —
   their newer content wins and the restore is skipped.

A `changeCount` read failure is treated as "unsafe to restore" — unknown state is safer
than an unconditional overwrite. A failed paste never leaves the clipboard stuck holding
the transcript.

### Failure handling

Every stage can fail. None may fail silently — a dictation that vanishes with no
explanation is worse than one that errors.

| Failure | Behaviour |
|---|---|
| Recording shorter than 0.5s | Discard. Island shows "too short", collapses quickly. |
| Mic returns silence | Transcribe anyway; empty result shows "nothing heard". |
| WhisperKit throws | Island shows the error, tappable to copy details. Audio kept in history for retry. |
| Refinement throws or times out | Fall back to the raw transcript and paste that. Never blocks delivery. |
| Paste fails | Fall back to copy-only, tell the user to press ⌘V. Clipboard still restored per the guard above. |

Refinement is capped at a 2s timeout. It is an enhancement, never a dependency — if it is
slow or unavailable, the raw transcript goes out on time.

## 9. Module layout

```
NotchVoice/
├── App/          AppDelegate, main, menu bar item, launch at login
├── Island/       NotchWindow, NotchWindowController, IslandViewModel,
│                 IslandView, VolumeHUDView, WaveformView
├── Input/        ModifierTap (observe-only CGEventTap), BindingStore,
│                 RecordingStateMachine
├── Audio/        MicRecorder, LevelMeter
├── Transcribe/   WhisperKitService, ModelManager, VocabularyBias
├── Refine/       FoundationModelRefiner
├── Deliver/      FocusSnapshot, Paster
├── History/      CaptureStore (SwiftData), HistoryWindow
└── Settings/     SettingsWindow, KeyPickerView, VocabularyEditor
```

Each module has one job and a narrow interface. `RecordingStateMachine` is pure logic with
no AppKit dependency so it can be unit tested directly. `Paster` and `FocusSnapshot` are
the only modules touching AX or synthetic events.

## 10. Permissions

Requested through a first-run flow with deep links into the relevant System Settings pane.

| Permission | Needed for | Without it |
|---|---|---|
| Microphone | Recording | Hard requirement — app cannot function |
| Input Monitoring | Noticing the modifier key | Hotkey silently never fires |
| Accessibility | Auto-paste | Falls back to copy-only |
| Apple Intelligence enabled | LLM refinement | Raw transcript pasted, refinement skipped |

Only Microphone and Input Monitoring are hard requirements. The other two degrade
gracefully and the island explains what is missing and how to fix it.

**Build note:** TCC grants are keyed to code-signing identity. The project must use a
stable signing identity from the first build, or macOS will silently revoke Accessibility
and Input Monitoring on every rebuild.

## 11. Data model

`Capture` (SwiftData):

| Field | Notes |
|---|---|
| `id` | UUID |
| `createdAt` | Date |
| `audioURL` | file in app support dir |
| `transcriptRaw` | Whisper output |
| `transcriptRefined` | LLM output, nil when refinement was skipped |
| `durationSeconds` | Double |
| `targetBundleID` | where it was pasted, nil if copy-only |
| `modelUsed` | Whisper variant |

Audio is retained so a capture can be re-transcribed with a different model, or promoted
into the vocabulary list when a term is consistently mangled.

## 12. Build order

Sequenced so a usable daily driver exists before the extras land.

1. **Core loop** — key tap, state machine, mic capture, WhisperKit, clipboard paste, island
   with all states, menu bar item, launch at login. Ships as a working dictation app.
2. **Refinement** — Foundation Models cleanup with the availability gate.
3. **Vocabulary bias** — Settings list, wired into `DecodingOptions`.
4. **History** — SwiftData store and browser window.

Milestone 1 is the bulk of the risk (permissions, event tap, focus capture, paste
reliability). 2–4 are additive and independently shippable.

## 13. Verification

Automated, limited to logic worth testing:

- `RecordingStateMachine` — hold, double-tap lock, short-tap discard, cancel-on-other-key,
  Esc cancel. This is the fiddliest logic in the app.
- Clipboard guard — restore happens when `changeCount` matches, is skipped when it does
  not, and is skipped when the read fails.

Manual, per milestone:

- Dictate into Slack, Cursor, Terminal, Safari, and Xcode.
- Laptop screen and external monitor; connect and disconnect mid-session.
- Confirm `⌥ + o` still types `ø` and `⌥ + ←` still jumps a word, with no stray dictation.
- Revoke Accessibility, confirm copy-only fallback and its message.
- Disable Apple Intelligence, confirm raw transcript still pastes.
- Confirm clipboard contents survive a dictation.

## 14. Open questions

None blocking. Two items deferred to implementation, both to be resolved by matching real
UI rather than by decision:

- Exact volume-HUD geometry and material on macOS 27.
- Waveform bar count, spacing and corner radius against the reference screenshot.
