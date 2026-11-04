import Foundation
import Testing
@testable import WakeWordKit

/// Measures the converter instead of assuming it: gain in the passband, rejection of energy
/// that would alias, and exact chunk-size independence (the property streaming depends on).
struct StreamingResamplerTests {
    // MARK: Helpers

    static func sine(frequency: Double, sampleRate: Double, count: Int, amplitude: Double = 0.5) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    /// RMS over the steady-state middle of `samples`, skipping filter start-up and tail.
    static func steadyStateRMS(_ samples: [Float]) -> Double {
        let margin = samples.count / 5
        let middle = samples[margin..<(samples.count - margin)]
        let sum = middle.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(middle.count)).squareRoot()
    }

    static func resample(_ input: [Float], from: Double, to: Double, chunk: Int? = nil) -> [Float] {
        let resampler = StreamingResampler(inputRate: from, outputRate: to)
        var output: [Float] = []
        if let chunk {
            var index = 0
            while index < input.count {
                let end = min(input.count, index + chunk)
                resampler.process(Array(input[index..<end]), appendingTo: &output)
                index = end
            }
        } else {
            resampler.process(input, appendingTo: &output)
        }
        return output
    }

    static func decibels(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-12)) }

    // MARK: Passthrough and ratios

    @Test func identicalRatesPassSamplesThroughUntouched() {
        let input = Self.sine(frequency: 440, sampleRate: 16_000, count: 1_000)
        let output = Self.resample(input, from: 16_000, to: 16_000)
        #expect(output == input)
        #expect(StreamingResampler(inputRate: 16_000, outputRate: 16_000).isPassthrough)
    }

    @Test(arguments: [
        (48_000.0, 16_000.0), (44_100.0, 16_000.0), (32_000.0, 16_000.0), (24_000.0, 16_000.0),
        (96_000.0, 16_000.0), (22_050.0, 16_000.0), (8_000.0, 16_000.0),
    ])
    func outputLengthMatchesTheRateRatio(rates: (Double, Double)) {
        let (from, to) = rates
        let seconds = 2.0
        let input = Self.sine(frequency: 300, sampleRate: from, count: Int(from * seconds))
        let output = Self.resample(input, from: from, to: to)
        let expected = Int(to * seconds)
        // The filter holds back exactly its look-ahead (in output samples) plus rounding.
        let lookAhead = StreamingResampler(inputRate: from, outputRate: to).latencyInputSamples
        let allowed = Int((Double(lookAhead) * to / from).rounded(.up)) + 4
        #expect(abs(output.count - expected) <= allowed, "got \(output.count), expected ≈ \(expected) (±\(allowed)) for \(from)→\(to)")
    }

    @Test func unusualRatesAreApproximatedWithABoundedFilterTable() {
        let (up, down) = StreamingResampler.reducedRatio(inputRate: 47_999, outputRate: 16_000)
        #expect(up <= StreamingResampler.maximumPhases)
        #expect(abs(Double(up) / Double(down) - 16_000.0 / 47_999.0) < 1e-4)
    }

    // MARK: Quality

    @Test(arguments: [(48_000.0, 100.0), (48_000.0, 1_000.0), (48_000.0, 4_000.0), (48_000.0, 6_500.0),
                      (44_100.0, 1_000.0), (44_100.0, 6_000.0), (24_000.0, 3_000.0)])
    func passbandGainIsFlatWithinHalfADecibel(case_: (Double, Double)) {
        let (rate, frequency) = case_
        let input = Self.sine(frequency: frequency, sampleRate: rate, count: Int(rate))
        let output = Self.resample(input, from: rate, to: 16_000)
        let gain = Self.decibels(Self.steadyStateRMS(output) / Self.steadyStateRMS(input))
        #expect(abs(gain) < 0.5, "\(frequency) Hz at \(rate) Hz changed by \(gain) dB")
    }

    @Test(arguments: [(48_000.0, 9_500.0), (48_000.0, 12_000.0), (48_000.0, 20_000.0), (44_100.0, 10_000.0),
                      (96_000.0, 15_000.0)])
    func energyAboveTheNewNyquistIsRejectedInsteadOfAliasing(case_: (Double, Double)) {
        let (rate, frequency) = case_
        let input = Self.sine(frequency: frequency, sampleRate: rate, count: Int(rate))
        let output = Self.resample(input, from: rate, to: 16_000)
        let level = Self.decibels(Self.steadyStateRMS(output) / Self.steadyStateRMS(input))
        #expect(level < -60, "\(frequency) Hz leaked through at \(level) dB (would alias into the speech band)")
    }

    @Test func zeroInputProducesZeroOutputAndDCIsPreserved() {
        let silence = Self.resample([Float](repeating: 0, count: 9_600), from: 48_000, to: 16_000)
        #expect(silence.allSatisfy { $0 == 0 })

        let dc = Self.resample([Float](repeating: 0.25, count: 48_000), from: 48_000, to: 16_000)
        let settled = dc[dc.count / 4..<(dc.count * 3 / 4)]
        #expect(settled.allSatisfy { abs($0 - 0.25) < 1e-3 })
    }

    // MARK: Streaming correctness

    @Test(arguments: [1, 7, 480, 1_001, 4_096])
    func outputIsIdenticalWhateverTheChunkSize(chunk: Int) {
        // A signal with several components so any state-carrying bug shows up.
        let input = (0..<48_000).map { index -> Float in
            let t = Double(index) / 48_000
            return Float(0.3 * sin(2 * .pi * 440 * t) + 0.2 * sin(2 * .pi * 3_100 * t) + 0.1 * sin(2 * .pi * 11_000 * t))
        }
        let whole = Self.resample(input, from: 48_000, to: 16_000)
        let chunked = Self.resample(input, from: 48_000, to: 16_000, chunk: chunk)
        #expect(chunked.count == whole.count)
        let worst = zip(whole, chunked).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-6, "chunk size \(chunk) changed the output by \(worst)")
    }

    @Test func fractionalRatioIsAlsoChunkIndependent() {
        let input = Self.sine(frequency: 1_500, sampleRate: 44_100, count: 44_100)
        let whole = Self.resample(input, from: 44_100, to: 16_000)
        let chunked = Self.resample(input, from: 44_100, to: 16_000, chunk: 333)
        #expect(chunked.count == whole.count)
        #expect((zip(whole, chunked).map { abs($0 - $1) }.max() ?? 0) < 1e-6)
    }

    @Test func resetStartsAFreshStream() {
        let resampler = StreamingResampler(inputRate: 48_000, outputRate: 16_000)
        var first: [Float] = []
        resampler.process(Self.sine(frequency: 500, sampleRate: 48_000, count: 4_800), appendingTo: &first)
        resampler.reset()
        var second: [Float] = []
        resampler.process(Self.sine(frequency: 500, sampleRate: 48_000, count: 4_800), appendingTo: &second)
        #expect(first == second)
    }

    @Test func memoryDoesNotGrowOverLongStreams() {
        let resampler = StreamingResampler(inputRate: 48_000, outputRate: 16_000)
        let chunk = Self.sine(frequency: 800, sampleRate: 48_000, count: 4_800)
        var output: [Float] = []
        for _ in 0..<2_000 { // ≈ 200 s of audio
            output.removeAll(keepingCapacity: true)
            resampler.process(chunk, appendingTo: &output)
        }
        #expect(output.count > 1_500 && output.count < 1_700)
    }
}
