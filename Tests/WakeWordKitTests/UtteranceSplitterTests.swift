import Foundation
import Testing
@testable import WakeWordKit

struct UtteranceSplitterTests {
    static let rate = 16_000

    /// A 200 Hz tone, standing in for a voiced stretch of speech.
    static func tone(_ seconds: Double, _ amplitude: Float = 0.2) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sinf(2 * .pi * 200 * Float($0) / Float(rate)) }
    }

    /// Deterministic room noise.
    static func room(_ seconds: Double, _ level: Float = 0.001, seed: UInt64 = 5) -> [Float] {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(Int64(bitPattern: state >> 11) & 0xFFFFF) / Float(0xFFFFF) * 2 - 1) * level
        }
    }

    static func seconds(_ clip: [Float]) -> Double { Double(clip.count) / Double(rate) }

    @Test func aLongTakeBecomesOneClipPerUtterance() {
        let take = Self.room(2) + Self.tone(0.8) + Self.room(1.5, seed: 6) + Self.tone(0.6) + Self.room(1.5, seed: 7) + Self.tone(1.0) + Self.room(2, seed: 8)
        let pieces = UtteranceSplitter.split(take)
        #expect(pieces.count == 3, "got \(pieces.map(Self.seconds))")
        for (piece, length) in zip(pieces, [0.8, 0.6, 1.0]) {
            #expect(Self.seconds(piece) >= length && Self.seconds(piece) <= length + 0.7 + 0.05, "the utterance with a little room around it: \(Self.seconds(piece))")
        }
    }

    @Test func aShortGapInsideAnUtteranceDoesNotSplitIt() {
        // "hey … Jarvis": two bursts 0.3 s apart are one utterance.
        let take = Self.room(1.5) + Self.tone(0.4) + Self.room(0.3, seed: 6) + Self.tone(0.6) + Self.room(1.5, seed: 7)
        #expect(UtteranceSplitter.split(take).count == 1)
    }

    @Test func aSingleTrimmedWordComesBackAsOneClip() {
        let clip = Self.room(0.1) + Self.tone(0.7) + Self.room(0.1, seed: 6)
        let pieces = UtteranceSplitter.split(clip)
        #expect(pieces.count == 1 && Self.seconds(pieces[0]) <= Self.seconds(clip) + 0.001)
    }

    @Test func aRecordingWithNothingInItComesBackWhole() {
        let quiet = Self.room(3)
        #expect(UtteranceSplitter.split(quiet) == [quiet])
        #expect(UtteranceSplitter.split([]).isEmpty)
        #expect(UtteranceSplitter.split([0.1, 0.2, 0.1]) == [[0.1, 0.2, 0.1]], "too short to analyse: as it is")
    }

    @Test func aQuietVoiceInAQuietRoomIsFoundByItsLevelRelativeToTheRoom() {
        let take = Self.room(2, 0.0003) + Self.tone(0.7, 0.01) + Self.room(1.5, 0.0003, seed: 6) + Self.tone(0.7, 0.01) + Self.room(2, 0.0003, seed: 7)
        #expect(UtteranceSplitter.split(take).count == 2)
    }

    @Test func aClickShorterThanAWordIsIgnored() {
        let take = Self.room(1.5) + Self.tone(0.8) + Self.room(1.5, seed: 6) + Self.tone(0.1) + Self.room(1.5, seed: 7) + Self.tone(0.8) + Self.room(1.5, seed: 8)
        #expect(UtteranceSplitter.split(take).count == 2, "the 0.1 s click is not an utterance")
    }

    @Test func aVeryLongStretchIsCut() {
        let pieces = UtteranceSplitter.split(Self.room(3) + Self.tone(20) + Self.room(3, seed: 6), longest: 8)
        #expect(pieces.count == 1 && Self.seconds(pieces[0]) <= 8.001)
    }

    @Test func aLongRecordingAtOneLevelIsNotOneEnormousUtterance() {
        let hum = Self.tone(30)   // nothing stands out from the rest, so there is no utterance to find
        let pieces = UtteranceSplitter.split(hum)
        #expect(pieces.count == 3 && pieces.allSatisfy { Self.seconds($0) <= 12.001 }, "got \(pieces.map(Self.seconds))")
        #expect(pieces.reduce(0) { $0 + $1.count } == hum.count, "nothing is lost")
        #expect(UtteranceSplitter.split(hum, longest: .nan).count == 3, "a longest that is not a number means the default")
    }

    @Test func settingsThatAreNotSensibleNumbersDoNotCrashIt() {
        let take = Self.room(2) + Self.tone(0.8) + Self.room(1.5, seed: 6) + Self.tone(0.6) + Self.room(2, seed: 7)
        let usual = UtteranceSplitter.split(take).count
        for pause in [Double.nan, .infinity, -1, 1e300] {
            let pieces = UtteranceSplitter.split(take, pause: pause)
            #expect(!pieces.isEmpty, "pause \(pause)")
        }
        #expect(UtteranceSplitter.split(take, pause: .nan).count == usual, "a pause that is not a number means the usual one")
        _ = UtteranceSplitter.split(take, shortest: .nan)
        _ = UtteranceSplitter.split(take, shortest: .infinity)
    }

    @Test func numbersThatAreNotAudioDoNotCrashIt() {
        var take = Self.room(1) + Self.tone(0.6) + Self.room(1, seed: 6)
        take[8_000] = .nan
        take[9_000] = .infinity
        _ = UtteranceSplitter.split(take)
    }

    // MARK: Frames and ranges (what a live recording is judged by)

    @Test func eachTwentyMillisecondsHasALevelInDecibels() {
        let levels = UtteranceSplitter.frameLevels(Self.tone(1, 0.5) + [Float](repeating: 0, count: 16_000))
        #expect(levels.count == 100)
        #expect(abs(levels[10] - 20 * log10(Float(0.5) / Float(2).squareRoot())) < 0.1, "a sine of amplitude 0.5 has an RMS of 0.354: \(levels[10])")
        #expect(levels[60] == -120, "digital silence is the floor of the scale")
        var broken = [Float](repeating: 0.1, count: 640)
        broken[5] = .nan
        #expect(UtteranceSplitter.frameLevels(broken)[0] == -120 && UtteranceSplitter.frameLevels(broken)[1] > -30, "a frame of garbage is not louder than silence")
    }

    @Test func theRoomIsTheQuietestTenthOfTheFrames() {
        let levels: [Float] = (0..<100).map { $0 < 20 ? -60 : -20 }
        #expect(UtteranceSplitter.noiseFloor(of: levels) == -60)
        #expect(UtteranceSplitter.noiseFloor(of: []) == -120)
        #expect(UtteranceSplitter.threshold(floor: -50) == -40, "10 dB above the room")
        #expect(UtteranceSplitter.threshold(floor: -70) == -55, "but never lower than −55 dBFS")
    }

    @Test func rangesAreTheStretchesThatStandOutFromTheRoom() {
        let take = Self.room(2) + Self.tone(0.8) + Self.room(1.5, seed: 6) + Self.tone(0.6) + Self.room(2, seed: 7)
        let levels = UtteranceSplitter.frameLevels(take)
        let found = UtteranceSplitter.ranges(levels: levels)
        #expect(found.count == 2)
        #expect(abs(Double(found[0].count) / 50 - 0.8) < 0.1 && abs(Double(found[1].count) / 50 - 0.6) < 0.1, "\(found)")
        #expect(abs(Double(found[0].lowerBound) / 50 - 2.0) < 0.1, "the first starts after the two seconds of room")
        // With the room's level given (as a live recording does after listening to the room), the same stretches are found.
        let room = UtteranceSplitter.noiseFloor(of: Array(levels.prefix(80)))
        #expect(UtteranceSplitter.ranges(levels: levels, floor: room) == found)
        #expect(UtteranceSplitter.ranges(levels: []).isEmpty)
    }

    @Test func aClipHasItsMarginsAndNeverMoreThanTheLimit() {
        let take = Self.room(2) + Self.tone(0.8) + Self.room(2, seed: 6)
        let levels = UtteranceSplitter.frameLevels(take)
        let range = UtteranceSplitter.ranges(levels: levels)[0]
        let clip = UtteranceSplitter.clip(of: range, in: take, frameCount: levels.count)
        #expect(abs(Self.seconds(clip) - (0.8 + 0.3 + 0.4)) < 0.1, "\(Self.seconds(clip))")
        #expect(UtteranceSplitter.clip(of: range, in: take, frameCount: levels.count, longest: 0.5).count == 8_000)
        #expect(UtteranceSplitter.clip(of: 10_000..<10_010, in: take, frameCount: levels.count).isEmpty, "a range beyond the recording holds nothing")
    }
}
