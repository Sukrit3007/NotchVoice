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
