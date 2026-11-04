import Accelerate
import Foundation

/// A streaming, rational-ratio, polyphase windowed-sinc sample-rate converter for mono audio.
///
/// * **Streaming**: feed arbitrary-sized chunks; the output is identical (bit for bit) no matter
///   how the input is chunked, because all filter state is carried between calls.
/// * **Allocation-free in steady state**: the filter table is built once; `process` appends to a
///   caller-owned array whose capacity the caller reuses.
/// * **Quality**: a Kaiser-windowed sinc with `zeroCrossings` lobes on each side and a cutoff at
///   90 % of the lower Nyquist frequency, so the content that matters for speech (< 7 kHz when
///   producing 16 kHz audio) passes essentially flat while energy that would alias is rejected.
///   The unit tests measure passband gain and alias rejection rather than assuming them.
///
/// Not thread-safe; the owning pipeline serialises access.
public final class StreamingResampler {
    public let inputRate: Double
    public let outputRate: Double

    /// Interpolation factor, decimation factor (after reducing the ratio).
    private let up: Int
    private let down: Int
    /// The kernel spans `2 * halfWidth` input samples.
    private let halfWidth: Int
    private let taps: Int
    private let table: [Float]

    private var history: [Float]
    /// Position of the next output sample, in 1/`up` input-sample units relative to `history[0]`.
    private var position: Int

    public static let defaultZeroCrossings = 20
    public static let maximumPhases = 1024
    private static let cutoffScale = 0.9
    private static let kaiserBeta = 9.0

    /// True when no conversion is needed.
    public var isPassthrough: Bool { up == down }

    /// Look-ahead of the filter, in input samples (the converter's algorithmic delay).
    public var latencyInputSamples: Int { isPassthrough ? 0 : halfWidth }

    public init(inputRate: Double, outputRate: Double, zeroCrossings: Int = StreamingResampler.defaultZeroCrossings) {
        precondition(inputRate > 0 && outputRate > 0, "sample rates must be positive")
        self.inputRate = inputRate
        self.outputRate = outputRate

        let (up, down) = Self.reducedRatio(inputRate: inputRate, outputRate: outputRate)
        self.up = up
        self.down = down

        if up == down {
            halfWidth = 0
            taps = 0
            table = []
            history = []
            position = 0
            return
        }

        let cutoffHz = 0.5 * min(inputRate, outputRate) * Self.cutoffScale
        let halfWidth = max(8, Int((Double(zeroCrossings) * inputRate / (2 * cutoffHz)).rounded(.up)))
        let taps = 2 * halfWidth
        self.halfWidth = halfWidth
        self.taps = taps
        self.table = Self.makeTable(
            up: up, halfWidth: halfWidth, cutoffCyclesPerSample: cutoffHz / inputRate, beta: Self.kaiserBeta
        )
        self.history = []
        self.position = 0
        history.reserveCapacity(taps + 16_384)
        reset()
    }

    /// Discards filter state; the next input starts a fresh stream.
    public func reset() {
        guard !isPassthrough else { return }
        history.removeAll(keepingCapacity: true)
        history.append(contentsOf: repeatElement(0, count: halfWidth - 1))
        position = (halfWidth - 1) * up
    }

    /// Consumes `input` and appends every newly computable output sample to `output`.
    public func process(_ input: UnsafeBufferPointer<Float>, appendingTo output: inout [Float]) {
        if isPassthrough {
            output.append(contentsOf: input)
            return
        }
        history.append(contentsOf: input)

        let count = history.count
        var position = self.position
        history.withUnsafeBufferPointer { historyPointer in
            table.withUnsafeBufferPointer { tablePointer in
                guard let historyBase = historyPointer.baseAddress, let tableBase = tablePointer.baseAddress else { return }
                while true {
                    let index = position / up
                    // The kernel for this output reads history[index - halfWidth + 1 ... index + halfWidth].
                    if index + halfWidth >= count { break }
                    let phase = position - index * up
                    var accumulator: Float = 0
                    vDSP_dotpr(
                        historyBase + (index - halfWidth + 1), 1,
                        tableBase + phase * taps, 1,
                        &accumulator, vDSP_Length(taps)
                    )
                    output.append(accumulator)
                    position += down
                }
            }
        }

        // Drop history the next output can no longer reach, and rebase the position.
        let keepFrom = position / up - halfWidth + 1
        if keepFrom > 0 {
            history.removeFirst(keepFrom)
            position -= keepFrom * up
        }
        self.position = position
    }

    public func process(_ input: [Float], appendingTo output: inout [Float]) {
        input.withUnsafeBufferPointer { process($0, appendingTo: &output) }
    }

    // MARK: - Design

    static func reducedRatio(inputRate: Double, outputRate: Double) -> (up: Int, down: Int) {
        let inputHz = max(1, Int(inputRate.rounded()))
        let outputHz = max(1, Int(outputRate.rounded()))
        let divisor = greatestCommonDivisor(inputHz, outputHz)
        let up = outputHz / divisor
        let down = inputHz / divisor
        if up <= maximumPhases { return (up, down) }
        // Unusual hardware rate: approximate the ratio so the phase table stays small. The
        // resulting rate error is far below anything audible or relevant to a wake-word model.
        let approximation = bestRational(outputRate / inputRate, maximumNumerator: maximumPhases)
        return approximation.denominator > 0 ? (approximation.numerator, approximation.denominator) : (1, 1)
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (abs(a), abs(b))
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }

    static func bestRational(_ x: Double, maximumNumerator: Int) -> (numerator: Int, denominator: Int) {
        var previousNumerator = 0, numerator = 1
        var previousDenominator = 1, denominator = 0
        var value = x
        for _ in 0..<32 {
            let term = Int(value.rounded(.down))
            let nextNumerator = term * numerator + previousNumerator
            let nextDenominator = term * denominator + previousDenominator
            if nextNumerator > maximumNumerator { break }
            (previousNumerator, numerator) = (numerator, nextNumerator)
            (previousDenominator, denominator) = (denominator, nextDenominator)
            let fraction = value - Double(term)
            if fraction < 1e-9 { break }
            value = 1 / fraction
        }
        return (numerator, denominator)
    }

    private static func makeTable(up: Int, halfWidth: Int, cutoffCyclesPerSample: Double, beta: Double) -> [Float] {
        let taps = 2 * halfWidth
        var table = [Float](repeating: 0, count: up * taps)
        let normaliser = besselI0(beta)
        var row = [Double](repeating: 0, count: taps)

        for phase in 0..<up {
            let fraction = Double(phase) / Double(up)
            var sum = 0.0
            for k in 0..<taps {
                // Distance (in input samples) from the output instant to this tap.
                let tau = Double(k - halfWidth + 1) - fraction
                let argument = 2 * cutoffCyclesPerSample * tau
                let sinc = abs(argument) < 1e-12 ? 1.0 : sin(Double.pi * argument) / (Double.pi * argument)
                let u = tau / Double(halfWidth)
                let window = abs(u) >= 1 ? 0.0 : besselI0(beta * (1 - u * u).squareRoot()) / normaliser
                let weight = 2 * cutoffCyclesPerSample * sinc * window
                row[k] = weight
                sum += weight
            }
            // Normalise each phase to unity DC gain.
            let scale = sum == 0 ? 1 : 1 / sum
            for k in 0..<taps {
                table[phase * taps + k] = Float(row[k] * scale)
            }
        }
        return table
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let quarterSquare = x * x / 4
        var k = 1.0
        while term > 1e-14 * sum {
            term *= quarterSquare / (k * k)
            sum += term
            k += 1
        }
        return sum
    }
}
