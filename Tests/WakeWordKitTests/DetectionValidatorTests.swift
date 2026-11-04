import Foundation
import Testing
@testable import WakeWordKit

struct DetectionValidatorTests {
    static let jarvis = DetectionResult(keyword: .jarvis)

    static func validator(
        cooldown: Double = 2.0, debounce: Double = 0.6,
        accepted: Set<String>? = ["jarvis"], minimumConfidence: Float? = nil
    ) -> DetectionValidator {
        DetectionValidator(configuration: .init(
            cooldown: cooldown, debounceWindow: debounce, acceptedKeywords: accepted, minimumConfidence: minimumConfidence
        ))
    }

    static func t(_ seconds: Double) -> HostTime { HostTime(seconds: 1_000 + seconds) }

    @Test func firstDetectionIsAccepted() {
        var validator = Self.validator()
        #expect(validator.evaluate(Self.jarvis, at: Self.t(0)) == .accept)
    }

    @Test func aBurstOfConsecutiveFramesIsOneUtteranceAndKeepsExtendingTheWindow() {
        var validator = Self.validator(cooldown: 0, debounce: 0.6)
        #expect(validator.evaluate(Self.jarvis, at: Self.t(0)) == .accept)
        // An engine firing every 32 ms for a second: only the first counts.
        for frame in 1...30 {
            #expect(validator.evaluate(Self.jarvis, at: Self.t(Double(frame) * 0.032)) == .reject(.debounced))
        }
        // Once the engine goes quiet for longer than the window, a new utterance is accepted.
        #expect(validator.evaluate(Self.jarvis, at: Self.t(30 * 0.032 + 0.7)) == .accept)
    }

    @Test func cooldownBlocksAnythingAfterAnAcceptedDetectionUntilItExpires() {
        var validator = Self.validator(cooldown: 2.0, debounce: 0.3)
        #expect(validator.evaluate(Self.jarvis, at: Self.t(0)) == .accept)
        if case .reject(.cooldown(let remaining)) = validator.evaluate(Self.jarvis, at: Self.t(1.0)) {
            #expect(abs(remaining - 1.0) < 1e-3)
        } else {
            Issue.record("expected a cooldown rejection")
        }
        // After the cooldown (measured from the accepted detection) the next utterance is accepted.
        var fresh = Self.validator(cooldown: 2.0, debounce: 0.3)
        _ = fresh.evaluate(Self.jarvis, at: Self.t(0))
        #expect(fresh.evaluate(Self.jarvis, at: Self.t(2.01)) == .accept)
    }

    @Test func rejectedDetectionsDoNotExtendTheCooldown() {
        var validator = Self.validator(cooldown: 2.0, debounce: 0.3)
        #expect(validator.evaluate(Self.jarvis, at: Self.t(0)) == .accept)
        // Repeated attempts spaced beyond the debounce window but inside the cooldown.
        #expect(validator.evaluate(Self.jarvis, at: Self.t(0.8)) != .accept)
        #expect(validator.evaluate(Self.jarvis, at: Self.t(1.4)) != .accept)
        // 2.1 s after the *accepted* detection → accepted, even though attempts continued.
        #expect(validator.evaluate(Self.jarvis, at: Self.t(2.1)) == .accept)
    }

    @Test func detectionsOfOtherKeywordsNeverActivateJarvisAndDoNotDisturbState() {
        var validator = Self.validator()
        let other = DetectionResult(keyword: WakeKeyword(id: "computer", displayName: "Computer"))
        #expect(validator.evaluate(other, at: Self.t(0)) == .reject(.unexpectedKeyword("computer")))
        // The foreign keyword must not have started a debounce window or cooldown.
        #expect(validator.evaluate(Self.jarvis, at: Self.t(0.05)) == .accept)
    }

    @Test func nilAcceptedKeywordsAcceptsAnything() {
        var validator = Self.validator(accepted: nil)
        let other = DetectionResult(keyword: WakeKeyword(id: "computer", displayName: "Computer"))
        #expect(validator.evaluate(other, at: Self.t(0)) == .accept)
    }

    @Test func lowConfidenceIsIgnoredOnlyWhenTheEngineReportsAScore() {
        var validator = Self.validator(minimumConfidence: 0.7)
        #expect(validator.evaluate(DetectionResult(keyword: .jarvis, confidence: 0.4), at: Self.t(0)) == .reject(.lowConfidence(0.4)))
        // No score (Porcupine): the threshold does not apply.
        #expect(validator.evaluate(Self.jarvis, at: Self.t(0.1)) == .accept)
    }

    @Test func holdoffSuppressesEverythingUntilItEnds() {
        var validator = Self.validator(cooldown: 0, debounce: 0)
        validator.beginHoldoff(until: Self.t(5))
        if case .reject(.holdoff(let remaining)) = validator.evaluate(Self.jarvis, at: Self.t(3)) {
            #expect(abs(remaining - 2) < 1e-3)
        } else {
            Issue.record("expected holdoff rejection")
        }
        #expect(validator.evaluate(Self.jarvis, at: Self.t(5.01)) == .accept)
    }

    @Test func resetForgetsHistoryButKeepsConfiguration() {
        var validator = Self.validator(cooldown: 10)
        _ = validator.evaluate(Self.jarvis, at: Self.t(0))
        validator.reset()
        #expect(validator.configuration.cooldown == 10)
        #expect(validator.evaluate(Self.jarvis, at: Self.t(0.1)) == .accept)
    }
}
