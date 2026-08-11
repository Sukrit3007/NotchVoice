import SwiftUI

/// The island itself: a shape pinned to the top of the strip window that
/// changes size and contents with the dictation phase.
///
/// On a notched screen it starts exactly the size of the physical notch, so at
/// rest it is invisible — it *is* the notch. On other screens it renders as a
/// HUD capsule that is fully hidden at rest.
@MainActor
struct IslandView: View {
    @ObservedObject var coordinator: DictationCoordinator
    /// Physical notch size, or nil on screens without one.
    let notchSize: CGSize?
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
        notchSize: CGSize?,
        notchCenterOffset: CGFloat = 0
    ) {
        self.coordinator = coordinator
        self.notchSize = notchSize
        self.notchCenterOffset = notchCenterOffset
    }

    private var isDormant: Bool { coordinator.phase == .dormant }

    private let animation: Animation = .interactiveSpring(
        duration: 0.42, extraBounce: 0.22, blendDuration: 0.1
    )

    var body: some View {
        VStack(spacing: 0) {
            if let notchSize {
                notchIsland(notchSize: notchSize)
                    .offset(x: notchCenterOffset)
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
