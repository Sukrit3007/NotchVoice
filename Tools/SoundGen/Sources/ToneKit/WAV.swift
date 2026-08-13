import Foundation

/// Minimal 16-bit PCM WAV writer.
///
/// Hand-rolled rather than reached for via AVFoundation so this tool stays a
/// plain SPM package with no framework linkage — it has to run from a build
/// script, not from an app.
public enum WAV {

    public static func encode(_ samples: [Float], sampleRate: Double) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataBytes = UInt32(samples.count * Int(bitsPerSample / 8))

        var data = Data()
        data.append(ascii: "RIFF")
        data.append(le: UInt32(36 + Int(dataBytes)))
        data.append(ascii: "WAVE")

        data.append(ascii: "fmt ")
        data.append(le: UInt32(16))          // PCM header length
        data.append(le: UInt16(1))           // format: PCM
        data.append(le: channels)
        data.append(le: UInt32(sampleRate))
        data.append(le: byteRate)
        data.append(le: blockAlign)
        data.append(le: bitsPerSample)

        data.append(ascii: "data")
        data.append(le: dataBytes)
        for sample in samples {
            // Clamped before scaling: a value even slightly past ±1 wraps to the
            // opposite rail as a loud click, which is the exact artefact Tone's
            // envelope exists to prevent.
            let clamped = max(-1, min(1, sample))
            data.append(le: Int16(clamped * 32_767))
        }
        return data
    }
}

private extension Data {
    mutating func append(ascii text: String) {
        append(contentsOf: text.utf8)
    }

    mutating func append<T: FixedWidthInteger>(le value: T) {
        // Qualified: unqualified, this resolves to `Data.withUnsafeBytes` — the
        // instance method that reads the buffer — rather than the global one
        // that writes an integer's bytes.
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
