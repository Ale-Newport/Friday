import Foundation
import Testing
@testable import FridaySpeech

/// Playback goes through the Mac's output device (quietly); every test bounds how long `play()` may take, which is
/// the point: an engine that stops under the player must never hold the caller.
@Suite(.serialized) struct SpeechPlayerTests {
    static let rate = 24_000

    /// `seconds` of a quiet 220 Hz tone in `chunkSeconds` chunks, streamed at once.
    static func tone(seconds: Double, chunkSeconds: Double = 0.25) -> AsyncThrowingStream<AudioChunk, any Error> {
        let samples = (0..<Int(seconds * Double(rate))).map { i in 0.02 * sin(Float(i) * 2 * .pi * 220 / Float(rate)) }
        let chunk = Int(chunkSeconds * Double(rate))
        return AsyncThrowingStream { continuation in
            for start in stride(from: 0, to: samples.count, by: chunk) {
                continuation.yield(AudioChunk(samples: Array(samples[start..<min(start + chunk, samples.count)]), sampleRate: rate))
            }
            continuation.finish()
        }
    }

    /// Runs `play` and reports how long it took; nil when the Mac has no usable output (the engine will not start).
    static func timed(_ play: @escaping @Sendable () async throws -> Bool) async -> (result: Bool, elapsed: Duration)? {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let result = try await play()
            return (result, clock.now - started)
        } catch {
            print("skipped: audio output unavailable (\(error))")
            return nil
        }
    }

    @Test func playsAnUtteranceToTheEnd() async {
        let player = SpeechPlayer()
        guard let outcome = await Self.timed({ try await player.play(Self.tone(seconds: 0.6)) }) else { return }
        #expect(outcome.result, "played to the end")
        #expect(outcome.elapsed > .milliseconds(400) && outcome.elapsed < .seconds(3), "took \(outcome.elapsed)")
        #expect(await player.isPlaying == false)
        let recoveries = await player.recoveries
        let failures = await player.failures
        #expect(recoveries == 0 && failures == 0)
        await player.shutdown()
    }

    @Test func stopInterruptsPlayback() async {
        let player = SpeechPlayer()
        let stopper = Task {
            try? await Task.sleep(for: .milliseconds(300))
            await player.stop()
        }
        guard let outcome = await Self.timed({ try await player.play(Self.tone(seconds: 4)) }) else { stopper.cancel(); return }
        #expect(!outcome.result, "an interrupted utterance reports false")
        #expect(outcome.elapsed < .seconds(2), "stop() returned play() after \(outcome.elapsed)")
        #expect(await player.isPlaying == false)
        await player.shutdown()
    }

    @Test func outputConfigurationChangeDoesNotHoldPlay() async {
        // What the system does when AirPods connect mid-sentence: the engine stops and posts the notification.
        let player = SpeechPlayer()
        let changer = Task {
            try? await Task.sleep(for: .milliseconds(400))
            await player.changeOutputConfigurationForTesting()
        }
        guard let outcome = await Self.timed({ try await player.play(Self.tone(seconds: 1.5)) }) else { changer.cancel(); return }
        // The audio is 1.5 s; a recovery replays at most the interrupted chunk. Never the old "for ever".
        #expect(outcome.elapsed < .seconds(5), "play() returned after \(outcome.elapsed)")
        let recoveries = await player.recoveries
        let failures = await player.failures
        print("configuration change: result \(outcome.result) after \(outcome.elapsed); recoveries \(recoveries), failures \(failures)")
        #expect(recoveries + failures >= 1, "the change was noticed")
        if recoveries > 0 { #expect(outcome.result, "a recovered utterance plays to its end") }
        if failures > 0 { #expect(!outcome.result, "an utterance given up reports false") }
        #expect(await player.isPlaying == false)
        await player.shutdown()
    }

    @Test func engineStoppingWithoutNoticeDoesNotHoldPlay() async {
        // The engine stopped and no notification came: the completions it fires while stopped are not progress.
        let player = SpeechPlayer()
        let stopper = Task {
            try? await Task.sleep(for: .milliseconds(400))
            await player.stopEngineForTesting()
        }
        guard let outcome = await Self.timed({ try await player.play(Self.tone(seconds: 1.5)) }) else { stopper.cancel(); return }
        #expect(outcome.elapsed < .seconds(5) + SpeechPlayer.stallGrace, "play() returned after \(outcome.elapsed)")
        let recoveries = await player.recoveries
        let failures = await player.failures
        print("silent engine stop: result \(outcome.result) after \(outcome.elapsed); recoveries \(recoveries), failures \(failures)")
        #expect(recoveries + failures >= 1, "the stop was noticed")
        #expect(await player.isPlaying == false)
        await player.shutdown()
    }

    @Test func stalledPlaybackIsGivenUpAfterTheGrace() async {
        // The engine runs but nothing is rendered (the node is paused): no completion will ever come. The watchdog
        // allows the scheduled audio its own length plus the grace period, then ends the utterance as interrupted.
        let player = SpeechPlayer()
        let pauser = Task {
            try? await Task.sleep(for: .milliseconds(300))
            await player.pausePlayerForTesting()
        }
        guard let outcome = await Self.timed({ try await player.play(Self.tone(seconds: 1.0)) }) else { pauser.cancel(); return }
        #expect(!outcome.result, "a stalled utterance reports false")
        #expect(outcome.elapsed > .seconds(1), "the watchdog waits for the audio's own length first")
        #expect(outcome.elapsed < .seconds(1) + SpeechPlayer.stallGrace + .seconds(2), "play() returned after \(outcome.elapsed)")
        #expect(await player.failures == 1)
        #expect(await player.isPlaying == false)
        // The player is usable again afterwards.
        guard let again = await Self.timed({ try await player.play(Self.tone(seconds: 0.3)) }) else { return }
        #expect(again.result)
        await player.shutdown()
    }

    @Test func playingAgainAfterAnOutputChangeWorks() async {
        let player = SpeechPlayer()
        guard let first = await Self.timed({ try await player.play(Self.tone(seconds: 0.3)) }) else { return }
        #expect(first.result)
        await player.changeOutputConfigurationForTesting()   // between utterances: nothing to recover
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await player.recoveries == 0)
        guard let second = await Self.timed({ try await player.play(Self.tone(seconds: 0.3)) }) else { return }
        #expect(second.result, "the engine is reconnected on the next utterance")
        #expect(await player.isEngineRunningForTesting)
        await player.shutdown()
        #expect(await player.isEngineRunningForTesting == false)
    }
}
