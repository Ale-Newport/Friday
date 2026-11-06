import Foundation
import FridayCore

/// Where the speech engines find their native library and model files.
///
/// Code and data are kept apart on purpose: the library runs inside this process, so it is only ever taken from the
/// app bundle's frameworks folder (or, for tests and command-line tools, the repository's Vendor folder), never from
/// a user-writable location. The models are data and may come from anywhere.
public struct SherpaOnnxSpeechResources: Sendable, Equatable {
    /// Where the files come from, which decides what a missing file means to the person reading the message.
    public enum Layout: Sendable, Equatable {
        /// Inside an app bundle: the files are copied in at build time, so a missing one is a build without them.
        case bundle
        /// The repository's Vendor folder: a missing file is fetched by the scripts.
        case development
    }

    /// `libsherpa-onnx-c-api.dylib`; `libonnxruntime.dylib` must sit next to it.
    public var libraryURL: URL
    /// The Kokoro multi-lang v1.0 folder: `model.int8.onnx`, `voices.bin`, `tokens.txt`, `espeak-ng-data/` and the lexicons.
    public var kokoroDirectory: URL
    /// `silero_vad.onnx`.
    public var sileroModelURL: URL
    public var layout: Layout

    public static let libraryName = "libsherpa-onnx-c-api.dylib"
    public static let kokoroDirectoryName = "kokoro-multi-lang-v1_0"
    public static let sileroModelName = "silero_vad.onnx"
    /// The folder below the bundle's resources that holds the models (`Scripts/embed-engine-files.sh` puts them there).
    public static let bundleModelsFolder = "Speech"
    static func fetchScripts(in language: Language) -> String {
        "Scripts/fetch-sherpa.sh \(language == .es ? "y" : "and") Scripts/fetch-speech-models.sh"
    }

    public init(libraryURL: URL, kokoroDirectory: URL, sileroModelURL: URL, layout: Layout = .development) {
        self.libraryURL = libraryURL
        self.kokoroDirectory = kokoroDirectory
        self.sileroModelURL = sileroModelURL
        self.layout = layout
    }

    /// The app bundle: the library in `Contents/Frameworks`, the models in `Contents/Resources/Speech`. Nil for a bundle
    /// without those folders (a bare test runner); whether the files are actually there is each engine's `availability()`.
    public static func locate(bundle: Bundle = .main) -> SherpaOnnxSpeechResources? {
        guard let frameworks = bundle.privateFrameworksURL, let resources = bundle.resourceURL else { return nil }
        let models = resources.appendingPathComponent(bundleModelsFolder, isDirectory: true)
        return SherpaOnnxSpeechResources(
            libraryURL: frameworks.appendingPathComponent(libraryName),
            kokoroDirectory: models.appendingPathComponent(kokoroDirectoryName, isDirectory: true),
            sileroModelURL: models.appendingPathComponent(sileroModelName),
            layout: .bundle
        )
    }

    /// The repository's Vendor folder, as `Scripts/fetch-sherpa.sh` and `Scripts/fetch-speech-models.sh` fill it.
    public static func developmentDefault(repositoryRoot: URL) -> SherpaOnnxSpeechResources {
        let speech = repositoryRoot.appendingPathComponent("Vendor/Speech", isDirectory: true)
        return SherpaOnnxSpeechResources(
            libraryURL: repositoryRoot.appendingPathComponent("Vendor/SherpaOnnx/lib/\(libraryName)"),
            kokoroDirectory: speech.appendingPathComponent(kokoroDirectoryName, isDirectory: true),
            sileroModelURL: speech.appendingPathComponent(sileroModelName),
            layout: .development
        )
    }

    /// What to tell the user when `missing` files are not where this layout keeps them. Inside an app bundle no script
    /// can fix the running app: the build was made without the files, and only a rebuild after fetching them helps.
    public func setupMessage(missing: [String]) -> LocalizedText {
        let list = missing.joined(separator: ", ")
        switch layout {
        case .bundle:
            return LocalizedText(
                en: "This build of Friday was made without the speech files (missing \(list)). Rebuild the app after running \(Self.fetchScripts(in: .en)).",
                es: "Esta compilación de Friday se hizo sin los archivos de voz (faltan \(list)). Vuelve a compilar la app después de ejecutar \(Self.fetchScripts(in: .es)).")
        case .development:
            return LocalizedText(
                en: "Missing \(list); run \(Self.fetchScripts(in: .en)).",
                es: "Faltan \(list); ejecuta \(Self.fetchScripts(in: .es)).")
        }
    }

    /// `setupMessage` as the reason of a `SpeechError` (one language: the error's text is diagnostic).
    func setupReason(missing: [String]) -> String {
        setupMessage(missing: missing).en
    }

    /// The Kokoro files resolved below `kokoroDirectory`, with the given lexicon file names.
    public func kokoroFiles(lexicons: [String]) -> KokoroModelFiles {
        KokoroModelFiles(
            model: kokoroDirectory.appendingPathComponent(KokoroModelFiles.modelName),
            voices: kokoroDirectory.appendingPathComponent(KokoroModelFiles.voicesName),
            tokens: kokoroDirectory.appendingPathComponent(KokoroModelFiles.tokensName),
            espeakData: kokoroDirectory.appendingPathComponent(KokoroModelFiles.espeakDataName, isDirectory: true),
            lexicons: lexicons.map { kokoroDirectory.appendingPathComponent($0) }
        )
    }

    var isLibraryPresent: Bool { FileManager.default.fileExists(atPath: libraryURL.path) }
}

/// The files one Kokoro model is made of.
public struct KokoroModelFiles: Sendable, Equatable {
    public var model: URL
    public var voices: URL
    public var tokens: URL
    /// espeak-ng's data folder, used to phonemise every language but English (and English words the lexicon lacks).
    public var espeakData: URL
    /// Pronunciation tables consulted, in order, for English text; the first file to list a word wins.
    public var lexicons: [URL]

    public static let modelName = "model.int8.onnx"
    public static let voicesName = "voices.bin"
    public static let tokensName = "tokens.txt"
    public static let espeakDataName = "espeak-ng-data"
    public static let americanEnglishLexicon = "lexicon-us-en.txt"
    public static let britishEnglishLexicon = "lexicon-gb-en.txt"
    /// What the library itself insists on finding in the espeak-ng data folder.
    static let espeakDataFiles = ["phontab", "phonindex", "phondata", "intonations"]

    public init(model: URL, voices: URL, tokens: URL, espeakData: URL, lexicons: [URL]) {
        self.model = model
        self.voices = voices
        self.tokens = tokens
        self.espeakData = espeakData
        self.lexicons = lexicons
    }

    /// The names of the files that are not there, relative to the model folder; empty when everything is in place.
    public var missingFiles: [String] {
        var required = [model, voices, tokens] + lexicons
        required += Self.espeakDataFiles.map { espeakData.appendingPathComponent($0) }
        let base = model.deletingLastPathComponent().path
        return required.filter { !FileManager.default.fileExists(atPath: $0.path) }.map { url in
            url.path.hasPrefix(base + "/") ? String(url.path.dropFirst(base.count + 1)) : url.path
        }
    }
}
