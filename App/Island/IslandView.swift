import SwiftUI
import NotchVoiceCore

/// The island: a black shape pinned to the top of the screen that widens in
/// place around the notch.
///
/// **Every display gets the same silhouette.** A screen with no physical cutout
/// draws one at the dimensions borrowed from a screen that has — a pill on the
/// monitor and a notch on the laptop would be two appearances for one app.
///
/// **Two axes, two meanings.** Horizontal is status — the island grows sideways
/// into the strips either side of the notch, and that is all this file does.
/// Vertical is content: the span below the cutout is reserved for the transcript
/// panel and nothing here may take it.
///
/// **It never grows taller than the cutout.** The display has no pixels behind
/// the notch, so anything drawn there is invisible. The wings are the whole
/// trick: either side is real screen, so state goes left, live audio goes
/// right, and the middle stays empty because the middle is a hole.
///
/// **The wings are unequal and sized to their contents**, from `IslandMetrics`,
/// where a test asserts the meter fits the wing holding it.
@MainActor
struct IslandView: View {
    var coordinator: DictationCoordinator

    /// The cutout this display draws around — its own if it has one, otherwise
    /// the dimensions borrowed from a display that does. See
    /// `NotchGeometry.effectiveNotch`.
    let notchSize: CGSize

    /// Whether that cutout is a hole in the display or one this app is drawing.
    ///
    /// The difference is not cosmetic. A real cutout is always there, so the
    /// island only ever changes width around it. A drawn one has to arrive and
    /// leave, and cannot sit on the wallpaper at rest.
    let isPhysical: Bool

    /// Horizontal distance from the window's centre to the notch's centre.
    ///
    /// The island cannot simply centre itself in the window. `NotchGeometry`
    /// was fixed in task 5 precisely because the cutout is not guaranteed to
    /// be centred in the frame, and centring the view would reintroduce that
    /// assumption one layer up, where the geometry tests cannot see it. Zero
    /// on hardware where the notch *is* centred, which is every machine this
    /// has been run on — so this is insurance, not an observed fix.
    let notchCenterOffset: CGFloat

    init(
        coordinator: DictationCoordinator,
        notchSize: CGSize,
        isPhysical: Bool,
        notchCenterOffset: CGFloat = 0
    ) {
        self.coordinator = coordinator
        self.notchSize = notchSize
        self.isPhysical = isPhysical
        self.notchCenterOffset = notchCenterOffset
    }

    /// Matches the physical cutout's own bottom corners.
    private static let bottomRadius: CGFloat = 14
    /// How far the island flares out into the menu bar at its top edge, so the
    /// black flows into the bar instead of meeting it at a hard 90° join.
    /// Proportions taken from boring.notch's `NotchShape` (top 6 / bottom 14),
    /// where the bottom is markedly rounder than the top.
    private static let concaveRadius: CGFloat = 8

    private static let idleIconSize: CGFloat = 9
    private static let iconSize: CGFloat = 12

    private var phase: DictationCoordinator.Phase { coordinator.phase }
    private var isDormant: Bool { phase == .dormant }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Expanding answers a physical key press, so it carries a little
    /// overshoot — Apple's shipped drawer/sheet spring, damping 0.8 and
    /// response 0.3. Collapsing answers nothing: it is the system tidying up
    /// after itself, so it is critically damped and never bounces. One spring
    /// for both directions made the island wobble on its way out, which drew
    /// the eye at exactly the moment there was nothing left to look at.
    private var transition: Animation {
        if reduceMotion { return .easeOut(duration: 0.2) }
        return isDormant
            ? .spring(response: 0.32, dampingFraction: 1.0)
            : .spring(response: 0.3, dampingFraction: 0.78)
    }

    var body: some View {
        VStack(spacing: 8) {
            island
            panel
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(transition, value: phase)
        .animation(.smooth(duration: 0.3), value: coordinator.readiness)
        .allowsHitTesting(false)
        // The island is a status readout in a window that never takes focus, so
        // without this VoiceOver has nothing to report about a dictation at all.
        // That was survivable while every state had a sound; it stopped being so
        // when the failure cue was removed.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notch Voice")
        .accessibilityValue(spokenState)
    }

    /// The sentence-length half of the island, for the phases that have one.
    ///
    /// Offset by the notch centre alone, *not* by `cutoutCorrection`: that
    /// correction exists to keep the island's reserved span over the physical
    /// hole as its unequal wings resize, and the panel has no wings and no hole
    /// to avoid. Applying it here would slide the panel sideways every time the
    /// island above it changed width.
    @ViewBuilder
    private var panel: some View {
        if let message = phase.panelMessage {
            NotchPanelView(message: message)
                .offset(x: notchCenterOffset)
                .transition(panelArrival)
                .id(message)
        }
    }

    /// Down out of the notch, and back up into it. Never a fade in place — see
    /// `NotchPanelView`.
    private var panelArrival: AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: .top).combined(with: .opacity)
    }

    /// What VoiceOver says the app is doing.
    private var spokenState: String {
        switch phase {
        case .dormant:
            switch coordinator.readiness {
            case .loadingModel: "Loading"
            case .ready: "Ready"
            case .needsPermission: "Needs permission"
            case .modelUnavailable: "Speech model unavailable"
            }
        case .recording:
            coordinator.inputTooQuiet ? "Recording, but hearing almost nothing" : "Recording"
        case .locked: "Recording hands-free"
        case .transcribing: "Transcribing"
        case .polishing: "Tidying up"
        case .done: "Pasted"
        // The panel announces itself when it appears, so these say only what the
        // state is; the detail is not repeated here.
        case .copied: "Copied to the clipboard"
        case .tooShort: "Too short"
        case let .error(failure): failure.short
        }
    }

    /// One presentation for every display: the same shape at the same size, the
    /// only difference being that a drawn cutout has to arrive.
    @ViewBuilder
    private var island: some View {
        if isSynthetic && isDormant {
            // Nothing at all. On the laptop the resting island is a small wing
            // beside a hole that exists regardless; here there is no hole, so
            // the same treatment would leave a black block parked on the
            // wallpaper for the entire session.
            EmptyView()
        } else {
            notchIsland(notchSize: notchSize)
                .offset(x: notchCenterOffset + cutoutCorrection)
                .transition(arrival)
        }
    }

    private var isSynthetic: Bool { !isPhysical }

    /// How the shape enters and leaves.
    ///
    /// `.identity` on a real notch, because nothing enters — the cutout is
    /// already there and only its wings change width. A drawn notch slides in
    /// from the edge it belongs to, and leaves the same way, so it reads as
    /// arriving from off-screen rather than materialising in place.
    private var arrival: AnyTransition {
        guard isSynthetic else { return .identity }
        if reduceMotion { return .opacity }
        return .move(edge: .top).combined(with: .opacity)
    }

    // MARK: - Wings

    private var leadingWing: CGFloat {
        isDormant ? IslandMetrics.idleLeadingWing : IslandMetrics.expandedLeadingWing
    }

    private var trailingWing: CGFloat {
        switch phase {
        case .dormant: 0
        case .recording, .locked, .transcribing, .polishing:
            IslandMetrics.waveformTrailingWing
        case .done, .copied, .tooShort: IslandMetrics.labelTrailingWing
        case .error: IslandMetrics.messageTrailingWing
        }
    }

    /// Keeps the cutout span over the physical notch as the wings change size.
    ///
    /// Load-bearing, and only necessary because the wings are unequal. A
    /// centred island puts its own midpoint on the notch's midpoint, but with
    /// asymmetric wings the *cutout span* sits `(leading − trailing) / 2` away
    /// from that midpoint. Without this correction the reserved span drifts off
    /// the real hole every time the island changes width, and content slides
    /// under the notch — the exact bug the wing layout was built to fix.
    private var cutoutCorrection: CGFloat {
        (trailingWing - leadingWing) / 2
    }

    // MARK: - Notch presentation

    private func notchIsland(notchSize: CGSize) -> some View {
        HStack(spacing: 0) {
            leadingIcon
                .frame(
                    width: IslandMetrics.contentWidth(inWing: leadingWing),
                    alignment: .leading
                )
                .padding(.leading, IslandMetrics.wingPadding)

            // The cutout. Reserved and deliberately empty — there is no screen
            // here, so anything placed in this span cannot be seen.
            Color.clear.frame(width: notchSize.width)

            // Skipped entirely at rest rather than given a zero width: a
            // zero-width frame would still carry its padding and quietly add
            // 8pt the width maths does not know about.
            if trailingWing > 0 {
                trailing
                    .frame(
                        width: IslandMetrics.contentWidth(inWing: trailingWing),
                        alignment: .trailing
                    )
                    .padding(.trailing, IslandMetrics.wingPadding)
            }
        }
        .frame(
            width: IslandMetrics.islandWidth(
                notchWidth: notchSize.width,
                leadingWing: leadingWing,
                trailingWing: trailingWing
            ),
            height: notchSize.height   // never changes
        )
        // Padded by the flare on each side so the body keeps its width and the
        // concave corners have room to live outside it.
        .padding(.horizontal, Self.concaveRadius)
        .background(.black, in: shape)
        .clipShape(shape)
    }

    private var shape: NotchIslandShape {
        NotchIslandShape(
            bottomRadius: Self.bottomRadius,
            concaveRadius: Self.concaveRadius
        )
    }

    // MARK: - Left slot: what is happening

    /// One `Image`, not a switch over several.
    ///
    /// This is what makes the most frequent transition in the app free: at rest
    /// and while recording the symbol is the same `mic.fill`, so pressing the
    /// key does not replace one view with another — the glyph already on screen
    /// brightens and turns red. Nothing enters, nothing leaves, nothing to get
    /// wrong. Where the symbol genuinely does change, SwiftUI morphs it.
    private var leadingIcon: some View {
        Image(systemName: iconSymbol)
            .font(.system(size: isDormant ? Self.idleIconSize : Self.iconSize,
                          weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconTint)
            // Replaces the previous `.id(name)` trick, which forced SwiftUI to
            // treat each phase's glyph as a distinct view so a scale/opacity
            // transition would run. That cross-faded two separate images;
            // this morphs one symbol into the next.
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .symbolEffect(.pulse, isActive: isLoadingAtRest && !reduceMotion)
            .symbolEffect(
                .variableColor.iterative,
                isActive: isWorking && !reduceMotion
            )
            // Decorative: the same information is on the container's
            // accessibility value, in words rather than as a glyph.
            .accessibilityHidden(true)
    }

    /// Decoding or tidying — both are "the app is busy with what you said", and
    /// both carry the same variable-colour animation.
    private var isWorking: Bool {
        phase == .transcribing || phase == .polishing
    }

    private var iconSymbol: String {
        switch phase {
        // Same symbol on purpose — see `leadingIcon`.
        case .dormant, .recording: "mic.fill"
        case .locked: "lock.fill"
        // Carries the variable-colour loading animation above; the frozen
        // meter in the right wing says "heard you", this says "working".
        case .transcribing: "ellipsis"
        // Distinct from `.transcribing` so the two halves of the wait are
        // legible as different things: the transcript exists by now, and what
        // is happening is a rewrite.
        case .polishing: "wand.and.sparkles"
        case .done: "checkmark.circle.fill"
        case .copied: "doc.on.clipboard.fill"
        case .tooShort: "timer"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    /// Readiness rides the resting glyph's colour rather than a state of its
    /// own. Nothing else on screen can say "the model is still loading" or "a
    /// permission was revoked" — the menu bar can, but only once opened, and
    /// the first the user would otherwise hear of it is a dictation failing.
    private var iconTint: Color {
        switch phase {
        case .dormant:
            switch coordinator.readiness {
            case .loadingModel: .white.opacity(0.22)
            case .ready: .white.opacity(0.35)
            case .needsPermission, .modelUnavailable: .orange.opacity(0.9)
            }
        case .recording:
            // Amber rather than red once the input has been too quiet to
            // transcribe for a while. The waveform alone could not say this:
            // flat bars look the same whether the user has paused mid-sentence
            // or is inaudible, and the failure only surfaced afterwards as
            // "Nothing heard".
            coordinator.inputTooQuiet ? .orange : .red
        case .locked: .orange
        case .transcribing, .polishing: .white.opacity(0.85)
        case .done: .green
        case .copied: .blue
        case .tooShort: .white.opacity(0.65)
        case .error: .orange
        }
    }

    private var isLoadingAtRest: Bool {
        isDormant && coordinator.readiness == .loadingModel
    }

    // MARK: - Right slot: the detail

    /// Lives in `IslandTrailingContent`, not here. It switched over every phase
    /// and was the longest thing in this file; as its own view it re-evaluates
    /// independently of the island around it.
    private var trailing: some View {
        IslandTrailingContent(
            phase: phase,
            levels: coordinator.levels,
            inputTooQuiet: coordinator.inputTooQuiet
        )
    }
}
