import SwiftUI

/// The feedback cues, and a way to actually hear them.
///
/// Previews are the whole reason this is a pane rather than one line in
/// General. A switch labelled "Play sounds" asks the user to decide about five
/// tones they have heard in passing, mid-dictation, while looking at a text
/// field. Letting them play each one on demand is the only way that choice is
/// informed.
@MainActor
struct SoundPane: View {
    /// Read in `task`, for the same reason as `GeneralPane`: a `@State` default
    /// runs on every struct init.
    @State private var playSounds = true

    var body: some View {
        Form {
            Section {
                Toggle("Play sounds", isOn: $playSounds)
                    .onChange(of: playSounds, applyPlaySounds)
            } footer: {
                Text("Short tones mark the start and end of a dictation, and "
                     + "the moment the text lands — what the island cannot tell "
                     + "you while you are looking at the text field you are "
                     + "dictating into. Nothing plays when a dictation fails; "
                     + "the notch says so instead.")
            }

            Section("Preview") {
                ForEach(Cues.Cue.allCases) { cue in
                    LabeledContent(cue.title) {
                        Button("Play") { Cues.play(cue) }
                    }
                }
            }
            // Not hidden. A greyed-out list still says what you are turning back
            // on, where an empty section would leave the switch unexplained.
            .disabled(!playSounds)
        }
        .formStyle(.grouped)
        .task { playSounds = SoundPreference.isEnabled }
    }

    /// Answers the switch with the thing it controls. Turning sound *off* stays
    /// silent, which is its own correct confirmation.
    private func applyPlaySounds(_ previous: Bool, _ enabled: Bool) {
        SoundPreference.isEnabled = enabled
        if enabled { Cues.play(.done) }
    }
}

#Preview {
    SoundPane()
        .frame(width: 460, height: 380)
}
