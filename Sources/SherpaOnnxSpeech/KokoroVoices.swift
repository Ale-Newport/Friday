import Foundation

/// The 54 speakers of Kokoro multi-lang v1.0, in the model's own order (its `id2speaker` metadata), with the language
/// each was trained for and the espeak-ng voice that phonemises it.
///
/// The speaker id encodes the voice: the first letter is the language (`a`merican English, `b`ritish English,
/// `e`spañol, `f`rançais, `h`indi, `i`taliano, `j`apanese, `p`ortuguês do Brasil, `z`hōngwén), the second the gender.
enum KokoroVoices {
    struct Entry: Sendable, Equatable {
        /// The `sid` handed to the library.
        let speakerID: Int32
        /// Kokoro's name, for example `af_heart`; this is the `TTSVoice.id`.
        let id: String
        /// For display, for example "Heart".
        let name: String
        /// BCP-47 tag, for example `en-US`.
        let language: String
    }

    /// The model's `speaker_names` metadata, in order. An index here is the speaker id.
    private static let speakerNames = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        "ef_dora", "em_alex", "ff_siwis", "hf_alpha", "hf_beta", "hm_omega", "hm_psi", "if_sara", "im_nicola",
        "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa",
        "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
        "em_santa",
    ]

    /// Language by the first letter of a speaker id.
    private static let languages: [Character: String] = [
        "a": "en-US", "b": "en-GB", "e": "es-ES", "f": "fr-FR", "h": "hi-IN", "i": "it-IT", "j": "ja-JP", "p": "pt-BR", "z": "zh-CN",
    ]

    /// The espeak-ng voice that phonemises text for a language, or nil for American English, which goes through the
    /// lexicon instead (closer to the pronunciations the model was trained on). The names are what the bundled
    /// espeak-ng-data knows: `fr`, not `fr-fr`; `en-gb-x-rp` (Received Pronunciation), since there is no plain `en-gb`.
    private static let espeakVoices: [String: String] = [
        "en-GB": "en-gb-x-rp", "es-ES": "es", "fr-FR": "fr", "hi-IN": "hi", "it-IT": "it", "ja-JP": "ja", "pt-BR": "pt-br", "zh-CN": "cmn",
    ]

    static let all: [Entry] = speakerNames.enumerated().map { index, id in
        let parts = id.split(separator: "_", maxSplits: 1)
        let given = parts.count == 2 ? String(parts[1]) : id
        let gender = id.dropFirst().first == "f" ? "female" : "male"
        return Entry(
            speakerID: Int32(index), id: id,
            name: "\(given.prefix(1).uppercased())\(given.dropFirst()) (\(gender))",
            language: languages[id.first ?? " "] ?? "und"
        )
    }

    private static let byID: [String: Entry] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func entry(for id: String) -> Entry? { byID[id] }

    static func espeakVoice(forLanguage language: String) -> String? { espeakVoices[language] }
}
