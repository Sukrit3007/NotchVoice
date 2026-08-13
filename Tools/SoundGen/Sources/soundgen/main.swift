import Foundation
import ToneKit

// Renders the feedback cues to .wav. Run from the repo root:
//
//     swift run --package-path Tools/SoundGen soundgen App/Feedback/Sounds
//
// Output is committed — the app loads .wav files at runtime and never
// synthesises anything.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: soundgen <output-directory>\n".utf8))
    exit(1)
}

let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for cue in CueSet.all {
    let url = directory.appendingPathComponent(cue.fileName).appendingPathExtension("wav")
    let data = WAV.encode(cue.samples, sampleRate: Tone.sampleRate)
    try data.write(to: url)

    let seconds = Double(cue.samples.count) / Tone.sampleRate
    let peak = cue.samples.map(abs).max() ?? 0
    print(String(format: "%-16s %5.0fms  peak %.3f  %6d bytes",
                 (cue.fileName as NSString).utf8String!, seconds * 1000, peak, data.count))
}
