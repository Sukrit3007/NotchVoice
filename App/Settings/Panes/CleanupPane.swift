import SwiftUI

/// What happens to a transcript between hearing it and pasting it.
///
/// Its own pane rather than a row in Dictation, because it is now a choice with
/// a 2.3GB download attached rather than a fact to report. Cleanup is also the
/// one part of the pipeline that can be silently absent: with nothing available,
/// dictation still works and the text is simply rougher, which is impossible to
/// tell from "the cleanup ran and wasn't very good".
@MainActor
struct CleanupPane: View {
    var coordinator: DictationCoordinator

    @State private var installer = LocalModelInstaller.shared
    @State private var usesLocalModel = LocalPolishPreference.isEnabled
    @State private var isConfirmingRemoval = false

    var body: some View {
        Form {
            Section {
                SettingsStatusRow(
                    symbol: activeSymbol, tint: activeTint,
                    title: activeTitle, detail: activeDetail
                )
            } header: {
                Text("Right now")
            }

            Section {
                switch installer.state {
                case .absent:
                    LabeledContent("Better formatting") {
                        Button("Download — \(LocalPolishModel.approximateSize)") {
                            installer.install()
                        }
                    }

                case let .downloading(fraction):
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: fraction)
                        HStack {
                            Text("Downloading — \(Int(fraction * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { installer.cancel() }
                                .buttonStyle(.link)
                        }
                    }

                case .installed:
                    Toggle("Use the downloaded model", isOn: $usesLocalModel)
                    LabeledContent("On disk", value: sizeOnDisk)
                    Button("Remove Model", role: .destructive) {
                        isConfirmingRemoval = true
                    }

                case let .failed(reason):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Button("Try Again") { installer.install() }
                    }
                }
            } header: {
                Text("Local model")
            } footer: {
                Text(localModelExplanation)
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: installer.state)
        .onChange(of: usesLocalModel) { _, new in
            LocalPolishPreference.isEnabled = new
            // Loads the weights now rather than on the next dictation, so the
            // several seconds that costs are spent while the user is looking at
            // the switch they just flipped.
            coordinator.prepareCleanup()
        }
        .confirmationDialog(
            "Remove the cleanup model?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                installer.remove()
                usesLocalModel = false
            }
        } message: {
            Text(
                "Frees \(sizeOnDisk). Transcripts go back to being tidied by "
                + "Apple Intelligence. You can download it again later."
            )
        }
    }

    // MARK: - What is actually running

    /// Deliberately describes the backend in use, not the one preferred. The two
    /// come apart the moment Apple Intelligence is switched off or the weights
    /// are deleted from the Finder, and that is exactly when a settings screen
    /// asserting the preference would be lying.
    private var usesLocal: Bool {
        usesLocalModel && installer.state == .installed
    }

    private var activeSymbol: String {
        usesLocal || coordinator.polishAvailability == .available
            ? "wand.and.sparkles" : "text.alignleft"
    }

    private var activeTint: Color {
        usesLocal || coordinator.polishAvailability == .available ? .accentColor : .secondary
    }

    private var activeTitle: String {
        if usesLocal { return "Tidying with the local model" }
        if coordinator.polishAvailability == .available { return "Tidying with Apple Intelligence" }
        return "Not tidying transcripts"
    }

    private var activeDetail: String {
        if usesLocal {
            return "Filler words are removed, punctuation is fixed, and the text "
                + "is broken into paragraphs and lists. Adds a couple of seconds "
                + "before the text appears."
        }
        if let explanation = coordinator.polishAvailability.explanation {
            return explanation
        }
        return "Filler words and stray punctuation are cleaned up on-device "
            + "before pasting, when that can be done quickly enough not to hold "
            + "the paste up."
    }

    private var localModelExplanation: String {
        "A \(LocalPolishModel.approximateSize) language model that runs entirely on "
        + "this Mac, downloaded once. It formats better than Apple Intelligence — "
        + "paragraphs where you change subject, lists where you list things — and "
        + "costs a couple of seconds per dictation and about "
        + "\(LocalPolishModel.approximateMemory) of memory while it's in use."
    }

    /// Read on demand rather than stored: the download is still growing while
    /// this pane is open, and a number captured at `onAppear` would be wrong by
    /// the time anyone read it.
    private var sizeOnDisk: String {
        ByteCountFormatStyle(style: .file).format(LocalPolishModel.bytesOnDisk())
    }
}

#Preview {
    // See PermissionsPane's preview: constructing a coordinator here starts
    // nothing.
    CleanupPane(coordinator: DictationCoordinator())
        .frame(width: 460, height: 460)
}
