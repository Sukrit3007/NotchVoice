# NotchVoice Milestone 1 — Core Dictation Loop

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hold right-Option, speak, release — transcribed text is pasted into whatever text field had focus, with status shown in the MacBook notch.

**Architecture:** A single non-sandboxed macOS app (`LSUIElement`, no dock icon). All pure logic — the gesture state machine, notch geometry, waveform buffering, the clipboard-restore decision — lives in a local SwiftPM package `NotchVoiceCore` so it can be unit tested with a fast `swift test` cycle. The app target holds everything that touches AppKit, AVFoundation, CoreGraphics event taps, or the Accessibility API, and is verified manually. A single `DictationCoordinator` owns the wiring between them.

**Tech Stack:** Swift 6, SwiftUI + AppKit, WhisperKit (CoreML/ANE), XcodeGen for project generation, Swift Testing for unit tests.

## Global Constraints

- **Platform floor:** macOS 26.0. Apple Silicon only.
- **App sandbox MUST be disabled.** `AXUIElement` cross-process reads, `CGEventPost`, and `CGEventTap` all fail silently under the sandbox. This is not negotiable and not a shortcut.
- **Hardened runtime ON**, with `com.apple.security.device.audio-input`.
- **Stable code-signing identity from the first build.** TCC grants (Accessibility, Input Monitoring) are keyed to the signature. Ad-hoc signing causes macOS to revoke permissions on every rebuild, which will look like a bug in your code and waste hours.
- **The event tap is observe-only.** It reads `.flagsChanged` and returns the event unmodified, always. It must never consume, swallow, or synthesise an event.
- **No network calls at runtime.** The only network access permitted is the one-time WhisperKit model download.
- **Timing constants** (from spec §5): hold threshold `0.4s`, double-tap window `0.3s`, minimum recording `0.5s`, maximum recording `300s`.
- **Modifier keycodes:** right-Command `54`, right-Shift `60`, right-Option `61`, right-Control `62`.
- **Default binding:** right-Option.
- **Commits:** conventional prefixes (`feat:`, `test:`, `chore:`, `docs:`). Author is Sukrit — do NOT add any `Co-Authored-By` trailer.

## File Structure

```
NotchVoice/
├── project.yml                      XcodeGen project definition
├── Core/                            SwiftPM package — pure logic, unit tested
│   ├── Package.swift
│   ├── Sources/NotchVoiceCore/
│   │   ├── RecordingStateMachine.swift
│   │   ├── ModifierKey.swift
│   │   ├── ClipboardGuard.swift
│   │   ├── LevelBuffer.swift
│   │   └── NotchGeometry.swift
│   └── Tests/NotchVoiceCoreTests/
│       ├── RecordingStateMachineTests.swift
│       ├── ClipboardGuardTests.swift
│       ├── LevelBufferTests.swift
│       └── NotchGeometryTests.swift
└── App/                             app target — AppKit / AVFoundation / CG / AX
    ├── Info.plist
    ├── NotchVoice.entitlements
    ├── App/
    │   ├── NotchVoiceApp.swift       @main, AppDelegate
    │   ├── MenuBarController.swift
    │   └── LaunchAtLogin.swift
    ├── Input/
    │   ├── ModifierTap.swift         observe-only CGEventTap
    │   └── BindingStore.swift
    ├── Audio/
    │   └── MicRecorder.swift         AVAudioEngine → 16kHz mono Float32
    ├── Transcribe/
    │   └── WhisperKitService.swift
    ├── Deliver/
    │   ├── FocusSnapshot.swift       AX read of focused app
    │   └── Paster.swift              clipboard round-trip + synthetic ⌘V
    ├── Island/
    │   ├── IslandWindow.swift
    │   ├── IslandWindowController.swift
    │   ├── IslandViewModel.swift
    │   ├── IslandView.swift
    │   ├── WaveformView.swift
    │   └── HUDView.swift             non-notch fallback
    ├── Permissions/
    │   └── PermissionChecker.swift
    └── DictationCoordinator.swift    wires everything together
```

`Core` is where the fiddly logic lives and where all the tests are. The app target has one job per file and no business logic worth testing in isolation.

---

## Task 1: Project scaffolding

**Files:**
- Create: `project.yml`
- Create: `Core/Package.swift`
- Create: `Core/Sources/NotchVoiceCore/NotchVoiceCore.swift`
- Create: `App/Info.plist`
- Create: `App/NotchVoice.entitlements`
- Create: `App/App/NotchVoiceApp.swift`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing
- Produces: a buildable, launchable app. Later tasks add files under `App/` and `Core/Sources/NotchVoiceCore/` and they are picked up automatically by the `sources` globs.

- [ ] **Step 1: Install XcodeGen**

The `.xcodeproj` is generated from `project.yml`, never hand-edited and never committed. This keeps project config reviewable as a diff.

```bash
brew install xcodegen
xcodegen --version
```

- [ ] **Step 2: Find the code-signing team ID**

TCC permissions are keyed to the signing identity. Run this and note the team ID in parentheses:

```bash
security find-identity -v -p codesigning
```

Expected: at least one `Apple Development: ... (TEAMID)` line. If there are none, open Xcode → Settings → Accounts, add your Apple ID, and let it create a personal development certificate. Do not proceed without one — ad-hoc signing will cause macOS to revoke Accessibility and Input Monitoring on every rebuild.

- [ ] **Step 3: Write the Core package manifest**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchVoiceCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NotchVoiceCore", targets: ["NotchVoiceCore"]),
    ],
    targets: [
        .target(name: "NotchVoiceCore"),
        .testTarget(name: "NotchVoiceCoreTests", dependencies: ["NotchVoiceCore"]),
    ]
)
```

- [ ] **Step 4: Add a placeholder source so the package compiles**

`Core/Sources/NotchVoiceCore/NotchVoiceCore.swift`:

```swift
/// Namespace for shared constants used across the app.
public enum NotchVoice {
    /// Bundle identifier of the app itself. Used to short-circuit auto-paste
    /// when NotchVoice is the frontmost app.
    public static let bundleID = "com.sukrit.notchvoice"
}
```

- [ ] **Step 5: Verify the package builds and tests run**

```bash
cd Core && swift build && swift test
```

Expected: builds clean. `swift test` reports 0 tests — that is correct at this point.

- [ ] **Step 6: Write the XcodeGen project definition**

`project.yml`. Replace `TEAMID` with the value from Step 2.

```yaml
name: NotchVoice
options:
  bundleIdPrefix: com.sukrit
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true

packages:
  WhisperKit:
    url: https://github.com/argmaxinc/argmax-oss-swift.git
    from: 0.9.0
  NotchVoiceCore:
    path: Core

targets:
  NotchVoice:
    type: application
    platform: macOS
    sources:
      - path: App
        excludes:
          - "Info.plist"
          - "NotchVoice.entitlements"
    dependencies:
      - package: WhisperKit
        product: WhisperKit
      - package: NotchVoiceCore
        product: NotchVoiceCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.sukrit.notchvoice
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: TEAMID
        ENABLE_HARDENED_RUNTIME: YES
        INFOPLIST_FILE: App/Info.plist
        CODE_SIGN_ENTITLEMENTS: App/NotchVoice.entitlements
        MACOSX_DEPLOYMENT_TARGET: "26.0"
```

If the build in Step 9 fails with "no such product 'WhisperKit'", list the package's actual products with `swift package --package-path .build/checkouts/argmax-oss-swift describe` and use the correct name. The package is a monorepo containing WhisperKit alongside other kits, so the product name is worth confirming rather than assuming.

- [ ] **Step 7: Write Info.plist**

`App/Info.plist`. `LSUIElement` is what makes this a background app with no dock icon.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>NotchVoice records audio only while you hold the dictation key, and transcribes it on your Mac.</string>
</dict>
</plist>
```

- [ ] **Step 8: Write the entitlements file**

`App/NotchVoice.entitlements`. The sandbox key is deliberately `false` — see Global Constraints.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 9: Write a minimal app entry point**

`App/App/NotchVoiceApp.swift`:

```swift
import AppKit

@main
final class NotchVoiceApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = NotchVoiceApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[NotchVoice] launched")
    }
}
```

- [ ] **Step 10: Generate the project and build**

```bash
xcodegen generate
xcodebuild -project NotchVoice.xcodeproj -scheme NotchVoice -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. First run resolves the WhisperKit package, which takes a few minutes.

- [ ] **Step 11: Launch it and confirm it runs headless**

```bash
open ~/Library/Developer/Xcode/DerivedData/NotchVoice-*/Build/Products/Debug/NotchVoice.app
sleep 2
pgrep -l NotchVoice
```

Expected: `pgrep` prints a PID, and **no dock icon appears**. Quit it with `pkill NotchVoice`.

- [ ] **Step 12: Ignore generated project files**

Append to `.gitignore`:

```
# Generated by XcodeGen — project.yml is the source of truth
*.xcodeproj/
```

- [ ] **Step 13: Commit**

```bash
git add project.yml Core App .gitignore
git commit -m "chore: project scaffolding with XcodeGen and Core package"
```

---

## Task 2: Recording state machine

The fiddliest logic in the app, and the only part where a subtle bug produces stray dictations in the middle of someone's work. Pure logic, no AppKit, fully tested.

**Files:**
- Create: `Core/Sources/NotchVoiceCore/RecordingStateMachine.swift`
- Test: `Core/Tests/NotchVoiceCoreTests/RecordingStateMachineTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `RecordingStateMachine.State` — `.idle`, `.holding(downAt: TimeInterval)`, `.awaitingSecondTap(firstUpAt: TimeInterval)`, `.locked`
  - `RecordingStateMachine.Event` — `.keyDown(at:)`, `.keyUp(at:)`, `.otherKeyPressed`, `.escapePressed`, `.doubleTapWindowExpired`, `.maxDurationReached`
  - `RecordingStateMachine.Effect` — `.none`, `.startCapture`, `.restartCapture`, `.armDoubleTapTimer`, `.enterLocked`, `.stopAndTranscribe`, `.discard`
  - `mutating func handle(_ event: Event) -> Effect`
  - `var state: State { get }`

- [ ] **Step 1: Write the failing tests**

`Core/Tests/NotchVoiceCoreTests/RecordingStateMachineTests.swift`:

```swift
import Testing
@testable import NotchVoiceCore

@Suite("RecordingStateMachine")
struct RecordingStateMachineTests {

    @Test("key down starts capture")
    func keyDownStartsCapture() {
        var sm = RecordingStateMachine()
        #expect(sm.handle(.keyDown(at: 0)) == .startCapture)
        #expect(sm.state == .holding(downAt: 0))
    }

    @Test("holding past the threshold then releasing transcribes")
    func longHoldTranscribes() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.keyUp(at: 0.9)) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("a quick tap waits for a second tap instead of transcribing")
    func quickTapArmsTimer() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.keyUp(at: 0.1)) == .armDoubleTapTimer)
        #expect(sm.state == .awaitingSecondTap(firstUpAt: 0.1))
    }

    @Test("double tap within the window locks")
    func doubleTapLocks() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        #expect(sm.handle(.keyDown(at: 0.3)) == .enterLocked)
        #expect(sm.state == .locked)
    }

    @Test("a single tap with no follow-up is discarded")
    func singleTapDiscards() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        #expect(sm.handle(.doubleTapWindowExpired) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("a second tap arriving too late starts a fresh hold")
    func lateSecondTapRestarts() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        #expect(sm.handle(.keyDown(at: 5.0)) == .startCapture)
        #expect(sm.state == .holding(downAt: 5.0))
    }

    @Test("pressing another key while held cancels silently")
    func otherKeyCancels() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.otherKeyPressed) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("escape while holding cancels")
    func escapeWhileHoldingCancels() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.escapePressed) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("tapping the key while locked stops and transcribes")
    func tapWhileLockedStops() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        _ = sm.handle(.keyDown(at: 0.3))
        #expect(sm.handle(.keyDown(at: 9.0)) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("the key release that follows a locking tap is ignored")
    func keyUpAfterLockIsIgnored() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        _ = sm.handle(.keyDown(at: 0.3))
        #expect(sm.handle(.keyUp(at: 0.4)) == .none)
        #expect(sm.state == .locked)
    }

    @Test("typing while locked does not cancel — locked is deliberate")
    func otherKeyWhileLockedIsIgnored() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        _ = sm.handle(.keyDown(at: 0.3))
        #expect(sm.handle(.otherKeyPressed) == .none)
        #expect(sm.state == .locked)
    }

    @Test("escape while locked cancels")
    func escapeWhileLockedCancels() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        _ = sm.handle(.keyDown(at: 0.3))
        #expect(sm.handle(.escapePressed) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("hitting the duration cap transcribes rather than discarding")
    func maxDurationTranscribes() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.maxDurationReached) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("hitting the duration cap while locked transcribes")
    func maxDurationWhileLockedTranscribes() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        _ = sm.handle(.keyDown(at: 0.3))
        #expect(sm.handle(.maxDurationReached) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("events arriving in the idle state are ignored")
    func idleIgnoresStrayEvents() {
        var sm = RecordingStateMachine()
        #expect(sm.handle(.keyUp(at: 1)) == .none)
        #expect(sm.handle(.otherKeyPressed) == .none)
        #expect(sm.handle(.escapePressed) == .none)
        #expect(sm.handle(.doubleTapWindowExpired) == .none)
        #expect(sm.state == .idle)
    }

    @Test("thresholds are configurable")
    func customThresholds() {
        var sm = RecordingStateMachine(
            thresholds: .init(hold: 1.0, doubleTap: 0.1)
        )
        _ = sm.handle(.keyDown(at: 0))
        // 0.5s is a long hold by default, but a short tap at this threshold
        #expect(sm.handle(.keyUp(at: 0.5)) == .armDoubleTapTimer)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd Core && swift test
```

Expected: compile failure — `cannot find 'RecordingStateMachine' in scope`.

- [ ] **Step 3: Write the implementation**

`Core/Sources/NotchVoiceCore/RecordingStateMachine.swift`:

```swift
import Foundation

/// Resolves raw key events from the modifier tap into recording effects.
///
/// Capture always starts on key-down, before the gesture is known — deciding
/// first would clip the first word. The gesture is resolved on key-up, and a
/// short tap keeps capturing while it waits to find out whether a second tap
/// is coming.
///
/// Pure logic: no AppKit, no timers, no clock reads. The host supplies
/// timestamps and drives `.doubleTapWindowExpired` and `.maxDurationReached`
/// from its own timers, which is what makes every branch testable.
public struct RecordingStateMachine: Sendable {

    public struct Thresholds: Sendable {
        /// Held at least this long counts as push-to-talk rather than a tap.
        public let hold: TimeInterval
        /// A second tap within this window of the first release locks.
        public let doubleTap: TimeInterval

        public init(hold: TimeInterval = 0.4, doubleTap: TimeInterval = 0.3) {
            self.hold = hold
            self.doubleTap = doubleTap
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Key is down; the gesture is not yet decided.
        case holding(downAt: TimeInterval)
        /// Key was tapped and released quickly. Still capturing while we wait
        /// to see whether a second tap arrives.
        case awaitingSecondTap(firstUpAt: TimeInterval)
        /// Hands-free. Capture continues until the key is tapped again.
        case locked
    }

    public enum Event: Equatable, Sendable {
        case keyDown(at: TimeInterval)
        case keyUp(at: TimeInterval)
        /// Any non-binding key was pressed. Makes `⌥ + o` still type `ø`.
        case otherKeyPressed
        case escapePressed
        case doubleTapWindowExpired
        case maxDurationReached
    }

    public enum Effect: Equatable, Sendable {
        case none
        case startCapture
        /// Keep capturing, and schedule `.doubleTapWindowExpired`.
        case armDoubleTapTimer
        case enterLocked
        case stopAndTranscribe
        /// Throw the audio away. No transcription, no paste.
        case discard
    }

    public private(set) var state: State = .idle
    private let thresholds: Thresholds

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    public mutating func handle(_ event: Event) -> Effect {
        switch (state, event) {

        // --- idle ------------------------------------------------------
        case let (.idle, .keyDown(t)):
            state = .holding(downAt: t)
            return .startCapture

        case (.idle, _):
            return .none

        // --- holding ---------------------------------------------------
        case let (.holding(downAt), .keyUp(t)):
            if t - downAt >= thresholds.hold {
                state = .idle
                return .stopAndTranscribe
            }
            state = .awaitingSecondTap(firstUpAt: t)
            return .armDoubleTapTimer

        case (.holding, .otherKeyPressed), (.holding, .escapePressed):
            state = .idle
            return .discard

        case (.holding, .maxDurationReached):
            state = .idle
            return .stopAndTranscribe

        case (.holding, .keyDown), (.holding, .doubleTapWindowExpired):
            return .none

        // --- awaitingSecondTap -----------------------------------------
        case let (.awaitingSecondTap(firstUpAt), .keyDown(t)):
            if t - firstUpAt <= thresholds.doubleTap {
                state = .locked
                return .enterLocked
            }
            // Too late to be a double tap. The first tap's audio is stale,
            // so this is a fresh hold rather than a continuation.
            state = .holding(downAt: t)
            return .startCapture

        case (.awaitingSecondTap, .doubleTapWindowExpired),
             (.awaitingSecondTap, .otherKeyPressed),
             (.awaitingSecondTap, .escapePressed):
            state = .idle
            return .discard

        case (.awaitingSecondTap, .maxDurationReached):
            state = .idle
            return .stopAndTranscribe

        case (.awaitingSecondTap, .keyUp):
            return .none

        // --- locked ----------------------------------------------------
        case (.locked, .keyDown):
            state = .idle
            return .stopAndTranscribe

        case (.locked, .escapePressed):
            state = .idle
            return .discard

        case (.locked, .maxDurationReached):
            state = .idle
            return .stopAndTranscribe

        // Typing while locked is expected — hands-free is deliberate.
        case (.locked, .keyUp),
             (.locked, .otherKeyPressed),
             (.locked, .doubleTapWindowExpired):
            return .none
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd Core && swift test
```

Expected: 16 tests, all passing.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/NotchVoiceCore/RecordingStateMachine.swift Core/Tests/NotchVoiceCoreTests/RecordingStateMachineTests.swift
git commit -m "feat: recording gesture state machine"
```

---

## Task 3: Modifier key model and clipboard guard

Two small pure types the app layer needs. Grouped because neither justifies its own review cycle.

**Files:**
- Create: `Core/Sources/NotchVoiceCore/ModifierKey.swift`
- Create: `Core/Sources/NotchVoiceCore/ClipboardGuard.swift`
- Test: `Core/Tests/NotchVoiceCoreTests/ClipboardGuardTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `enum ModifierKey: UInt16, CaseIterable, Codable, Sendable` with cases `.rightCommand = 54`, `.rightShift = 60`, `.rightOption = 61`, `.rightControl = 62`; `var displayName: String`; `static let `default`: ModifierKey`
  - `enum ClipboardGuard { static func shouldRestore(changeCountAfterWrite: Int, currentChangeCount: Int?) -> Bool }`

- [ ] **Step 1: Write the failing test**

`Core/Tests/NotchVoiceCoreTests/ClipboardGuardTests.swift`:

```swift
import Testing
@testable import NotchVoiceCore

@Suite("ClipboardGuard")
struct ClipboardGuardTests {

    @Test("restores when nothing else touched the clipboard")
    func restoresWhenUntouched() {
        #expect(ClipboardGuard.shouldRestore(
            changeCountAfterWrite: 42, currentChangeCount: 42) == true)
    }

    @Test("skips restore when something else wrote in the meantime")
    func skipsWhenClobbered() {
        #expect(ClipboardGuard.shouldRestore(
            changeCountAfterWrite: 42, currentChangeCount: 43) == false)
    }

    @Test("skips restore when the change count could not be read")
    func skipsWhenUnknown() {
        // Unknown state is safer than an unconditional overwrite: the user's
        // newer clipboard content is worth more than our snapshot.
        #expect(ClipboardGuard.shouldRestore(
            changeCountAfterWrite: 42, currentChangeCount: nil) == false)
    }

    @Test("a lower change count is still treated as a mismatch")
    func skipsOnLowerCount() {
        #expect(ClipboardGuard.shouldRestore(
            changeCountAfterWrite: 42, currentChangeCount: 41) == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd Core && swift test --filter ClipboardGuard
```

Expected: compile failure — `cannot find 'ClipboardGuard' in scope`.

- [ ] **Step 3: Write ClipboardGuard**

`Core/Sources/NotchVoiceCore/ClipboardGuard.swift`:

```swift
/// Decides whether it is safe to put the user's original clipboard back after
/// a paste.
///
/// `NSPasteboard.changeCount` increments on every mutation from any process.
/// If it still matches the value recorded right after we staged our text,
/// nothing else wrote in the interim and the restore is safe. If it moved —
/// the user's own ⌘C, a clipboard manager, Universal Clipboard — their newer
/// content wins and we leave it alone.
public enum ClipboardGuard {
    public static func shouldRestore(
        changeCountAfterWrite: Int,
        currentChangeCount: Int?
    ) -> Bool {
        guard let current = currentChangeCount else { return false }
        return current == changeCountAfterWrite
    }
}
```

- [ ] **Step 4: Write ModifierKey**

`Core/Sources/NotchVoiceCore/ModifierKey.swift`:

```swift
/// A bindable modifier key, identified by its macOS virtual keycode.
///
/// Only right-hand modifiers are offered. Left-hand variants collide with the
/// shortcuts people already use, and non-modifier keys would require a
/// consuming event tap — see the design spec, §4.
public enum ModifierKey: UInt16, CaseIterable, Codable, Sendable {
    case rightCommand = 54
    case rightShift = 60
    case rightOption = 61
    case rightControl = 62

    public static let `default`: ModifierKey = .rightOption

    public var displayName: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .rightShift: "Right ⇧"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd Core && swift test
```

Expected: 20 tests, all passing.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/NotchVoiceCore/ModifierKey.swift Core/Sources/NotchVoiceCore/ClipboardGuard.swift Core/Tests/NotchVoiceCoreTests/ClipboardGuardTests.swift
git commit -m "feat: modifier key model and clipboard restore guard"
```

---

## Task 4: Waveform level buffer

Backs the scrolling bars in the island. Pure ring buffer so the view layer stays dumb.

**Files:**
- Create: `Core/Sources/NotchVoiceCore/LevelBuffer.swift`
- Test: `Core/Tests/NotchVoiceCoreTests/LevelBufferTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `struct LevelBuffer` with `init(capacity: Int)`, `mutating func append(_ level: Float)`, `var levels: [Float] { get }`, `mutating func reset()`, `static func rms(_ samples: [Float]) -> Float`

- [ ] **Step 1: Write the failing test**

`Core/Tests/NotchVoiceCoreTests/LevelBufferTests.swift`:

```swift
import Testing
@testable import NotchVoiceCore

@Suite("LevelBuffer")
struct LevelBufferTests {

    @Test("starts empty-padded to capacity so bars render flat, not missing")
    func startsPadded() {
        let buffer = LevelBuffer(capacity: 4)
        #expect(buffer.levels == [0, 0, 0, 0])
    }

    @Test("appending scrolls values leftward")
    func appendScrolls() {
        var buffer = LevelBuffer(capacity: 3)
        buffer.append(0.1)
        buffer.append(0.2)
        #expect(buffer.levels == [0, 0.1, 0.2])
    }

    @Test("oldest value drops off once capacity is exceeded")
    func dropsOldest() {
        var buffer = LevelBuffer(capacity: 3)
        buffer.append(0.1)
        buffer.append(0.2)
        buffer.append(0.3)
        buffer.append(0.4)
        #expect(buffer.levels == [0.2, 0.3, 0.4])
    }

    @Test("levels are clamped into 0...1")
    func clampsLevels() {
        var buffer = LevelBuffer(capacity: 2)
        buffer.append(-5)
        buffer.append(9)
        #expect(buffer.levels == [0, 1])
    }

    @Test("reset returns to flat")
    func resetsToFlat() {
        var buffer = LevelBuffer(capacity: 3)
        buffer.append(0.9)
        buffer.reset()
        #expect(buffer.levels == [0, 0, 0])
    }

    @Test("rms of silence is zero")
    func rmsOfSilence() {
        #expect(LevelBuffer.rms([0, 0, 0, 0]) == 0)
    }

    @Test("rms of a constant signal is its magnitude")
    func rmsOfConstant() {
        let value = LevelBuffer.rms([0.5, -0.5, 0.5, -0.5])
        #expect(abs(value - 0.5) < 0.0001)
    }

    @Test("rms of an empty buffer is zero rather than NaN")
    func rmsOfEmpty() {
        #expect(LevelBuffer.rms([]) == 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd Core && swift test --filter LevelBuffer
```

Expected: compile failure — `cannot find 'LevelBuffer' in scope`.

- [ ] **Step 3: Write the implementation**

`Core/Sources/NotchVoiceCore/LevelBuffer.swift`:

```swift
import Foundation

/// Fixed-width ring of recent microphone amplitudes, oldest first.
///
/// Always reports exactly `capacity` values so the waveform renders a stable
/// number of bars from the first frame — a buffer that grows would make the
/// bars visibly pop in.
public struct LevelBuffer: Sendable {
    private var storage: [Float]
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "LevelBuffer needs at least one slot")
        self.capacity = capacity
        self.storage = Array(repeating: 0, count: capacity)
    }

    public var levels: [Float] { storage }

    public mutating func append(_ level: Float) {
        storage.removeFirst()
        storage.append(min(max(level, 0), 1))
    }

    public mutating func reset() {
        storage = Array(repeating: 0, count: capacity)
    }

    /// Root-mean-square amplitude of a PCM chunk, used to drive one bar.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd Core && swift test
```

Expected: 28 tests, all passing.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/NotchVoiceCore/LevelBuffer.swift Core/Tests/NotchVoiceCoreTests/LevelBufferTests.swift
git commit -m "feat: waveform level ring buffer"
```

---

## Task 5: Notch geometry

Pure math so the window layer can be dumb, and so the "does this screen have a notch" rule is testable without a MacBook attached.

**Files:**
- Create: `Core/Sources/NotchVoiceCore/NotchGeometry.swift`
- Test: `Core/Tests/NotchVoiceCoreTests/NotchGeometryTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `struct ScreenMetrics` (`frameWidth`, `frameHeight`, `originX`, `originY`, `safeAreaTop`, `auxiliaryLeftWidth`, `auxiliaryRightWidth` — all `CGFloat`, all optional-free), and `enum NotchGeometry { static func notchSize(for: ScreenMetrics) -> CGSize?; static func notchRect(for: ScreenMetrics) -> CGRect? }`

- [ ] **Step 1: Write the failing test**

`Core/Tests/NotchVoiceCoreTests/NotchGeometryTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import NotchVoiceCore

@Suite("NotchGeometry")
struct NotchGeometryTests {

    /// 16" MacBook Pro in points.
    private var macBookPro: ScreenMetrics {
        ScreenMetrics(
            frameWidth: 1728, frameHeight: 1117,
            originX: 0, originY: 0,
            safeAreaTop: 32,
            auxiliaryLeftWidth: 764, auxiliaryRightWidth: 764
        )
    }

    /// External monitor: no safe-area inset, no auxiliary areas.
    private var externalMonitor: ScreenMetrics {
        ScreenMetrics(
            frameWidth: 2560, frameHeight: 1440,
            originX: 1728, originY: 0,
            safeAreaTop: 0,
            auxiliaryLeftWidth: 0, auxiliaryRightWidth: 0
        )
    }

    @Test("a notched screen reports the notch size")
    func notchedScreenHasSize() {
        let size = NotchGeometry.notchSize(for: macBookPro)
        #expect(size == CGSize(width: 200, height: 32))
    }

    @Test("an external monitor reports no notch")
    func externalMonitorHasNoNotch() {
        #expect(NotchGeometry.notchSize(for: externalMonitor) == nil)
    }

    @Test("a screen with a top inset but no auxiliary areas has no notch")
    func insetWithoutAuxiliaryAreasIsNotANotch() {
        // A full-screen-menu-bar inset is not a notch. Both auxiliary areas
        // must be present for the cutout to be real.
        let metrics = ScreenMetrics(
            frameWidth: 1920, frameHeight: 1080,
            originX: 0, originY: 0,
            safeAreaTop: 24,
            auxiliaryLeftWidth: 0, auxiliaryRightWidth: 0
        )
        #expect(NotchGeometry.notchSize(for: metrics) == nil)
    }

    @Test("the notch rect is centred at the top of the screen")
    func notchRectIsTopCentred() {
        let rect = NotchGeometry.notchRect(for: macBookPro)
        #expect(rect == CGRect(x: 764, y: 1085, width: 200, height: 32))
    }

    @Test("the notch rect accounts for a non-zero screen origin")
    func notchRectRespectsOrigin() {
        let metrics = ScreenMetrics(
            frameWidth: 1728, frameHeight: 1117,
            originX: 100, originY: 50,
            safeAreaTop: 32,
            auxiliaryLeftWidth: 764, auxiliaryRightWidth: 764
        )
        let rect = NotchGeometry.notchRect(for: metrics)
        #expect(rect == CGRect(x: 864, y: 1135, width: 200, height: 32))
    }

    @Test("an external monitor has no notch rect")
    func externalMonitorHasNoRect() {
        #expect(NotchGeometry.notchRect(for: externalMonitor) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd Core && swift test --filter NotchGeometry
```

Expected: compile failure — `cannot find 'ScreenMetrics' in scope`.

- [ ] **Step 3: Write the implementation**

`Core/Sources/NotchVoiceCore/NotchGeometry.swift`:

```swift
import CoreGraphics

/// The subset of `NSScreen` this module needs, lifted into a plain value so
/// the geometry rules can be tested without a display attached.
public struct ScreenMetrics: Equatable, Sendable {
    public let frameWidth: CGFloat
    public let frameHeight: CGFloat
    public let originX: CGFloat
    public let originY: CGFloat
    /// `NSScreen.safeAreaInsets.top`.
    public let safeAreaTop: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea?.width ?? 0`.
    public let auxiliaryLeftWidth: CGFloat
    /// `NSScreen.auxiliaryTopRightArea?.width ?? 0`.
    public let auxiliaryRightWidth: CGFloat

    public init(
        frameWidth: CGFloat,
        frameHeight: CGFloat,
        originX: CGFloat,
        originY: CGFloat,
        safeAreaTop: CGFloat,
        auxiliaryLeftWidth: CGFloat,
        auxiliaryRightWidth: CGFloat
    ) {
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.originX = originX
        self.originY = originY
        self.safeAreaTop = safeAreaTop
        self.auxiliaryLeftWidth = auxiliaryLeftWidth
        self.auxiliaryRightWidth = auxiliaryRightWidth
    }
}

/// Derives the physical notch cutout from screen metrics.
///
/// A top safe-area inset alone is not enough — a full-screen menu bar produces
/// one too. Both auxiliary top areas must be non-zero, because those are the
/// usable strips either side of the cutout and they only exist when there is
/// a cutout between them.
public enum NotchGeometry {

    public static func notchSize(for metrics: ScreenMetrics) -> CGSize? {
        guard metrics.safeAreaTop > 0 else { return nil }
        guard metrics.auxiliaryLeftWidth > 0, metrics.auxiliaryRightWidth > 0 else {
            return nil
        }
        let width = metrics.frameWidth
            - metrics.auxiliaryLeftWidth
            - metrics.auxiliaryRightWidth
        guard width > 0 else { return nil }
        return CGSize(width: width, height: metrics.safeAreaTop)
    }

    /// Notch rect in screen coordinates, origin bottom-left as AppKit expects.
    public static func notchRect(for metrics: ScreenMetrics) -> CGRect? {
        guard let size = notchSize(for: metrics) else { return nil }
        return CGRect(
            x: metrics.originX + (metrics.frameWidth - size.width) / 2,
            y: metrics.originY + metrics.frameHeight - size.height,
            width: size.width,
            height: size.height
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd Core && swift test
```

Expected: 34 tests, all passing.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/NotchVoiceCore/NotchGeometry.swift Core/Tests/NotchVoiceCoreTests/NotchGeometryTests.swift
git commit -m "feat: notch geometry derivation"
```

---

## Task 6: Microphone capture

**Files:**
- Create: `App/Audio/MicRecorder.swift`

**Interfaces:**
- Consumes: `LevelBuffer.rms(_:)` from Task 4
- Produces:
  - `@MainActor final class MicRecorder`
  - `func start() throws`
  - `func stop() -> [Float]` — returns the full 16kHz mono buffer
  - `func discard()`
  - `var onLevel: (@MainActor @Sendable (Float) -> Void)?` — fires ~20×/sec with an RMS level in `0...1`. Read once when `start()` installs the tap, so set it before starting.
  - `var duration: TimeInterval { get }`
  - `enum MicRecorderError: Error { case engineFailed(String), converterUnavailable }`

- [ ] **Step 1: Write the implementation**

There is no unit test here — this is a thin wrapper over `AVAudioEngine` whose behaviour is entirely about real hardware. It is verified manually in Step 2.

`App/Audio/MicRecorder.swift`:

```swift
import AVFoundation
import NotchVoiceCore
import Synchronization

enum MicRecorderError: Error {
    case engineFailed(String)
    case converterUnavailable
}

/// Captures microphone audio into a 16 kHz mono Float32 buffer, which is the
/// format Whisper expects.
///
/// The hardware runs at whatever rate it likes (usually 48 kHz), so every tap
/// buffer is converted before being accumulated. Conversion happens on the
/// audio thread, which is acceptable because `AVAudioConverter` on a small
/// buffer is cheap and the alternative — shipping raw buffers to another
/// thread — costs more in allocation than it saves.
@MainActor
final class MicRecorder {

    /// Whisper's required input rate.
    private static let targetSampleRate: Double = 16_000
    /// How many level callbacks per second the waveform gets.
    private static let levelsPerSecond: Double = 20

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    /// Samples are accumulated under a lock, straight from the audio thread,
    /// rather than hopped onto the main actor. See the tap block below for why.
    /// Keep this on the lock; do not route it back through the main actor.
    private nonisolated let store = Mutex<[Float]>([])

    private var isRunning = false
    private var startedAt: Date?

    /// Fires with an RMS level in `0...1` roughly 20 times a second. Read once
    /// when `start()` installs the tap, so set it before starting.
    var onLevel: (@MainActor @Sendable (Float) -> Void)?

    var duration: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    func start() throws {
        guard !isRunning else { return }
        store.withLock { $0.removeAll(keepingCapacity: true) }

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MicRecorderError.converterUnavailable
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw MicRecorderError.converterUnavailable
        }
        self.converter = converter

        // Tap buffer sized so one callback is roughly one waveform bar.
        let tapFrames = AVAudioFrameCount(
            hardwareFormat.sampleRate / Self.levelsPerSecond
        )

        // Grabbed here so the audio thread never reaches for main-actor state.
        let onLevel = self.onLevel

        input.installTap(onBus: 0, bufferSize: tapFrames, format: hardwareFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            let converted = Self.convert(buffer, using: converter, to: targetFormat)
            guard !converted.isEmpty else { return }
            // Samples go straight into the lock. They must NOT be hopped onto
            // the main actor: stop() is synchronous and never suspends, so any
            // append still queued there could not have run when it reads. That
            // cost 100-150ms of tail with the actor merely busy at 60fps, the
            // whole take when it was blocked, and the stranded appends then
            // landed after stop() cleared — becoming the head of the next take.
            self.store.withLock { $0.append(contentsOf: converted) }

            // The level is only a waveform bar, so it can afford the hop —
            // a late or dropped bar costs nothing, a late sample costs audio.
            guard let onLevel else { return }
            let level = LevelBuffer.rms(converted)
            Task { @MainActor in
                onLevel(min(level * 4, 1))  // ×4 so speech fills the bars
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicRecorderError.engineFailed(error.localizedDescription)
        }

        isRunning = true
        startedAt = Date()
    }

    /// Stops capture and hands back everything recorded.
    func stop() -> [Float] {
        teardown()
        return store.withLock { captured in
            let samples = captured
            captured.removeAll(keepingCapacity: false)
            return samples
        }
    }

    /// Stops capture and throws the audio away.
    func discard() {
        teardown()
        store.withLock { $0.removeAll(keepingCapacity: false) }
    }

    private func teardown() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
        startedAt = nil
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: capacity
        ) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
```

- [ ] **Step 2: Verify manually by recording to a file**

Temporarily add this to `applicationDidFinishLaunching` in `App/App/NotchVoiceApp.swift`:

```swift
Task { @MainActor in
    let recorder = MicRecorder()
    recorder.onLevel = { NSLog("[NotchVoice] level %.3f", $0) }
    try? recorder.start()
    try? await Task.sleep(for: .seconds(3))
    let samples = recorder.stop()
    NSLog("[NotchVoice] captured %d samples (%.2fs at 16kHz)",
          samples.count, Double(samples.count) / 16_000)
}
```

Then:

```bash
xcodegen generate
xcodebuild -project NotchVoice.xcodeproj -scheme NotchVoice -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/NotchVoice-*/Build/Products/Debug/NotchVoice.app
```

macOS will prompt for microphone access — grant it. Talk for the 3 seconds.

Run the binary **directly** rather than via `open`, so `NSLog` goes to stderr in
the terminal. Do NOT use `log show`: it redacts NSLog arguments coming from
another process, so every one of our lines reads as `(Foundation) <private>`,
which looks identical to the app printing nothing at all.

```bash
"$(ls -d ~/Library/Developer/Xcode/DerivedData/NotchVoice-*/Build/Products/Debug/NotchVoice.app)/Contents/MacOS/NotchVoice"
```

Expected: level lines that are near zero in silence and clearly higher while you speak, then `captured ~48000 samples (3.00s at 16kHz)`. If the sample count is wildly off 48000, the converter ratio is wrong.

- [ ] **Step 3: Remove the temporary test code**

Delete the block added in Step 2 from `NotchVoiceApp.swift`.

- [ ] **Step 4: Commit**

```bash
git add App/Audio/MicRecorder.swift
git commit -m "feat: 16kHz mono microphone capture with level metering"
```

---

## Task 7: WhisperKit transcription service

**Files:**
- Create: `App/Transcribe/WhisperKitService.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `actor WhisperKitService`
  - `init(modelVariant: String = "openai_whisper-large-v3-v20240930_turbo_632MB")`
  - `func prepare(progress: @Sendable @escaping (Double) -> Void) async throws` — downloads if needed, loads, prewarms
  - `func transcribe(_ samples: [Float]) async throws -> String`
  - `var isReady: Bool { get }`
  - `enum TranscriptionError: Error { case notReady, empty }`

- [ ] **Step 1: Write the implementation**

The model is loaded once at launch and kept resident for the life of the process — the design accepts ~1GB permanent RAM in exchange for every dictation being fast (spec §4).

`App/Transcribe/WhisperKitService.swift`:

```swift
import Foundation
import WhisperKit

enum TranscriptionError: Error {
    case notReady
    case empty
}

/// Owns the WhisperKit pipeline for the life of the process.
///
/// An actor rather than a class: transcription is the one genuinely
/// long-running operation in the app, and serialising access means a second
/// dictation submitted while the first is still decoding queues instead of
/// contending for the ANE.
actor WhisperKitService {

    private let modelVariant: String
    private var pipe: WhisperKit?

    init(modelVariant: String = "openai_whisper-large-v3-v20240930_turbo_632MB") {
        self.modelVariant = modelVariant
    }

    var isReady: Bool { pipe != nil }

    /// Downloads the model if it isn't cached, loads it, and prewarms the
    /// compute units. Safe to call more than once; later calls no-op.
    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws {
        guard pipe == nil else { return }

        let config = WhisperKitConfig(
            model: modelVariant,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        pipe = try await WhisperKit(config)
        progress(1.0)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe else { throw TranscriptionError.notReady }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw TranscriptionError.empty }
        return text
    }
}
```

- [ ] **Step 2: Verify manually against a known recording**

Temporarily add to `applicationDidFinishLaunching`:

```swift
Task { @MainActor in
    let service = WhisperKitService()
    NSLog("[NotchVoice] preparing model…")
    try await service.prepare { NSLog("[NotchVoice] prepare progress %.2f", $0) }
    NSLog("[NotchVoice] model ready")

    // MicRecorder is @MainActor-isolated and this Task runs on the main
    // actor, so these calls need no hopping.
    let recorder = MicRecorder()
    try recorder.start()
    try await Task.sleep(for: .seconds(5))
    let samples = recorder.stop()

    let text = try await service.transcribe(samples)
    NSLog("[NotchVoice] transcript: %@", text)
}
```

Build, launch, and say a clear sentence during the 5 second window. First launch downloads ~630MB, so allow several minutes before the "model ready" line.

Run the binary directly so `NSLog` reaches stderr uncensored — `log show`
redacts NSLog arguments from other processes and will show `<private>`.

```bash
"$(ls -d ~/Library/Developer/Xcode/DerivedData/NotchVoice-*/Build/Products/Debug/NotchVoice.app)/Contents/MacOS/NotchVoice"
```

Expected: `model ready`, then a `transcript:` line matching roughly what you said.

If the model variant name is rejected, list what the repo actually offers and pick the turbo variant:

```bash
curl -s "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml" | python3 -m json.tool | grep -i turbo
```

- [ ] **Step 3: Remove the temporary test code**

Delete the block added in Step 2.

- [ ] **Step 4: Commit**

```bash
git add App/Transcribe/WhisperKitService.swift
git commit -m "feat: WhisperKit transcription service, resident model"
```

---

## Task 8: Focus capture and paste delivery

The part that has to be right or it eats people's clipboards.

**Files:**
- Create: `App/Deliver/FocusSnapshot.swift`
- Create: `App/Deliver/Paster.swift`

**Interfaces:**
- Consumes: `ClipboardGuard.shouldRestore(changeCountAfterWrite:currentChangeCount:)` and `NotchVoice.bundleID` from Task 3 / Task 1
- Produces:
  - `struct FocusSnapshot: Sendable { let pid: pid_t; let bundleID: String? }`, `static func capture() -> FocusSnapshot?`, `func activate()`
  - `enum PasteOutcome { case pasted, copiedOnly }`
  - `enum Paster { static func isAccessibilityTrusted() -> Bool; static func promptForAccessibility(); @MainActor static func deliver(_ text: String, to focus: FocusSnapshot?) async -> PasteOutcome }`

- [ ] **Step 1: Write FocusSnapshot**

`App/Deliver/FocusSnapshot.swift`:

```swift
import AppKit

/// Which app owned the keyboard when the dictation chord fired.
///
/// Captured *before* the island window is shown. Showing a window first risks
/// AppKit reshuffling key focus, and then we would paste into the wrong place.
struct FocusSnapshot: Sendable {
    let pid: pid_t
    let bundleID: String?

    static func capture() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FocusSnapshot(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier
        )
    }

    /// Brings the captured app back to the front so the synthetic ⌘V lands
    /// in it rather than wherever focus drifted to.
    func activate() {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }
}
```

- [ ] **Step 2: Write Paster**

`App/Deliver/Paster.swift`:

```swift
import AppKit
import ApplicationServices
import NotchVoiceCore

enum PasteOutcome {
    case pasted
    case copiedOnly
}

/// Delivers transcribed text into the app that had focus.
///
/// Uses a clipboard round-trip rather than an Accessibility text insertion:
/// `AXUIElementSetAttributeValue` fails or corrupts state in Electron apps,
/// terminals, and anything with a custom text engine, which is most of what
/// people dictate into. The clipboard plus a synthetic ⌘V works everywhere.
///
/// The original clipboard is snapshotted at full fidelity (every UTI on every
/// item, raw bytes) and put back afterwards — but only if nothing else wrote
/// in the meantime. See `ClipboardGuard`.
enum Paster {

    /// How long the staged text stays on the clipboard before restore. Too
    /// short and slow apps have not consumed the paste yet; too long and the
    /// user notices their clipboard is briefly wrong.
    private static let pasteConsumeDelay = Duration.milliseconds(150)
    /// Time for the reactivated app to actually become frontmost.
    private static let activateSettleDelay = Duration.milliseconds(80)

    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that deep-links into Settings. Only call this
    /// from an explicit user action — it is noisy.
    static func promptForAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func deliver(_ text: String, to focus: FocusSnapshot?) async -> PasteOutcome {
        // Pasting into ourselves would double-insert or miss the real target.
        let targetIsSelf = focus?.bundleID == NotchVoice.bundleID

        guard isAccessibilityTrusted(), let focus, !targetIsSelf else {
            copyOnly(text)
            return .copiedOnly
        }

        focus.activate()
        try? await Task.sleep(for: activateSettleDelay)

        let snapshot = ClipboardSnapshot.capture()
        let changeCountAfterWrite = writeText(text)

        let pasted = sendCommandV()
        try? await Task.sleep(for: pasteConsumeDelay)

        // Restore is attempted whether or not the paste succeeded, so a failed
        // CGEventPost never leaves the clipboard stuck holding the transcript.
        if ClipboardGuard.shouldRestore(
            changeCountAfterWrite: changeCountAfterWrite,
            currentChangeCount: NSPasteboard.general.changeCount
        ) {
            snapshot.restore()
        }

        return pasted ? .pasted : .copiedOnly
    }

    private static func copyOnly(_ text: String) {
        _ = writeText(text)
    }

    @discardableResult
    private static func writeText(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    /// Posts ⌘V into the session event stream. Returns false if the events
    /// could not be created — which in practice means Accessibility was
    /// revoked between the check above and here.
    private static func sendCommandV() -> Bool {
        let vKeyCode: CGKeyCode = 9  // kVK_ANSI_V
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: vKeyCode, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}

/// Full-fidelity snapshot of the general pasteboard.
///
/// Stores every `(UTI, raw bytes)` pair on every item, so restoring rebuilds
/// the complete multi-type payload — images, styled text, and file references
/// all survive the round-trip, not just the plain-text fallback.
private struct ClipboardSnapshot {
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    static func capture() -> ClipboardSnapshot {
        let captured = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
        return ClipboardSnapshot(items: captured)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let rebuilt = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(rebuilt)
    }
}
```

- [ ] **Step 3: Verify the clipboard survives a paste**

Temporarily add to `applicationDidFinishLaunching`:

```swift
Task { @MainActor in
    try? await Task.sleep(for: .seconds(5))  // switch to TextEdit now
    let focus = FocusSnapshot.capture()
    NSLog("[NotchVoice] target: %@", focus?.bundleID ?? "none")
    let outcome = await Paster.deliver("hello from notchvoice", to: focus)
    NSLog("[NotchVoice] outcome: %@", String(describing: outcome))
}
```

Then:

1. Copy something distinctive first: `echo "SENTINEL-VALUE" | pbcopy`
2. Build, launch, and immediately click into an open TextEdit document.
3. Wait for the paste.

```bash
pbpaste
```

Expected: `hello from notchvoice` appears in TextEdit, **and `pbpaste` still prints `SENTINEL-VALUE`**. If the sentinel is gone, the restore is broken — that is the single most important behaviour in this task.

On first run the app will not be trusted, so the outcome will be `copiedOnly`. Grant it in System Settings → Privacy & Security → Accessibility, relaunch, and repeat to see `pasted`.

- [ ] **Step 4: Verify the copy-only fallback**

Revoke Accessibility for NotchVoice in System Settings, relaunch, repeat Step 3. Expected: outcome `copiedOnly`, nothing typed into TextEdit, and `pbpaste` prints `hello from notchvoice`. Re-grant afterwards.

- [ ] **Step 5: Remove the temporary test code**

Delete the block added in Step 3.

- [ ] **Step 6: Commit**

```bash
git add App/Deliver/FocusSnapshot.swift App/Deliver/Paster.swift
git commit -m "feat: focus capture and clipboard-safe paste delivery"
```

---

## Task 9: Observe-only modifier tap

**Files:**
- Create: `App/Input/ModifierTap.swift`
- Create: `App/Input/BindingStore.swift`

**Interfaces:**
- Consumes: `ModifierKey` from Task 3
- Produces:
  - `enum BindingStore { static var binding: ModifierKey { get set } }` — persisted in `UserDefaults`
  - `@MainActor final class ModifierTap`
  - `init(binding: ModifierKey)`
  - `func start() -> Bool` — false if Input Monitoring is not granted
  - `func stop()`
  - `func updateBinding(_ key: ModifierKey)`
  - `var onKeyDown: (() -> Void)?`, `var onKeyUp: (() -> Void)?`, `var onOtherKey: (() -> Void)?`, `var onEscape: (() -> Void)?`

- [ ] **Step 1: Write BindingStore**

`App/Input/BindingStore.swift`:

```swift
import Foundation
import NotchVoiceCore

/// Persists which modifier is bound to dictation.
enum BindingStore {
    private static let key = "dictationBinding"

    static var binding: ModifierKey {
        get {
            let raw = UserDefaults.standard.object(forKey: key) as? Int
            guard let raw, let parsed = ModifierKey(rawValue: UInt16(raw)) else {
                return .default
            }
            return parsed
        }
        set {
            UserDefaults.standard.set(Int(newValue.rawValue), forKey: key)
        }
    }
}
```

- [ ] **Step 2: Write ModifierTap**

`App/Input/ModifierTap.swift`:

```swift
import AppKit
import NotchVoiceCore

/// Watches the global keyboard for the bound modifier.
///
/// **Observe-only.** The callback returns every event unmodified, always. It
/// never consumes, swallows, or rewrites anything — which is precisely why the
/// binding is restricted to modifiers: holding a bare modifier does nothing in
/// any app, so letting it through is harmless. Binding to a normal key would
/// require a consuming tap and put this code in the path of every keystroke
/// the user types.
///
/// Modifiers do not produce keyDown/keyUp events; they produce `.flagsChanged`
/// with the raw keycode identifying *which* modifier, including whether it is
/// the left or right one. That is why the binding is stored as a keycode
/// rather than an `NSEvent.ModifierFlags`.
@MainActor
final class ModifierTap {

    private var binding: ModifierKey
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isBindingKeyDown = false

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onOtherKey: (() -> Void)?
    var onEscape: (() -> Void)?

    init(binding: ModifierKey = BindingStore.binding) {
        self.binding = binding
    }

    deinit {
        // Cannot call the @MainActor stop() here; unwind the CF objects directly.
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    func updateBinding(_ key: ModifierKey) {
        binding = key
        isBindingKeyDown = false
    }

    /// Returns false when Input Monitoring has not been granted — creating the
    /// tap is exactly how you find out, there is no separate check.
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // <- observe-only, cannot swallow
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<ModifierTap>.fromOpaque(refcon)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    tap.handle(type: type, event: event)
                }
                // Always hand the event straight back, untouched.
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        runLoopSource = source
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        tap = nil
        isBindingKeyDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables a tap that takes too long in its callback. Re-arm
        // rather than silently dying — the user would just see the hotkey
        // stop working with no explanation.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .flagsChanged:
            guard keyCode == binding.rawValue else {
                // A different modifier moved. Only counts as interference
                // while our key is actually held.
                if isBindingKeyDown { onOtherKey?() }
                return
            }
            // flagsChanged carries no up/down bit, so track it ourselves.
            isBindingKeyDown.toggle()
            if isBindingKeyDown { onKeyDown?() } else { onKeyUp?() }

        case .keyDown:
            let escapeKeyCode: UInt16 = 53
            if keyCode == escapeKeyCode {
                onEscape?()
            } else if isBindingKeyDown {
                onOtherKey?()
            }

        default:
            break
        }
    }
}
```

- [ ] **Step 3: Verify the tap sees the right key and nothing else**

Temporarily add to `applicationDidFinishLaunching`:

```swift
Task { @MainActor in
    let tap = ModifierTap()
    tap.onKeyDown = { NSLog("[NotchVoice] DOWN") }
    tap.onKeyUp = { NSLog("[NotchVoice] UP") }
    tap.onOtherKey = { NSLog("[NotchVoice] OTHER") }
    tap.onEscape = { NSLog("[NotchVoice] ESC") }
    let started = tap.start()
    NSLog("[NotchVoice] tap started: %@", started ? "yes" : "no")
    self.debugTap = tap  // add `var debugTap: ModifierTap?` to the class
}
```

Build, launch. macOS prompts for Input Monitoring — grant it in System Settings → Privacy & Security → Input Monitoring, then relaunch.

```bash
log stream --predicate 'process == "NotchVoice"' --info
```

Test each of these and confirm the log:

| Action | Expected log |
|---|---|
| Tap right-⌥ | `DOWN` then `UP` |
| Tap **left**-⌥ | nothing |
| Hold right-⌥, press `o` | `DOWN`, `OTHER` |
| Press `Esc` alone | `ESC` |
| Type a normal sentence | nothing |

Then the critical check — **confirm nothing is being swallowed**. With the app running, open TextEdit and:

- Type `⌥ + o` → must produce `ø`
- Press `⌥ + ←` → cursor must jump a word
- Type a full sentence normally → every character must appear

If any keystroke is missing, the tap is not observe-only and must be fixed before going further.

- [ ] **Step 4: Remove the temporary test code**

Delete the block and the `debugTap` property.

- [ ] **Step 5: Commit**

```bash
git add App/Input/ModifierTap.swift App/Input/BindingStore.swift
git commit -m "feat: observe-only modifier key tap"
```

---

## Task 10: Dictation coordinator — end-to-end, no UI

After this task the app is a working dictation tool. Everything remaining is presentation.

**Files:**
- Create: `App/DictationCoordinator.swift`
- Modify: `App/App/NotchVoiceApp.swift`

**Interfaces:**
- Consumes: `RecordingStateMachine` (Task 2), `MicRecorder` (Task 6), `WhisperKitService` (Task 7), `FocusSnapshot` / `Paster` (Task 8), `ModifierTap` / `BindingStore` (Task 9)
- Produces:
  - `@MainActor final class DictationCoordinator`
  - `enum Phase: Equatable { case dormant, recording, locked, transcribing, done, tooShort, error(String) }`
  - `@Published private(set) var phase: Phase`
  - `@Published private(set) var levels: [Float]`
  - `func start()`
  - `var onPhaseChange: ((Phase) -> Void)?`

- [ ] **Step 1: Write the coordinator**

`App/DictationCoordinator.swift`:

```swift
import AppKit
import Combine
import NotchVoiceCore

/// Wires the tap, the state machine, the recorder, transcription, and delivery
/// into one flow. The only object that knows the whole pipeline.
@MainActor
final class DictationCoordinator: ObservableObject {

    enum Phase: Equatable {
        case dormant
        case recording
        case locked
        case transcribing
        case done
        case tooShort
        case error(String)
    }

    /// Below this, there is not enough audio to transcribe usefully.
    private static let minimumDuration: TimeInterval = 0.5
    /// Locked sessions would otherwise run unbounded. Spec §5.
    private static let maximumDuration: TimeInterval = 300
    /// How many bars the waveform shows.
    private static let waveformBarCount = 28
    /// How long a terminal phase stays on screen before collapsing.
    private static let doneDwell = Duration.milliseconds(900)
    private static let errorDwell = Duration.seconds(4)

    @Published private(set) var phase: Phase = .dormant
    @Published private(set) var levels: [Float]

    private var machine = RecordingStateMachine()
    private let recorder = MicRecorder()
    private let transcriber = WhisperKitService()
    private var tap: ModifierTap?

    private var buffer: LevelBuffer
    private var focus: FocusSnapshot?
    private var doubleTapTimer: Task<Void, Never>?
    private var maxDurationTimer: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?

    init() {
        let buffer = LevelBuffer(capacity: Self.waveformBarCount)
        self.buffer = buffer
        self.levels = buffer.levels
    }

    func start() {
        let tap = ModifierTap(binding: BindingStore.binding)
        tap.onKeyDown = { [weak self] in self?.dispatch(.keyDown(at: Self.now())) }
        tap.onKeyUp = { [weak self] in self?.dispatch(.keyUp(at: Self.now())) }
        tap.onOtherKey = { [weak self] in self?.dispatch(.otherKeyPressed) }
        tap.onEscape = { [weak self] in self?.dispatch(.escapePressed) }

        if !tap.start() {
            phase = .error("Input Monitoring permission needed")
            return
        }
        self.tap = tap

        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            buffer.append(level)
            levels = buffer.levels
        }

        Task {
            do {
                try await transcriber.prepare { _ in }
            } catch {
                phase = .error("Model failed to load: \(error.localizedDescription)")
            }
        }
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func dispatch(_ event: RecordingStateMachine.Event) {
        apply(machine.handle(event))
    }

    private func apply(_ effect: RecordingStateMachine.Effect) {
        switch effect {
        case .none:
            break

        case .startCapture:
            beginCapture()

        case .restartCapture:
            // A second tap arrived too late to lock, so the first tap's audio
            // is stale. Drop it before starting over — MicRecorder.start()
            // no-ops while already running, so without this the stale samples
            // would be prepended to the new dictation and pasted.
            recorder.discard()
            beginCapture()

        case .armDoubleTapTimer:
            armDoubleTapTimer()

        case .enterLocked:
            cancelDoubleTapTimer()
            setPhase(.locked)

        case .stopAndTranscribe:
            cancelTimers()
            finishAndTranscribe()

        case .discard:
            cancelTimers()
            recorder.discard()
            resetWaveform()
            setPhase(.dormant)
        }
    }

    private func beginCapture() {
        collapseTask?.cancel()
        // Captured before any window is shown — see FocusSnapshot's note.
        focus = FocusSnapshot.capture()
        resetWaveform()

        do {
            try recorder.start()
        } catch {
            setPhase(.error("Microphone unavailable"))
            return
        }

        setPhase(.recording)
        armMaxDurationTimer()
    }

    private func finishAndTranscribe() {
        let duration = recorder.duration
        let samples = recorder.stop()
        resetWaveform()

        guard duration >= Self.minimumDuration else {
            setPhase(.tooShort)
            scheduleCollapse(after: Self.doneDwell)
            return
        }

        setPhase(.transcribing)
        let target = focus

        Task {
            do {
                let text = try await transcriber.transcribe(samples)
                _ = await Paster.deliver(text, to: target)
                setPhase(.done)
                scheduleCollapse(after: Self.doneDwell)
            } catch TranscriptionError.empty {
                setPhase(.error("Nothing heard"))
                scheduleCollapse(after: Self.errorDwell)
            } catch {
                setPhase(.error(error.localizedDescription))
                scheduleCollapse(after: Self.errorDwell)
            }
        }
    }

    // MARK: - Timers

    private func armDoubleTapTimer() {
        cancelDoubleTapTimer()
        doubleTapTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.dispatch(.doubleTapWindowExpired)
        }
    }

    private func armMaxDurationTimer() {
        maxDurationTimer?.cancel()
        maxDurationTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumDuration))
            guard !Task.isCancelled else { return }
            self?.dispatch(.maxDurationReached)
        }
    }

    private func cancelDoubleTapTimer() {
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
    }

    private func cancelTimers() {
        cancelDoubleTapTimer()
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
    }

    private func scheduleCollapse(after delay: Duration) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.setPhase(.dormant)
        }
    }

    // MARK: - Helpers

    private func resetWaveform() {
        buffer.reset()
        levels = buffer.levels
    }

    private func setPhase(_ next: Phase) {
        phase = next
        onPhaseChange?(next)
    }

    var onPhaseChange: ((Phase) -> Void)?
}
```

- [ ] **Step 2: Wire it into the app delegate**

Replace `App/App/NotchVoiceApp.swift` with:

```swift
import AppKit

@main
final class NotchVoiceApp: NSObject, NSApplicationDelegate {
    private var coordinator: DictationCoordinator?

    static func main() {
        let app = NSApplication.shared
        let delegate = NotchVoiceApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let coordinator = DictationCoordinator()
            coordinator.onPhaseChange = { phase in
                NSLog("[NotchVoice] phase: %@", String(describing: phase))
            }
            coordinator.start()
            self.coordinator = coordinator
        }
    }
}
```

- [ ] **Step 3: Build and test the full loop**

```bash
xcodegen generate
xcodebuild -project NotchVoice.xcodeproj -scheme NotchVoice -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/NotchVoice-*/Build/Products/Debug/NotchVoice.app
log stream --predicate 'process == "NotchVoice"' --info
```

Wait for the model to load, then click into TextEdit and run through these:

| Test | Expected |
|---|---|
| Hold right-⌥, say "hello world", release | `recording` → `transcribing` → `done`; text appears in TextEdit |
| Double-tap right-⌥, talk, tap again | `locked` → `transcribing` → `done`; text appears |
| Tap right-⌥ once, wait | `recording` → `dormant`; nothing pasted |
| Hold right-⌥, press `o`, release | `recording` → `dormant`; nothing pasted; `ø` typed |
| Hold right-⌥, say nothing, release quickly | `tooShort` → `dormant` |
| Hold right-⌥, talk, press `Esc` | `dormant`; nothing pasted |

Also confirm again that the clipboard survives: `echo SENTINEL | pbcopy`, dictate, then `pbpaste` still prints `SENTINEL`.

- [ ] **Step 4: Commit**

```bash
git add App/DictationCoordinator.swift App/App/NotchVoiceApp.swift
git commit -m "feat: end-to-end dictation loop"
```

---

## Task 11: Island window and notch bridge

**Files:**
- Create: `App/Island/IslandWindow.swift`
- Create: `App/Island/IslandWindowController.swift`
- Create: `App/Island/ScreenMetrics+NSScreen.swift`

**Interfaces:**
- Consumes: `ScreenMetrics`, `NotchGeometry` from Task 5
- Produces:
  - `extension NSScreen { var metrics: ScreenMetrics }`
  - `final class IslandWindow: NSWindow` — borderless, transparent, above the menu bar
  - `@MainActor final class IslandWindowController` with `init(coordinator: DictationCoordinator)`, `func show()`, `func moveToActiveScreen()`, `func rebuildForScreenChange()`

- [ ] **Step 1: Bridge NSScreen to ScreenMetrics**

`App/Island/ScreenMetrics+NSScreen.swift`:

```swift
import AppKit
import NotchVoiceCore

extension NSScreen {
    var metrics: ScreenMetrics {
        ScreenMetrics(
            frameWidth: frame.width,
            frameHeight: frame.height,
            originX: frame.origin.x,
            originY: frame.origin.y,
            safeAreaTop: safeAreaInsets.top,
            auxiliaryLeftWidth: auxiliaryTopLeftArea?.width ?? 0,
            auxiliaryRightWidth: auxiliaryTopRightArea?.width ?? 0
        )
    }

    var hasNotch: Bool {
        NotchGeometry.notchSize(for: metrics) != nil
    }

    /// The screen the pointer is currently on, falling back to the main screen.
    static var active: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}
```

- [ ] **Step 2: Write the window**

`App/Island/IslandWindow.swift`:

```swift
import AppKit

/// Transparent borderless window that hosts the island.
///
/// Sits above the menu bar (`.statusBar + 1`) so it can cover the notch, joins
/// every Space, and stays put during Mission Control. It never takes key focus
/// — doing so would yank focus out of whatever the user is dictating into,
/// which is the opposite of what an overlay should do.
final class IslandWindow: NSWindow {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        ignoresMouseEvents = true
        level = .statusBar + 1
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 3: Write the window controller**

`App/Island/IslandWindowController.swift`:

```swift
import AppKit
import SwiftUI
import NotchVoiceCore

/// Owns the island window and keeps it on the screen the user is working on.
@MainActor
final class IslandWindowController {

    /// Tall enough for the expanded island plus its drop shadow.
    private static let stripHeight: CGFloat = 200

    private var window: IslandWindow?
    private let coordinator: DictationCoordinator
    private var screenObserver: NSObjectProtocol?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func show() {
        buildWindow(on: NSScreen.active)
        observeScreenChanges()
    }

    /// Rebuilds on the screen the pointer is on. Cheap enough to call on every
    /// dictation start, which is how the island follows the user between
    /// displays without polling.
    func moveToActiveScreen() {
        guard let screen = NSScreen.active else { return }
        guard window?.screen != screen else { return }
        buildWindow(on: screen)
    }

    private func buildWindow(on screen: NSScreen?) {
        guard let screen else { return }

        window?.orderOut(nil)
        window = nil

        let frame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y + screen.frame.height - Self.stripHeight,
            width: screen.frame.width,
            height: Self.stripHeight
        )

        let window = IslandWindow(contentRect: frame)
        let root = IslandView(
            coordinator: coordinator,
            notchSize: NotchGeometry.notchSize(for: screen.metrics)
        )
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()

        self.window = window
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildForScreenChange()
            }
        }
    }

    func rebuildForScreenChange() {
        buildWindow(on: NSScreen.active)
    }
}
```

- [ ] **Step 4: Commit**

This task's window has nothing to render until Task 12, so build verification happens there.

```bash
git add App/Island/IslandWindow.swift App/Island/IslandWindowController.swift App/Island/ScreenMetrics+NSScreen.swift
git commit -m "feat: island overlay window and screen tracking"
```

---

## Task 12: Island view, waveform, and HUD fallback

**Files:**
- Create: `App/Island/WaveformView.swift`
- Create: `App/Island/IslandView.swift`
- Create: `App/Island/HUDView.swift`
- Modify: `App/App/NotchVoiceApp.swift`

**Interfaces:**
- Consumes: `DictationCoordinator.Phase` and `levels` from Task 10; `IslandWindowController` from Task 11
- Produces: `struct IslandView: View` with `init(coordinator: DictationCoordinator, notchSize: CGSize?)`

- [ ] **Step 1: Write the waveform**

`App/Island/WaveformView.swift`:

```swift
import SwiftUI

/// Live microphone amplitude as scrolling vertical bars.
///
/// Deliberately no timer — the bars themselves answer "is it hearing me?",
/// which is the only question the recording state needs to answer.
struct WaveformView: View {
    let levels: [Float]

    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule(style: .continuous)
                    .fill(.white)
                    .frame(
                        width: barWidth,
                        height: minHeight + CGFloat(level) * (maxHeight - minHeight)
                    )
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
    }
}
```

- [ ] **Step 2: Write the HUD fallback**

`App/Island/HUDView.swift`:

```swift
import SwiftUI

/// Fallback presentation for screens with no notch.
///
/// Styled after the system volume HUD rather than a fake notch — pretending a
/// cutout exists where there is none reads as wrong (spec §7).
///
/// NOTE: the exact corner radius, material, size and drop-down animation are
/// placeholders until they are matched against the real system HUD. To do
/// that: trigger a volume change, screenshot it with `⌘⇧4`, and adjust these
/// constants to match.
struct HUDView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}
```

- [ ] **Step 3: Write the island view**

`App/Island/IslandView.swift`:

```swift
import SwiftUI

/// The island itself: a shape pinned to the top-centre of the strip window
/// that changes size and contents with the dictation phase.
///
/// On a notched screen it starts exactly the size of the physical notch, so at
/// rest it is invisible — it *is* the notch. On other screens it renders as a
/// HUD capsule that is fully hidden at rest.
struct IslandView: View {
    @ObservedObject var coordinator: DictationCoordinator
    /// Physical notch size, or nil on screens without one.
    let notchSize: CGSize?

    private var isDormant: Bool { coordinator.phase == .dormant }

    private let animation: Animation = .interactiveSpring(
        duration: 0.42, extraBounce: 0.22, blendDuration: 0.1
    )

    var body: some View {
        VStack(spacing: 0) {
            if let notchSize {
                notchIsland(notchSize: notchSize)
            } else {
                hudIsland
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(animation, value: coordinator.phase)
        .allowsHitTesting(false)
    }

    // MARK: - Notch presentation

    private func notchIsland(notchSize: CGSize) -> some View {
        content
            .frame(
                width: isDormant ? notchSize.width : expandedWidth,
                height: isDormant ? notchSize.height : expandedHeight
            )
            .background(.black, in: IslandShape(isDormant: isDormant))
            .clipShape(IslandShape(isDormant: isDormant))
    }

    // MARK: - HUD presentation

    private var hudIsland: some View {
        Group {
            if isDormant {
                Color.clear.frame(width: 1, height: 1)
            } else {
                HUDView { content }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Contents

    private var expandedWidth: CGFloat {
        switch coordinator.phase {
        case .recording, .locked: 260
        case .transcribing: 200
        case .done, .tooShort: 180
        case .error: 340
        case .dormant: 0
        }
    }

    private var expandedHeight: CGFloat { 38 }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .dormant:
            Color.clear

        case .recording, .locked:
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                WaveformView(levels: coordinator.levels)
                if coordinator.phase == .locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(.white)

        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Transcribing")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)

        case .done:
            Label("Pasted", systemImage: "checkmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)

        case .tooShort:
            Text("Too short")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))

        case let .error(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.orange)
        }
    }
}

/// Rounded rectangle whose corners tighten when collapsed, so at rest it
/// matches the notch's own radius rather than looking like a floating pill.
private struct IslandShape: Shape {
    let isDormant: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = isDormant ? 8 : 19
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }
}
```

- [ ] **Step 4: Show the island from the app delegate**

Replace `applicationDidFinishLaunching` in `App/App/NotchVoiceApp.swift`:

```swift
    private var coordinator: DictationCoordinator?
    private var island: IslandWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let coordinator = DictationCoordinator()
            let island = IslandWindowController(coordinator: coordinator)

            coordinator.onPhaseChange = { phase in
                NSLog("[NotchVoice] phase: %@", String(describing: phase))
                if phase == .recording {
                    island.moveToActiveScreen()
                }
            }

            coordinator.start()
            island.show()

            self.coordinator = coordinator
            self.island = island
        }
    }
```

- [ ] **Step 5: Build and verify visually**

```bash
xcodegen generate
xcodebuild -project NotchVoice.xcodeproj -scheme NotchVoice -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/NotchVoice-*/Build/Products/Debug/NotchVoice.app
```

Check each of these on the **laptop screen**:

| Test | Expected |
|---|---|
| At rest | Notch looks completely normal — no visible change |
| Hold right-⌥ | Notch expands, mic icon and waveform appear |
| Speak while holding | Bars visibly react — tall on speech, flat on silence |
| Release | Expands to "Transcribing", then "Pasted", then collapses |
| Double-tap right-⌥ | Lock icon shows alongside the waveform |
| Move to a fullscreen app, dictate | Island still visible above it |

Then plug in an **external monitor**, move the pointer to it, and repeat. Expected: the HUD capsule drops in from the top instead of a notch, and nothing renders at rest.

- [ ] **Step 6: Match the HUD to the real system volume indicator**

Press a volume key, screenshot the system HUD with `⌘⇧4`, and compare side by side with NotchVoice's HUD. Adjust the constants in `HUDView` — corner radius, material, padding, shadow, and the drop-in animation — until they match. This is the one piece of the design that was deliberately left to be matched visually rather than specified.

- [ ] **Step 7: Commit**

```bash
git add App/Island/WaveformView.swift App/Island/IslandView.swift App/Island/HUDView.swift App/App/NotchVoiceApp.swift
git commit -m "feat: island UI with live waveform and HUD fallback"
```

---

## Task 13: Menu bar item, launch at login, and permission surfacing

**Files:**
- Create: `App/App/MenuBarController.swift`
- Create: `App/App/LaunchAtLogin.swift`
- Create: `App/Permissions/PermissionChecker.swift`
- Modify: `App/App/NotchVoiceApp.swift`

**Interfaces:**
- Consumes: `ModifierKey` / `BindingStore` (Tasks 3, 9), `Paster.isAccessibilityTrusted()` (Task 8)
- Produces:
  - `enum LaunchAtLogin { static var isEnabled: Bool { get set } }`
  - `struct PermissionStatus { let microphone: Bool; let inputMonitoring: Bool; let accessibility: Bool; var allGranted: Bool }`
  - `enum PermissionChecker { static func status() -> PermissionStatus; static func openSettings(for:) }`
  - `@MainActor final class MenuBarController` with `init(coordinator: DictationCoordinator)` and `func install()`

- [ ] **Step 1: Write LaunchAtLogin**

`App/App/LaunchAtLogin.swift`:

```swift
import ServiceManagement

/// Thin wrapper over SMAppService. Registering throws when the app is not in
/// a stable location (a DerivedData build, for instance), so failures are
/// reported rather than silently swallowed.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[NotchVoice] launch at login failed: %@",
                      error.localizedDescription)
            }
        }
    }
}
```

- [ ] **Step 2: Write PermissionChecker**

`App/Permissions/PermissionChecker.swift`:

```swift
import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid   // IOHIDCheckAccess — Input Monitoring status

struct PermissionStatus {
    let microphone: Bool
    let inputMonitoring: Bool
    let accessibility: Bool

    /// Only microphone and input monitoring are hard requirements —
    /// accessibility degrades to copy-only rather than breaking the app.
    var canDictate: Bool { microphone && inputMonitoring }
    var allGranted: Bool { microphone && inputMonitoring && accessibility }
}

enum PermissionChecker {

    enum Kind {
        case microphone
        case inputMonitoring
        case accessibility

        var settingsURL: URL {
            let base = "x-apple.systempreferences:com.apple.preference.security"
            switch self {
            case .microphone:
                return URL(string: "\(base)?Privacy_Microphone")!
            case .inputMonitoring:
                return URL(string: "\(base)?Privacy_ListenEvent")!
            case .accessibility:
                return URL(string: "\(base)?Privacy_Accessibility")!
            }
        }
    }

    static func status() -> PermissionStatus {
        PermissionStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
            accessibility: AXIsProcessTrusted()
        )
    }

    static func openSettings(for kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
```

- [ ] **Step 3: Write MenuBarController**

`App/App/MenuBarController.swift`:

```swift
import AppKit
import NotchVoiceCore

/// Status-bar item: the only chrome a background app gets. Shows permission
/// state, the current binding, and a way to quit.
@MainActor
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private let coordinator: DictationCoordinator

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "NotchVoice"
        )
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = MenuRefresher.shared
        MenuRefresher.shared.rebuild = { [weak self] in self?.rebuildItems(in: $0) }
        rebuildItems(in: menu)
        return menu
    }

    private func rebuildItems(in menu: NSMenu) {
        menu.removeAllItems()

        let binding = BindingStore.binding
        let header = NSMenuItem(
            title: "Hold \(binding.displayName) to dictate",
            action: nil, keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let status = PermissionChecker.status()
        addPermissionItem(to: menu, title: "Microphone",
                          granted: status.microphone, kind: .microphone)
        addPermissionItem(to: menu, title: "Input Monitoring",
                          granted: status.inputMonitoring, kind: .inputMonitoring)
        addPermissionItem(to: menu, title: "Accessibility (auto-paste)",
                          granted: status.accessibility, kind: .accessibility)

        menu.addItem(.separator())

        let launch = NSMenuItem(
            title: "Launch at Login",
            action: #selector(MenuActions.toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = MenuActions.shared
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit NotchVoice",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    private func addPermissionItem(
        to menu: NSMenu,
        title: String,
        granted: Bool,
        kind: PermissionChecker.Kind
    ) {
        let item = NSMenuItem(
            title: "\(granted ? "✓" : "✗")  \(title)",
            action: granted ? nil : #selector(MenuActions.openPermission(_:)),
            keyEquivalent: ""
        )
        item.target = granted ? nil : MenuActions.shared
        item.representedObject = kind
        item.isEnabled = !granted
        menu.addItem(item)
    }
}

/// Rebuilds the menu each time it opens so permission ticks are never stale.
private final class MenuRefresher: NSObject, NSMenuDelegate {
    static let shared = MenuRefresher()
    var rebuild: ((NSMenu) -> Void)?

    func menuWillOpen(_ menu: NSMenu) {
        rebuild?(menu)
    }
}

private final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func toggleLaunchAtLogin() {
        LaunchAtLogin.isEnabled.toggle()
    }

    @objc func openPermission(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? PermissionChecker.Kind else {
            return
        }
        if kind == .accessibility {
            Paster.promptForAccessibility()
        }
        PermissionChecker.openSettings(for: kind)
    }
}
```

- [ ] **Step 4: Request microphone access at launch and install the menu**

Replace `applicationDidFinishLaunching` in `App/App/NotchVoiceApp.swift`:

```swift
    private var coordinator: DictationCoordinator?
    private var island: IslandWindowController?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let coordinator = DictationCoordinator()
            let island = IslandWindowController(coordinator: coordinator)
            let menuBar = MenuBarController(coordinator: coordinator)

            coordinator.onPhaseChange = { phase in
                if phase == .recording {
                    island.moveToActiveScreen()
                }
            }

            menuBar.install()
            island.show()

            Task {
                // Prompts on first launch; a no-op once answered.
                _ = await PermissionChecker.requestMicrophone()
                coordinator.start()
            }

            self.coordinator = coordinator
            self.island = island
            self.menuBar = menuBar
        }
    }
```

- [ ] **Step 5: Build and verify**

```bash
xcodegen generate
xcodebuild -project NotchVoice.xcodeproj -scheme NotchVoice -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/NotchVoice-*/Build/Products/Debug/NotchVoice.app
```

| Test | Expected |
|---|---|
| Launch | Waveform icon appears in the menu bar; still no dock icon |
| Open the menu | Header reads "Hold Right ⌥ to dictate"; three permission rows with ✓ or ✗ |
| Click a ✗ permission row | The matching System Settings pane opens |
| Revoke a permission, reopen the menu | That row now shows ✗ without needing a relaunch |
| Toggle Launch at Login, reopen menu | Checkmark persists |
| Quit from the menu | App exits, island disappears |

Note that Launch at Login will not stick while running from DerivedData — `SMAppService` needs the app in a stable location. Copy the built `.app` to `/Applications` to verify it properly.

- [ ] **Step 6: Commit**

```bash
git add App/App/MenuBarController.swift App/App/LaunchAtLogin.swift App/Permissions/PermissionChecker.swift App/App/NotchVoiceApp.swift
git commit -m "feat: menu bar item, launch at login, permission surfacing"
```

---

## Task 14: Milestone acceptance and release

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything
- Produces: tag `v0.1.0`

- [ ] **Step 1: Run the full test suite**

```bash
cd Core && swift test
```

Expected: 34 tests, all passing.

- [ ] **Step 2: Build clean from scratch**

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/NotchVoice-*
xcodegen generate
xcodebuild -project NotchVoice.xcodeproj -scheme NotchVoice -configuration Release build
```

Expected: `** BUILD SUCCEEDED **` with no warnings you introduced.

- [ ] **Step 3: Install to /Applications and grant permissions**

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/NotchVoice-*/Build/Products/Release/NotchVoice.app /Applications/
open /Applications/NotchVoice.app
```

Grant Microphone, Input Monitoring, and Accessibility when prompted. Relaunch after granting Input Monitoring.

- [ ] **Step 4: Run the acceptance checklist**

Every row must pass. These are the spec's §13 manual checks.

**Core loop, in each of Slack, Cursor, Terminal, Safari, and TextEdit:**

| Test | Expected |
|---|---|
| Hold right-⌥, speak a sentence, release | Text appears at the cursor, correctly transcribed |
| Double-tap right-⌥, speak, tap again | Same, hands-free |
| Tap right-⌥ once and wait | Nothing happens, nothing pasted |

**Non-interference — the app must not disturb normal typing:**

| Test | Expected |
|---|---|
| Type `⌥ + o` in TextEdit | `ø` appears, no dictation triggered |
| Press `⌥ + ←` | Cursor jumps a word, no dictation triggered |
| Type a full paragraph normally | Every character appears, nothing dropped |
| Press left-⌥ and hold | Nothing happens |

**Clipboard safety:**

| Test | Expected |
|---|---|
| `echo SENTINEL \| pbcopy`, dictate, then `pbpaste` | Prints `SENTINEL` |
| Copy an image, dictate, then paste the image somewhere | Image still pastes intact |

**Displays:**

| Test | Expected |
|---|---|
| Dictate on the laptop screen | Island animates in the notch |
| Dictate on an external monitor | HUD capsule drops from the top |
| Unplug the monitor mid-session, dictate | Island reappears on the laptop screen |
| Dictate inside a fullscreen app | Island still visible |

**Degradation:**

| Test | Expected |
|---|---|
| Revoke Accessibility, dictate | Text is copied, island says so, nothing pasted |
| Hold and release immediately | "Too short", nothing pasted |
| Hold, say nothing, release after 2s | "Nothing heard" |
| Hold, speak, press `Esc` | Nothing pasted, island collapses |

If anything fails, fix it and re-run the whole checklist. Do not tag a release with a failing row.

- [ ] **Step 5: Update the changelog**

Replace the `[Unreleased]` section of `CHANGELOG.md` with:

```markdown
## [Unreleased]

## [0.1.0] — 2026-08-10

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
```

- [ ] **Step 6: Update the README status**

Replace the Status section of `README.md` with:

```markdown
## Status

v0.1.0 — core dictation loop working. Hold right-Option, speak, release.

Next: transcript cleanup via Foundation Models (0.2.0), custom vocabulary bias
(0.3.0), transcript history (0.4.0). See
[`docs/superpowers/specs/2026-08-06-notch-dictation-design.md`](docs/superpowers/specs/2026-08-06-notch-dictation-design.md).
```

- [ ] **Step 7: Commit and tag**

```bash
git add CHANGELOG.md README.md
git commit -m "chore: release v0.1.0"
git tag -a v0.1.0 -m "Core dictation loop"
git describe --tags
```

Expected: `v0.1.0`.

---

## Notes for the implementer

**Things that will waste your time if you do not know them:**

1. **TCC and code signing.** If Accessibility or Input Monitoring keeps getting revoked between builds, your signing identity is unstable. Check `DEVELOPMENT_TEAM` in `project.yml` is a real team ID. This presents as "my event tap randomly stopped working" and it is not a code bug.

2. **Input Monitoring needs a relaunch.** Granting it while the app is running does not take effect. Quit and reopen.

3. **The sandbox must stay off.** If you see `AXIsProcessTrusted()` returning false despite the app being ticked in Settings, check that `com.apple.security.app-sandbox` is still `false` in the entitlements.

4. **`xcodegen generate` after every file you add.** New files under `App/` are picked up by the source glob, but only when the project is regenerated. A "file not found" build error usually means you forgot.

5. **The first WhisperKit run downloads ~630MB.** It is not hung.

6. **Never make the event tap do work in its callback.** It posts to the main actor and returns. macOS disables taps whose callbacks are slow, and a disabled tap means the hotkey silently stops working.
