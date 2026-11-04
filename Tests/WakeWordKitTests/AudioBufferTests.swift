import Foundation
import Testing
@testable import WakeWordKit

struct FrameAssemblerTests {
    @Test func releasesOnlyCompleteFramesInOrder() {
        var assembler = FrameAssembler(frameLength: 4)
        var frames: [[Float]] = []
        assembler.append([1, 2, 3], emit: { frames.append($0) })
        #expect(frames.isEmpty)
        #expect(assembler.pendingCount == 3)

        assembler.append([4, 5, 6, 7, 8, 9], emit: { frames.append($0) })
        #expect(frames == [[1, 2, 3, 4], [5, 6, 7, 8]])
        #expect(assembler.pendingCount == 1)
    }

    @Test func frameBoundariesDoNotDependOnHowTheInputWasChunked() {
        let stream = (0..<1_000).map(Float.init)
        func frames(chunk: Int) -> [[Float]] {
            var assembler = FrameAssembler(frameLength: 64)
            var result: [[Float]] = []
            var index = 0
            while index < stream.count {
                let end = min(stream.count, index + chunk)
                assembler.append(Array(stream[index..<end]), emit: { result.append($0) })
                index = end
            }
            return result
        }
        let reference = frames(chunk: 1_000)
        #expect(reference.count == 15)
        for chunk in [1, 13, 64, 65, 300] {
            #expect(frames(chunk: chunk) == reference, "chunk \(chunk)")
        }
    }

    @Test func resetDropsThePartialFrame() {
        var assembler = FrameAssembler(frameLength: 4)
        assembler.append([1, 2, 3], emit: { _ in })
        assembler.reset()
        var frames: [[Float]] = []
        assembler.append([9, 9, 9, 9], emit: { frames.append($0) })
        #expect(frames == [[9, 9, 9, 9]])
    }

    @Test func bufferedAmountStaysBoundedOverALongStream() {
        var assembler = FrameAssembler(frameLength: 512)
        var emitted = 0
        for _ in 0..<5_000 {
            assembler.append([Float](repeating: 0.1, count: 1_600), emit: { _ in emitted += 1 })
            #expect(assembler.pendingCount < 512)
        }
        #expect(emitted == 5_000 * 1_600 / 512)
    }
}

struct PreRollBufferTests {
    @Test func zeroCapacityRetainsNothing() {
        var buffer = PreRollBuffer(capacity: 0)
        buffer.append([1, 2, 3])
        #expect(buffer.snapshot().isEmpty)
        #expect(buffer.count == 0)
    }

    @Test func keepsTheMostRecentSamplesOldestFirst() {
        var buffer = PreRollBuffer(capacity: 5)
        buffer.append([1, 2, 3])
        #expect(buffer.snapshot() == [1, 2, 3])
        buffer.append([4, 5, 6, 7])
        #expect(buffer.snapshot() == [3, 4, 5, 6, 7])
        buffer.append((10...30).map(Float.init))
        #expect(buffer.snapshot() == [26, 27, 28, 29, 30])
    }

    @Test func resetForgetsEverything() {
        var buffer = PreRollBuffer(capacity: 3)
        buffer.append([1, 2, 3])
        buffer.reset()
        #expect(buffer.snapshot().isEmpty)
    }
}

struct AudioLevelTests {
    @Test func measuresPeakAndRMS() {
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        let level = samples.withUnsafeBufferPointer { AudioLevel.measure($0) }
        #expect(abs(level.peak - 0.5) < 1e-6)
        #expect(abs(level.rms - 0.5) < 1e-6)
        #expect(abs(level.peakDecibels - (-6.0206)) < 0.01)
    }

    @Test func silenceIsFlooredNotInfinite() {
        let level = [Float](repeating: 0, count: 100).withUnsafeBufferPointer { AudioLevel.measure($0) }
        #expect(level == .silence)
        #expect(level.rmsDecibels == -120)
    }
}

struct AudioFrameTests {
    @Test func convertsToClippedRoundedInt16() {
        let frame = AudioFrame(samples: [0, 0.5, -0.5, 1.0, -1.0, 2.0, -2.0], sampleRate: 16_000, sequence: 0, captureTime: .zero)
        #expect(frame.int16Samples() == [0, 16384, -16384, 32767, -32768, 32767, -32768])
    }

    @Test func reusesTheCallersBufferWithoutReallocatingWhenSizesMatch() {
        let frame = AudioFrame(samples: [Float](repeating: 0.25, count: 512), sampleRate: 16_000, sequence: 1, captureTime: .zero)
        var buffer = [Int16](repeating: 0, count: 512)
        let before = buffer.withUnsafeBufferPointer { $0.baseAddress }
        frame.copyInt16Samples(into: &buffer)
        let after = buffer.withUnsafeBufferPointer { $0.baseAddress }
        #expect(before == after, "the caller's storage should be reused, not reallocated")
        #expect(buffer.allSatisfy { $0 == 8192 })
    }

    @Test func endTimeIsStartPlusDuration() {
        let start = HostTime(seconds: 10)
        let frame = AudioFrame(samples: [Float](repeating: 0, count: 512), sampleRate: 16_000, sequence: 0, captureTime: start)
        #expect(abs(frame.duration - 0.032) < 1e-9)
        #expect(abs(frame.endTime.seconds(since: start) - 0.032) < 1e-6)
    }
}

struct HostTimeTests {
    @Test func roundTripsSeconds() {
        let base = HostTime(seconds: 100)
        #expect(abs(base.advanced(bySeconds: 2.5).seconds(since: base) - 2.5) < 1e-6)
        #expect(abs(base.seconds(since: base.advanced(bySeconds: 1)) - (-1)) < 1e-6)
    }

    @Test func advancingBackwardsSaturatesAtZero() {
        #expect(HostTime(seconds: 1).advanced(bySeconds: -5).ticks == 0)
    }
}
