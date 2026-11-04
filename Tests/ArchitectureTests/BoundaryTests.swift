import Foundation
import Testing

/// Mechanical enforcement of the engine-independence rules, so they cannot erode unnoticed:
///
/// * A backend's native API is visible to exactly one module (its own).
/// * Only the composition root (and the benchmark tool) may even *name* a backend module.
/// * No engine-independent module mentions a backend's vocabulary in code.
/// * Every module imports only the modules its layer is allowed to depend on.
///
/// Adding a backend means adding one entry to `backends` (and its layer to `allowedImports`).
struct ArchitectureBoundaryTests {
    // MARK: Backends under governance

    struct Backend: @unchecked Sendable {   // regexes are immutable; the type is read-only test data
        /// Swift module of the engine, for example `PorcupineBackend`.
        let module: String
        /// Its C/binary module, if it has one, for example `CPorcupine`.
        let nativeModule: String?
        /// Words that must never appear in code outside the backend and the composition root.
        let vocabulary: [(name: String, pattern: Regex<Substring>)]
    }

    static let backends: [Backend] = [
        Backend(
            module: "PorcupineBackend", nativeModule: "CPorcupine",
            vocabulary: [("porcupine", /(?i)porcupine/), ("picovoice", /(?i)picovoice/), ("pv_ symbol", /\bpv_/), (".ppn file", /\.ppn\b/)]
        ),
        Backend(
            module: "SherpaOnnxBackend", nativeModule: "CSherpaOnnx",
            vocabulary: [("sherpa", /(?i)sherpa/)]
        ),
        // The speech engines (Kokoro text-to-speech, Silero voice activity) run on the same native library as the
        // wake-word spotter, so two backend modules share one native module; nothing else may touch it.
        Backend(
            module: "SherpaOnnxSpeech", nativeModule: "CSherpaOnnx",
            vocabulary: [("sherpa", /(?i)sherpa/)]
        ),
        // Backend(module: "OpenWakeWordBackend", nativeModule: nil, vocabulary: [("openwakeword", /(?i)openwakeword/)]),
    ]

    /// The backend modules that own `nativeModule`.
    static func owners(ofNativeModule nativeModule: String) -> [String] {
        backends.filter { $0.nativeModule == nativeModule }.map(\.module)
    }

    /// The only non-backend code allowed to import a backend.
    static let compositionRootPrefixes = ["App/Composition/", "Sources/FridayBench/"]

    // MARK: Source scanning

    struct SourceFile {
        let path: String          // repository-relative
        let lines: [String]
        /// Code with `//` comments (including doc comments) removed.
        var codeLines: [String] {
            lines.map { line in
                guard let range = line.range(of: "//") else { return line }
                // Keep "https://" style occurrences inside string literals.
                let prefix = line[..<range.lowerBound]
                return prefix.filter({ $0 == "\"" }).count % 2 == 1 ? line : String(prefix)
            }
        }
        /// Every module this file imports, however the statement is dressed: `@testable`, `@preconcurrency`, `@_exported`,
        /// `internal import`, `import struct Foo.Bar`, or several statements on one line separated by `;`.
        var imports: [String] {
            codeLines.flatMap { Self.importedModules(in: $0) }
        }

        static func importedModules(in line: String) -> [String] {
            let statement = /^(?:(?:@[A-Za-z_]+(?:\([^)]*\))?|public|internal|package|private|fileprivate)\s+)*import\s+(?:(?:class|struct|enum|protocol|func|typealias|var|let)\s+)?([A-Za-z0-9_]+)/
            return line.split(separator: ";").compactMap { part in
                part.trimmingCharacters(in: .whitespaces).firstMatch(of: statement).map { String($0.1) }
            }
        }
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func swiftFiles(under directories: [String]) -> [SourceFile] {
        var result: [SourceFile] = []
        for directory in directories {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = String(url.path.dropFirst(root.path.count + 1))
                result.append(SourceFile(path: relative, lines: text.components(separatedBy: "\n")))
            }
        }
        return result
    }

    static let allSwift = swiftFiles(under: ["Sources", "App", "AppTests", "Tests"])

    @Test func thereIsSomethingToScan() {
        #expect(Self.allSwift.count > 30, "the scanner found \(Self.allSwift.count) files; is the repository layout different?")
        for backend in Self.backends {
            #expect(Self.allSwift.contains { $0.path.hasPrefix("Sources/\(backend.module)/") }, "\(backend.module) has no sources")
        }
    }

    // MARK: Rule 1 — a native API belongs to one module

    @Test func onlyABackendImportsItsOwnNativeModule() {
        for backend in Self.backends {
            guard let native = backend.nativeModule else { continue }
            let owners = Self.owners(ofNativeModule: native).map { "Sources/\($0)/" }
            let offenders = Self.allSwift
                .filter { $0.imports.contains(native) }
                .map(\.path)
                .filter { path in !owners.contains { path.hasPrefix($0) } }
            #expect(offenders.isEmpty, "these files import \(native) directly: \(offenders)")
        }
    }

    @Test func onlyTheCompositionRootAndToolsNameABackend() {
        for backend in Self.backends {
            let allowedPrefixes = Self.compositionRootPrefixes + ["Tests/\(backend.module)Tests/", "Sources/\(backend.module)/"]
            let offenders = Self.allSwift
                .filter { $0.imports.contains(backend.module) }
                .map(\.path)
                .filter { path in !allowedPrefixes.contains { path.hasPrefix($0) } }
            #expect(offenders.isEmpty, "these files import \(backend.module) but are not the composition root: \(offenders)")
        }
    }

    /// The targets a `Package.swift` declares and every name each lists in its `dependencies:` — whether written as `"Name"`,
    /// `.target(name: "Name")` or `.product(name: "Name", …)`.
    static func manifestTargets(_ manifest: String) -> [(name: String, dependencies: Set<String>)] {
        let text = manifest.components(separatedBy: "\n").map { line in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
        func closing(_ open: Character, _ close: Character, from start: String.Index) -> String.Index? {
            var depth = 1
            var index = start
            while index < text.endIndex {
                if text[index] == open { depth += 1 } else if text[index] == close { depth -= 1; if depth == 0 { return index } }
                index = text.index(after: index)
            }
            return nil
        }
        var result: [(name: String, dependencies: Set<String>)] = []
        for opener in text.matches(of: /\.(?:target|executableTarget|testTarget|systemLibrary|macro|plugin)\(/) {
            guard let end = closing("(", ")", from: opener.range.upperBound) else { continue }
            let body = text[opener.range.upperBound..<end]
            guard let name = body.firstMatch(of: /name:\s*"([^"]+)"/)?.1 else { continue }
            var dependencies = Set<String>()
            if let list = body.firstMatch(of: /dependencies:\s*\[/), let listEnd = closing("[", "]", from: list.range.upperBound) {
                for literal in body[list.range.upperBound..<listEnd].matches(of: /"([^"]+)"/) { dependencies.insert(String(literal.1)) }
            }
            // A nested `.target(name: "X")` inside a dependency list matches the opener too; it is only a reference, with no
            // dependencies of its own, so it must not hide the parent's entry.
            result.append((String(name), dependencies))
        }
        return result
    }

    @Test func packageManifestGivesOnlyTheBackendAccessToItsNativeModule() throws {
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let targets = Self.manifestTargets(manifest)
        #expect(targets.count > 10, "the manifest parser found only \(targets.count) targets")
        for backend in Self.backends {
            guard let native = backend.nativeModule else { continue }
            let owners = Set(Self.owners(ofNativeModule: native))
            let users = Set(targets.filter { $0.dependencies.contains(native) }.map(\.name))
            #expect(users == owners, "only \(owners.sorted()) may depend on \(native); these do: \(users.sorted())")
        }
    }

    // The scanners themselves are tested, because a guard that can be sidestepped is worse than none.

    @Test func theImportScannerSeesImportsHoweverTheyAreDressed() {
        let lines = [
            "import AppKit", "@testable import AppKit", "@preconcurrency import AppKit", "@_exported import AppKit",
            "internal import AppKit", "public import AppKit", "package import AppKit", "@preconcurrency internal import AppKit",
            "import struct AppKit.NSRect", "import Foundation; import AppKit", "    import   AppKit  ", "let x = 1; import AppKit",
        ]
        for line in lines {
            #expect(SourceFile.importedModules(in: line).contains("AppKit"), "missed: \(line)")
        }
        #expect(SourceFile.importedModules(in: "let important = 1").isEmpty)
        #expect(SourceFile(path: "x.swift", lines: ["// import AppKit", "import Foundation  // not AppKit"]).imports == ["Foundation"])
    }

    @Test func theManifestScannerSeesADependencyHoweverItIsWritten() {
        let manifest = """
        let package = Package(name: "P", targets: [
            .target(name: "CNative", publicHeadersPath: "include"),
            .target(name: "Backend", dependencies: ["Kit", "CNative"]),
            .target(name: "Sneaky", dependencies: ["Kit", .target(name: "CNative")]),
            .target(name: "Product", dependencies: [.product(name: "CNative", package: "x")]),
            // .target(name: "Commented", dependencies: ["CNative"]),
            .testTarget(name: "Tests", dependencies: ["Kit"]),
        ])
        """
        let targets = Self.manifestTargets(manifest)
        // (A nested `.target(name:)` inside a dependency list is a reference, and shows up as an entry of its own.)
        #expect(targets.map(\.name) == ["CNative", "Backend", "Sneaky", "CNative", "Product", "Tests"], "got \(targets.map(\.name))")
        let users = targets.filter { $0.dependencies.contains("CNative") }.map(\.name)
        #expect(Set(users) == ["Backend", "Sneaky", "Product"], "got \(users)")
    }

    // MARK: Rule 2 — vocabulary

    @Test func engineIndependentCodeNeverMentionsABackendsVocabulary() {
        let guarded = [
            "Sources/WakeWordKit/", "Sources/FridayAudio/", "Sources/WakeWordCore/", "Sources/FridayPlatform/", "Sources/FridaySpeech/",
            "App/", "AppTests/",
        ]
        let allowed = ["App/Composition/"]
        var offenders: [String] = []
        for file in Self.allSwift {
            guard guarded.contains(where: { file.path.hasPrefix($0) }), !allowed.contains(where: { file.path.hasPrefix($0) }) else { continue }
            for (index, line) in file.codeLines.enumerated() {
                for backend in Self.backends {
                    if let hit = backend.vocabulary.first(where: { line.firstMatch(of: $0.pattern) != nil }) {
                        offenders.append("\(file.path):\(index + 1) mentions \(hit.name) (\(backend.module))")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "engine-specific vocabulary leaked out of a backend:\n\(offenders.joined(separator: "\n"))")
    }

    @Test func testsOutsideABackendDoNotAssumeAParticularEngine() {
        let offenders = Self.allSwift
            .filter { $0.path.hasPrefix("Tests/") && !$0.path.hasPrefix("Tests/ArchitectureTests/") }
            .filter { file in !Self.backends.contains { file.path.hasPrefix("Tests/\($0.module)Tests/") } }
            .filter { file in
                file.codeLines.contains { line in Self.backends.contains { $0.vocabulary.contains { line.firstMatch(of: $0.pattern) != nil } } }
            }
            .map(\.path)
        #expect(offenders.isEmpty, "engine-independent tests reference a concrete engine: \(offenders)")
    }

    // MARK: Rule 3 — layering

    /// Modules each layer may import (system frameworks included, so a UI import cannot sneak into
    /// the core). A new backend gets its own line here.
    static let allowedImports: [String: Set<String>] = [
        "Sources/WakeWordKit/": ["Foundation", "Darwin", "Accelerate"],
        "Sources/FridayAudio/": ["Foundation", "AVFoundation", "AudioToolbox", "CoreAudio", "WakeWordKit"],
        "Sources/WakeWordCore/": ["Foundation", "FridayAudio", "WakeWordKit", "os"],
        "Sources/FridayPlatform/": ["Foundation", "AppKit", "Network", "Security", "ServiceManagement", "Darwin", "os", "WakeWordCore", "FridayAudio", "WakeWordKit"],
        "Sources/PorcupineBackend/": ["Foundation", "CPorcupine", "WakeWordKit"],
        "Sources/SherpaOnnxBackend/": ["Foundation", "CryptoKit", "CSherpaOnnx", "WakeWordKit"],
        // Speech: the engine-independent contracts and Apple engines, and the sherpa-onnx engines behind them.
        "Sources/FridaySpeech/": ["Foundation", "AVFoundation", "Speech", "os", "CoreAudio", "Accelerate", "FridayCore", "WakeWordKit"],
        "Sources/SherpaOnnxSpeech/": ["Foundation", "os", "CSherpaOnnx", "FridaySpeech", "FridayCore"],
    ]

    @Test func everyModuleImportsOnlyWhatItsLayerAllows() {
        var offenders: [String] = []
        for file in Self.allSwift {
            guard let (prefix, allowed) = Self.allowedImports.first(where: { file.path.hasPrefix($0.key) }) else { continue }
            for module in file.imports where !allowed.contains(module) {
                offenders.append("\(file.path) imports \(module) (not allowed in \(prefix))")
            }
        }
        #expect(offenders.isEmpty, "layering violations:\n\(offenders.joined(separator: "\n"))")
    }

    @Test func everyBackendHasALayerRule() {
        for backend in Self.backends {
            #expect(Self.allowedImports["Sources/\(backend.module)/"] != nil, "add a layer rule for \(backend.module) to allowedImports")
        }
    }

    @Test func theCoreHasNoUserInterfaceDependencies() {
        let ui: Set = ["SwiftUI", "AppKit", "UIKit", "Combine"]
        let coreAndBackends = ["Sources/WakeWordKit/", "Sources/WakeWordCore/", "Sources/FridayAudio/", "Sources/FridaySpeech/"]
            + Self.backends.map { "Sources/\($0.module)/" }
        let offenders = Self.allSwift
            .filter { file in coreAndBackends.contains { file.path.hasPrefix($0) } }
            .filter { !ui.isDisjoint(with: $0.imports) }
            .map(\.path)
        #expect(offenders.isEmpty, "UI frameworks imported by the core: \(offenders)")
    }

    // MARK: Rule 4 — secrets

    @Test func noSecretsOrKeyLiteralsAreCommitted() {
        // API keys are typically long base64 strings; none may appear in source. A SHA-256 digest (exactly 64 lowercase
        // hex digits) is a public checksum, not a secret: the engines pin the model files they ship by it.
        let pattern = /"([A-Za-z0-9+\/]{40,}={0,2})"/
        let sha256 = /^[0-9a-f]{64}$/
        let offenders = Self.allSwift.flatMap { file in
            file.lines.enumerated().compactMap { index, line -> String? in
                guard let match = line.firstMatch(of: pattern), match.1.firstMatch(of: sha256) == nil else { return nil }
                return "\(file.path):\(index + 1)"
            }
        }
        #expect(offenders.isEmpty, "string literals that look like keys: \(offenders)")
    }

    @Test func secretsAreNeverReadFromTheEnvironmentInProductionCode() {
        // Reading the environment is fine (for example to detect a test host); reading something that
        // sounds like a credential is not — secrets come from the Keychain only. The benchmark tool is exempt.
        let secretLike = /(?i)(key|token|secret|password|credential)/
        let offenders = Self.allSwift
            .filter { $0.path.hasPrefix("Sources/") || $0.path.hasPrefix("App/") }
            .filter { !$0.path.hasPrefix("Sources/FridayBench/") }
            .flatMap { file in
                file.codeLines.enumerated().compactMap { index, line in
                    line.contains("environment") && line.contains("ProcessInfo") && line.firstMatch(of: secretLike) != nil
                        ? "\(file.path):\(index + 1)" : nil
                }
            }
        #expect(offenders.isEmpty, "only the benchmark tool may read credentials from the environment: \(offenders)")
    }
}
