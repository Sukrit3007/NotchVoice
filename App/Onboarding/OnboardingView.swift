import SwiftUI

/// The first-run flow.
///
/// One screen per thing being asked for, rather than a single page of four
/// switches. Each permission involves a system dialog and usually a trip to
/// System Settings, and a list of four makes it impossible to tell which one the
/// dialog that just appeared belongs to.
@MainActor
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 44)
                .padding(.top, 44)

            footer
        }
        .frame(width: 560, height: 460)
        .animation(transition, value: model.step)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    /// Critically damped. Moving between steps is the interface tidying up after
    /// a click, not a gesture the user threw — overshoot here would draw the eye
    /// to the transition rather than to what arrived.
    private var transition: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .microphone, .inputMonitoring, .accessibility: permission
        case .model: modelStep
        case .tryIt: tryIt
        case .done: done
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        step(
            symbol: "waveform",
            title: "Hold a key. Say something.",
            body: "Notch Voice types what you say, wherever your cursor is.\n\n"
                + "Everything happens on this Mac. Your voice is transcribed here and "
                + "never written to disk, transcripts stay local, and there is no "
                + "account. The only time it uses the network is once, in a moment, "
                + "to fetch the speech model."
        )
    }

    @ViewBuilder
    private var permission: some View {
        if let kind = model.step.permission {
            let granted = model.status.isGranted(kind)
            step(
                symbol: granted ? "checkmark.circle.fill" : kind.symbol,
                tint: granted ? .green : .accentColor,
                title: granted ? "\(kind.title) is on" : "Allow \(kind.title)",
                body: kind.onboardingExplanation
            ) {
                if !granted {
                    Button("Open System Settings") { model.request(kind) }
                        .buttonStyle(.borderedProminent)
                    // Polling is what updates the tick, so there is nothing to
                    // press afterwards — said out loud because a screen that
                    // looks inert is a screen people click twice.
                    Text("This screen updates by itself once you allow it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modelStep: some View {
        step(
            symbol: "arrow.down.circle",
            title: "Getting the speech model",
            body: "This is the part that does the listening. It downloads once and "
                + "then works offline forever."
        ) {
            switch model.modelPhase {
            case let .downloading(fraction):
                VStack(spacing: 6) {
                    ProgressView(value: fraction)
                        .frame(width: 260)
                    Text("Downloading — \(Int(fraction * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            case .loading:
                // Deliberately indeterminate. CoreML compilation reports no
                // progress, and a bar parked at 90% for twelve seconds is worse
                // than one that admits it does not know.
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Getting it ready — about ten seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var tryIt: some View {
        step(
            symbol: "keyboard",
            title: "Try it here",
            body: "Click the box, hold \(BindingStore.binding.displayName), say "
                + "anything, then let go."
        ) {
            // A real text field, deliberately. The dictation lands here through
            // the same focus capture, clipboard round-trip and paste as anywhere
            // else — so this proves delivery works rather than depicting it.
            TextEditor(text: $model.scratch)
                .font(.body)
                .frame(width: 380, height: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator)
                )

            if model.hasDictated {
                Label("That worked", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
    }

    private var done: some View {
        step(
            symbol: "checkmark.circle.fill",
            tint: .green,
            title: "You're set",
            body: "Hold \(BindingStore.binding.displayName) anywhere to dictate. "
                + "Press Space while holding it to keep recording hands-free.\n\n"
                + "Notch Voice lives in the menu bar — that's where History, your "
                + "custom words and every setting are."
        )
    }

    // MARK: - Chrome

    @ViewBuilder
    private func step(
        symbol: String,
        tint: Color = .accentColor,
        title: String,
        body text: String,
        @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)

            Text(title)
                // Tight leading and negative tracking, because large text reads
                // as too loosely set at its default.
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .multilineTextAlignment(.center)

            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            extra()
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if model.step.previous != nil, model.step != .done {
                    Button("Back") { model.goBack() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                dots
                Spacer()

                if model.step == .done {
                    Button("Start Dictating") { onFinish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.step == .tryIt && !model.hasDictated ? "Skip" : "Continue") {
                        model.advance()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // Balances the Back button so the dots stay centred in the window rather
        // than drifting as the left side appears and disappears.
        .frame(minHeight: 56)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.progressSteps) { step in
                Circle()
                    .fill(step <= model.step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel(
            "Step \(model.step.rawValue + 1) of \(OnboardingStep.progressSteps.count)")
    }
}
