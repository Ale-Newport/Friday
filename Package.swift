// swift-tools-version: 6.0
import PackageDescription

// FridayKit — everything in Friday except the SwiftUI application shell (App/).
//
// Friday unifies three earlier projects. Their modules were copied here verbatim and only renamed where two
// of them collided on a module name (both had a `JarvisCore`):
//
//   Speech (wake word "Jarvis")        → WakeWordKit, SherpaOnnxBackend/CSherpaOnnx, PorcupineBackend/CPorcupine,
//                                        FridayAudio (was JarvisAudio), WakeWordCore (was JarvisCore),
//                                        FridayPlatform (was JarvisPlatform), FridayBench (was JarvisBench)
//   Apple-Integrations (Action Engine) → FridayCore (was JarvisCore), FridayInterpreter, FridayIntegrations, FridayIPC, fridayctl
//   Jarvis (Chrome agent, Python)      → Sidecar/ (a Python process; FridayBrowser is its Swift client)
//
// New in Friday: FridaySpeech (speech recognition, text to speech, voice activity), FridayIntelligence (LLM providers,
// Laya routing, planning), FridayBrowser (sidecar client + browser tools), FridayComputer (Accessibility, windows,
// screen), FridayMemory (persistent memory), FridaySidecar (sidecar process lifecycle), FridayAssistant (the
// orchestrator that ties voice, chat, intelligence and tools together).
//
// Dependency direction (arrows point at what a module may import):
//
//   wake word:   FridayPlatform ──► WakeWordCore ──► FridayAudio ──► WakeWordKit ◄── {Sherpa,Porcupine}Backend ──► C module
//   actions:     FridayIPC / FridayInterpreter / FridayIntegrations ──► FridayCore
//   new layers:  FridayAssistant ──► FridayIntelligence, FridaySpeech, FridayBrowser, FridaySidecar ──► FridayCore
//                FridayComputer, FridayMemory ──► FridayCore (wired to the assistant by App/Composition; never imported by it)
//
// Nothing outside a wake-word backend may import its C module, and nothing outside the composition root
// (App/Composition) and the benchmark tool may import a backend. `ArchitectureBoundaryTests` enforces this.

let package = Package(
    name: "FridayKit",
    platforms: [.macOS(.v14)],
    products: [
        // Wake word (from Speech)
        .library(name: "WakeWordKit", targets: ["WakeWordKit"]),
        .library(name: "PorcupineBackend", targets: ["PorcupineBackend"]),
        .library(name: "SherpaOnnxBackend", targets: ["SherpaOnnxBackend"]),
        .library(name: "FridayAudio", targets: ["FridayAudio"]),
        .library(name: "WakeWordCore", targets: ["WakeWordCore"]),
        .library(name: "FridayPlatform", targets: ["FridayPlatform"]),
        .executable(name: "friday-bench", targets: ["FridayBench"]),
        // Action engine and integrations (from Apple-Integrations)
        .library(name: "FridayCore", targets: ["FridayCore"]),
        .library(name: "FridayInterpreter", targets: ["FridayInterpreter"]),
        .library(name: "FridayIntegrations", targets: ["FridayIntegrations"]),
        .library(name: "FridayIPC", targets: ["FridayIPC"]),
        .executable(name: "fridayctl", targets: ["fridayctl"]),
        // New in Friday
        .library(name: "FridayIntelligence", targets: ["FridayIntelligence"]),
        .library(name: "FridaySpeech", targets: ["FridaySpeech"]),
        .library(name: "SherpaOnnxSpeech", targets: ["SherpaOnnxSpeech"]),
        .library(name: "FridayMemory", targets: ["FridayMemory"]),
        .library(name: "FridayComputer", targets: ["FridayComputer"]),
        .library(name: "FridayBrowser", targets: ["FridayBrowser"]),
        .library(name: "FridaySidecar", targets: ["FridaySidecar"]),
        .library(name: "FridayAssistant", targets: ["FridayAssistant"]),
    ],
    targets: [
        // MARK: Wake word (from Speech, unchanged apart from module names)
        .target(name: "CPorcupine", publicHeadersPath: "include"),
        .target(name: "WakeWordKit"),
        .target(name: "PorcupineBackend", dependencies: ["WakeWordKit", "CPorcupine"]),
        .target(name: "CSherpaOnnx", publicHeadersPath: "include"),
        .target(name: "SherpaOnnxBackend", dependencies: ["WakeWordKit", "CSherpaOnnx"]),
        .target(name: "FridayAudio", dependencies: ["WakeWordKit"]),
        .target(name: "WakeWordCore", dependencies: ["WakeWordKit", "FridayAudio"]),
        .target(name: "FridayPlatform", dependencies: ["WakeWordKit", "FridayAudio", "WakeWordCore"]),
        .executableTarget(
            name: "FridayBench",
            dependencies: ["WakeWordKit", "FridayAudio", "WakeWordCore", "FridayPlatform", "PorcupineBackend", "SherpaOnnxBackend"]
        ),

        // MARK: Action engine (from Apple-Integrations, unchanged apart from module names)
        .target(name: "FridayCore"),
        .target(name: "FridayInterpreter", dependencies: ["FridayCore"]),
        .target(name: "FridayIntegrations", dependencies: ["FridayCore"]),
        .target(name: "FridayIPC", dependencies: ["FridayCore"]),
        .executableTarget(name: "fridayctl", dependencies: ["FridayIPC", "FridayCore"]),

        // MARK: New Friday modules
        .target(name: "FridayIntelligence", dependencies: ["FridayCore", "FridayInterpreter", "FridaySidecar"]),
        // Engine-independent speech contracts + Apple engines (SpeechAnalyzer, AVSpeechSynthesizer) + audio plumbing.
        .target(name: "FridaySpeech", dependencies: ["FridayCore", "WakeWordKit"]),
        // sherpa-onnx engines for speech: Kokoro text-to-speech and Silero voice activity. The only module besides the
        // wake-word backend that may import CSherpaOnnx (ArchitectureTests know about it).
        .target(name: "SherpaOnnxSpeech", dependencies: ["FridaySpeech", "FridayCore", "CSherpaOnnx"]),
        .target(name: "FridayMemory", dependencies: ["FridayCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "FridayComputer", dependencies: ["FridayCore"]),
        .target(name: "FridaySidecar", dependencies: ["FridayCore"]),
        .target(name: "FridayBrowser", dependencies: ["FridayCore", "FridaySidecar"]),
        .target(
            name: "FridayAssistant",
            dependencies: [
                "FridayCore", "FridayInterpreter", "FridayIntegrations", "FridayIntelligence", "FridaySpeech",
                "FridayBrowser", "FridaySidecar", "WakeWordKit", "FridayAudio", "WakeWordCore",
            ]),

        // MARK: Tests
        .testTarget(name: "WakeWordKitTests", dependencies: ["WakeWordKit"]),
        .testTarget(name: "FridayAudioTests", dependencies: ["FridayAudio", "WakeWordKit"]),
        .testTarget(name: "WakeWordCoreTests", dependencies: ["WakeWordCore", "FridayAudio", "WakeWordKit"]),
        .testTarget(name: "FridayPlatformTests", dependencies: ["FridayPlatform", "WakeWordCore", "WakeWordKit"]),
        .testTarget(name: "PorcupineBackendTests", dependencies: ["PorcupineBackend", "WakeWordKit"]),
        .testTarget(
            name: "SherpaOnnxBackendTests",
            dependencies: ["SherpaOnnxBackend", "WakeWordKit", "WakeWordCore", "FridayAudio"]
        ),
        .testTarget(name: "ArchitectureTests"),
        .testTarget(name: "FridayCoreTests", dependencies: ["FridayCore"]),
        .testTarget(name: "FridayInterpreterTests", dependencies: ["FridayInterpreter", "FridayCore"]),
        .testTarget(name: "FridayIntegrationsTests", dependencies: ["FridayIntegrations", "FridayCore", "FridayInterpreter"]),
        .testTarget(name: "FridayIPCTests", dependencies: ["FridayIPC", "FridayCore", "FridayInterpreter"]),
        .testTarget(name: "FridayIntelligenceTests", dependencies: ["FridayIntelligence", "FridayCore"]),
        .testTarget(name: "FridaySpeechTests", dependencies: ["FridaySpeech", "FridayCore"]),
        .testTarget(name: "SherpaOnnxSpeechTests", dependencies: ["SherpaOnnxSpeech", "FridaySpeech", "FridayCore"]),
        .testTarget(name: "FridayMemoryTests", dependencies: ["FridayMemory", "FridayCore"]),
        .testTarget(name: "FridayComputerTests", dependencies: ["FridayComputer", "FridayCore"]),
        .testTarget(name: "FridayBrowserTests", dependencies: ["FridayBrowser", "FridaySidecar", "FridayCore"]),
        .testTarget(name: "FridayAssistantTests", dependencies: ["FridayAssistant"]),
    ],
    swiftLanguageModes: [.v6]
)
