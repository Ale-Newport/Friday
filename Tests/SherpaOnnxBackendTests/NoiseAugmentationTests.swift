import Foundation
import Testing
@testable import SherpaOnnxBackend

@Suite struct NoiseAugmentationTests {
    /// A 0.6 s "word": a 220 Hz tone with an envelope.
    static let word: [Float] = (0..<9_600).map { index in
        let t = Float(index) / 16_000
        return 0.3 * sinf(2 * .pi * 220 * t) * min(1, Float(index) / 800) * min(1, Float(9_600 - index) / 800)
    }

    @Test func everyBackgroundAddsSoundAtARealisticLevel() {
        let speech = [[Float]]((0..<2).map { _ in (0..<32_000).map { sinf(Float($0) * 0.05) * 0.1 } })
        for background in NoiseAugmentation.Background.allCases {
            let noisy = NoiseAugmentation.augment(Self.word, background: background, speech: speech, seed: 42)
            #expect(noisy.count == Self.word.count + 9_600, "padding before and after")
            // The padding (word absent) now carries the background…
            let lead = NoiseAugmentation.rms(Array(noisy.prefix(4_000)))
            #expect(lead > 0.0005, "\(background) is audible before the word")
            // …well below the word.
            let middle = NoiseAugmentation.rms(Array(noisy[6_000..<12_000]))
            #expect(middle > lead * 1.5, "\(background): the word stays clearly above the background")
            #expect(noisy.allSatisfy { abs($0) <= 1 }, "no clipping")
        }
    }

    @Test func copiesAreDeterministic() {
        let a = NoiseAugmentation.augment(Self.word, background: .music, speech: [], seed: 7)
        let b = NoiseAugmentation.augment(Self.word, background: .music, speech: [], seed: 7)
        let c = NoiseAugmentation.augment(Self.word, background: .music, speech: [], seed: 8)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func backgroundsRotate() {
        #expect(Set((0..<3).map(NoiseAugmentation.background(for:))).count == 3)
    }
}
