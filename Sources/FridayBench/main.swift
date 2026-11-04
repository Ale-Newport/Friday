import Foundation
import FridayAudio
import WakeWordCore
import FridayPlatform
import PorcupineBackend
import SherpaOnnxBackend
import WakeWordKit

// jarvis-bench — measurements for the wake-word pipeline. Nothing here records audio.
//
//   jarvis-bench probe [--vendor DIR]
//   jarvis-bench devices
//   jarvis-bench pipeline [--seconds 600] [--rate 48000] [--engine mock|sherpa|porcupine] [--vendor DIR] [--sherpa DIR]
//   jarvis-bench idle     [--seconds 30]  [--engine mock|sherpa|porcupine] [--vendor DIR] [--sherpa DIR]
//   jarvis-bench latency  [--count 200]
//   jarvis-bench soak     [--seconds 300]
//   jarvis-bench measure --pid PID [--seconds 30]
//
// A Picovoice AccessKey, when needed, is read from the PICOVOICE_ACCESS_KEY environment variable.
// It is never printed. This tool is the only place in the project allowed to do that.

struct Options {
    var command = "help"
    var seconds = 30.0
    var rate = 48_000.0
    var engine = "mock"
    var vendor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/Porcupine")
    var sherpa = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/SherpaOnnx")
    var profile = "phone16"
    var pid: Int32?
    var json = false
    var count = 200

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        if let first = iterator.next() { command = first }
        while let flag = iterator.next() {
            switch flag {
            case "--seconds": seconds = iterator.next().flatMap(Double.init) ?? seconds
            case "--rate": rate = iterator.next().flatMap(Double.init) ?? rate
            case "--engine": engine = iterator.next() ?? engine
            case "--vendor": vendor = URL(fileURLWithPath: iterator.next() ?? vendor.path)
            case "--sherpa": sherpa = URL(fileURLWithPath: iterator.next() ?? sherpa.path)
            case "--profile": profile = iterator.next() ?? profile
            case "--pid": pid = iterator.next().flatMap(Int32.init)
            case "--count": count = iterator.next().flatMap(Int.init) ?? count
            case "--json": json = true
            default: break
            }
        }
    }

    var sherpaResources: EngineResourceLocator {
        EngineResourceLocator(
            searchDirectories: [sherpa.appendingPathComponent("models")],
            libraryDirectories: [sherpa.appendingPathComponent("lib")]
        )
    }

    var resources: EngineResourceLocator {
        EngineResourceLocator(
            searchDirectories: [vendor.appendingPathComponent("models"), vendor.appendingPathComponent("keywords")],
            libraryDirectories: [vendor.appendingPathComponent("lib")]
        )
    }
}

func machine() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var chars = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)
    let cpu = String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return "\(cpu), \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.processorCount) cores"
}

func fmt(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }

/// Builds the requested engine. The mock used for benchmarks never triggers, so the pipeline keeps running.
func makeEngine(_ options: Options) async throws(WakeWordError) -> (engine: any WakeWordEngine, descriptor: EngineDescriptor) {
    if options.engine == "sherpa" {
        let descriptor = SherpaOnnxBackend.descriptor
        let engine: any WakeWordEngine
        if let chosen = profile(named: options.profile), options.profile != "phone16" {
            // A model variant under evaluation rather than the shipped default.
            let directory = options.sherpa.appendingPathComponent("models/\(chosen.directory)")
            engine = SherpaOnnxWakeWordEngine(configuration: .init(
                libraryURL: options.sherpa.appendingPathComponent("lib/libsherpa-onnx-c-api.dylib"),
                model: .init(
                    encoder: directory.appendingPathComponent(chosen.encoder), decoder: directory.appendingPathComponent(chosen.decoder),
                    joiner: directory.appendingPathComponent(chosen.joiner), tokens: directory.appendingPathComponent(chosen.tokens)
                ),
                pronunciations: chosen.pronunciations,
                integrity: .unverified   // a variant under evaluation: its files have no pinned digests
            ))
        } else {
            engine = try descriptor.makeEngine(EngineEnvironment(resources: options.sherpaResources))
        }
        try await engine.initialize()
        return (engine, descriptor)
    }
    if options.engine != "porcupine" {
        let engine = MockWakeWordEngine()
        try await engine.initialize()
        return (engine, MockWakeWordEngine.descriptor())
    }
    let credentials = InMemoryCredentialStore()
    if let key = ProcessInfo.processInfo.environment["PICOVOICE_ACCESS_KEY"] {
        try? credentials.setSecret(key, for: PorcupineBackend.accessKeyCredential)
    }
    let environment = EngineEnvironment(credentials: credentials, resources: options.resources)
    let descriptor = PorcupineBackend.descriptor
    let engine = try descriptor.makeEngine(environment)
    try await engine.initialize()
    return (engine, descriptor)
}

// MARK: - probe

func probe(_ options: Options) async {
    print("Porcupine backend probe")
    print("  machine : \(machine())")
    let environment = EngineEnvironment(resources: options.resources)
    switch PorcupineBackend.descriptor.preflight(environment) {
    case .ready: print("  files   : library, model and “Jarvis” keyword found under \(options.vendor.path)")
    case .unavailable(let reason): print("  files   : NOT READY — \(reason)")
    }
    if let library = options.resources.locateLibrary("libpv_porcupine.dylib") {
        switch PorcupineBackend.inspectLibrary(at: library) {
        case .success(let info):
            print("  library : loads; reports version \(info.version), \(info.sampleRate) Hz, \(info.frameLength)-sample frames")
        case .failure(let error):
            print("  library : FAILED to load — \(error.errorDescription ?? "\(error)")")
        }
    }
    let hasKey = ProcessInfo.processInfo.environment["PICOVOICE_ACCESS_KEY"] != nil
    print("  key     : PICOVOICE_ACCESS_KEY is \(hasKey ? "set" : "not set")")
    if hasKey {
        let started = HostTime.now
        do {
            let (engine, _) = try await makeEngine(Options(["x", "probe", "--engine", "porcupine", "--vendor", options.vendor.path]))
            let requirements = engine.audioRequirements
            print("  engine  : initialised in \(fmt(HostTime.now.seconds(since: started) * 1000, 0)) ms — \(requirements.sampleRate) Hz, \(requirements.frameLength)-sample frames")
            engine.shutdown()
        } catch {
            print("  engine  : FAILED — \(error.errorDescription ?? "\(error)")")
            if let hint = error.recoverySuggestion { print("            \(hint)") }
        }
    }
    print("  mic     : \(SystemMicrophonePermission().status())")
}

func devices() {
    let catalog = CoreAudioDeviceCatalog()
    let defaultUID = catalog.defaultInputDevice()?.uid
    print("Input devices")
    for device in catalog.inputDevices() {
        print("  \(device.uid == defaultUID ? "▶" : " ") \(device.name)  [\(device.transport.rawValue), \(device.inputChannelCount) ch]  uid=\(device.uid)")
    }
    print("Microphone permission: \(SystemMicrophonePermission().status())")
}

// MARK: - pipeline (accelerated)

func pipeline(_ options: Options) async {
    let engineResult: (engine: any WakeWordEngine, descriptor: EngineDescriptor)
    do { engineResult = try await makeEngine(options) } catch {
        print("Cannot start the \(options.engine) engine: \(error.errorDescription ?? "\(error)")")
        exit(2)
    }
    let engine = engineResult.engine
    // Never gate: a benchmark must keep feeding the engine whatever it reports.
    let pipeline = WakeWordPipeline(configuration: .init(gateOnAcceptedDetection: false)) { _ in }
    do { try pipeline.install(engine) } catch { print("install failed: \(error)"); exit(2) }

    // Deterministic speech-like input: a few modulated tones plus noise, at the microphone's rate.
    let chunkFrames = Int(options.rate / 10)
    var generator = SystemRandomNumberGenerator()
    var phase = 0.0
    func makeChunk() -> [Float] {
        (0..<chunkFrames).map { _ in
            phase += 1
            let t = phase / options.rate
            let voiced = 0.15 * sin(2 * .pi * 180 * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t)) + 0.05 * sin(2 * .pi * 2_400 * t)
            return Float(voiced) + 0.01 * Float.random(in: -1...1, using: &generator)
        }
    }
    let chunks = Int(options.seconds * 10)
    let prepared = (0..<min(chunks, 50)).map { _ in makeChunk() }   // reuse a pool so generation is not measured

    let before = ResourceSampler.sample()!
    let started = HostTime.now
    var time = HostTime.now
    for index in 0..<chunks {
        pipeline.ingest(prepared[index % prepared.count], sampleRate: options.rate, hostTime: time)
        time = time.advanced(bySeconds: 0.1)
    }
    let wall = HostTime.now.seconds(since: started)
    let after = ResourceSampler.sample()!
    let usage = ResourceSampler.usage(from: before, to: after)!
    let statistics = pipeline.statistics()
    engine.shutdown()

    let audioSeconds = Double(chunks) / 10
    let cpu = after.cpuSeconds - before.cpuSeconds
    print("Pipeline benchmark — engine: \(options.engine), \(Int(options.rate)) Hz input → \(engine.audioRequirements.sampleRate) Hz / \(engine.audioRequirements.frameLength)-sample frames")
    print("  machine            : \(machine())")
    print("  audio processed    : \(fmt(audioSeconds, 0)) s in \(fmt(wall, 3)) s wall (\(fmt(audioSeconds / wall, 0))× real time)")
    print("  CPU time           : \(fmt(cpu * 1000, 1)) ms  →  \(fmt(cpu / audioSeconds * 100, 4)) % of one core when running in real time")
    print("  frames             : \(statistics.framesProcessed)  (\(fmt(Double(statistics.framesProcessed) / audioSeconds, 1)) per second)")
    print("  engine time/frame  : avg \(fmt(statistics.engineProcessTime.averageSeconds * 1e6, 1)) µs, max \(fmt(statistics.engineProcessTime.maxSeconds * 1e6, 1)) µs")
    print("  whole pipeline     : \(fmt(cpu / Double(max(1, statistics.framesProcessed)) * 1e6, 1)) µs of CPU per frame (resample + frame + engine + validate)")
    print("  energy             : \(fmt((after.energyJoules - before.energyJoules) * 1000, 2)) mJ for \(fmt(audioSeconds, 0)) s of audio = \(fmt((after.energyJoules - before.energyJoules) / audioSeconds * 1000, 3)) mW average if run in real time")
    print("  footprint          : \(fmt(usage.footprintMegabytes, 1)) MB (peak \(fmt(usage.peakFootprintMegabytes, 1)) MB)")
}

// MARK: - idle (real time, full runtime)

struct SimpleDevices: AudioDeviceProviding {
    func inputDevices() -> [AudioInputDevice] { [] }
    func defaultInputDevice() -> AudioInputDevice? { nil }
    func changes() -> AsyncStream<AudioDeviceChange> { AsyncStream { _ in } }
}

struct AlwaysAuthorized: MicrophonePermissionProviding {
    func status() -> MicrophoneAuthorization { .authorized }
    func request() async -> MicrophoneAuthorization { .authorized }
}

func idle(_ options: Options) async {
    let credentials = InMemoryCredentialStore()
    if let key = ProcessInfo.processInfo.environment["PICOVOICE_ACCESS_KEY"] {
        try? credentials.setSecret(key, for: PorcupineBackend.accessKeyCredential)
    }
    let registry = WakeWordEngineRegistry([SherpaOnnxBackend.descriptor, PorcupineBackend.descriptor, MockWakeWordEngine.descriptor()])
    let source = SyntheticAudioSource(sampleRate: options.rate)
    source.setSignal(.whiteNoise(amplitude: 0.002))   // a quiet room
    var settings = RuntimeSettings(engineID: options.engine == "sherpa" ? SherpaOnnxBackend.engineID : options.engine)
    settings.developerMode = true
    let runtime = WakeWordRuntime(
        settings: settings,
        dependencies: RuntimeDependencies(
            registry: registry, credentials: credentials, resources: options.engine == "sherpa" ? options.sherpaResources : options.resources,
            capture: source, devices: SimpleDevices(), permission: AlwaysAuthorized()
        )
    )
    await runtime.start()

    // Wait for the runtime to come up (an engine may need the network).
    let deadline = ContinuousClock.now + .seconds(30)
    var snapshot = await runtime.snapshot()
    while snapshot.state != .listening, ContinuousClock.now < deadline {
        if case .error(let failure) = snapshot.state {
            print("Runtime could not start: \(failure.message)")
            await runtime.stop()
            exit(2)
        }
        try? await Task.sleep(for: .milliseconds(50))
        snapshot = await runtime.snapshot()
    }
    guard snapshot.state == .listening else { print("Timed out waiting for the runtime."); exit(2) }

    source.beginRealTimeGeneration(chunkDuration: 0.1)
    try? await Task.sleep(for: .seconds(2))     // settle
    let before = ResourceSampler.sample()!
    try? await Task.sleep(for: .seconds(options.seconds))
    let after = ResourceSampler.sample()!
    let statistics = await runtime.pipelineStatistics()
    let usage = ResourceSampler.usage(from: before, to: after)!
    await runtime.stop()

    print("Idle listening — engine: \(options.engine), synthetic microphone at \(Int(options.rate)) Hz in real time, \(fmt(options.seconds, 0)) s")
    print("  machine            : \(machine())")
    print("  CPU                : \(fmt(usage.cpuPercent, 3)) % of one core")
    print("  energy             : \(usage.averagePowerMilliwatts.map { fmt($0, 2) + " mW average" } ?? "n/a")")
    print("  wake-ups           : \(fmt(usage.wakeupsPerSecond, 1)) per second")
    print("  memory footprint   : \(fmt(usage.footprintMegabytes, 1)) MB (peak \(fmt(usage.peakFootprintMegabytes, 1)) MB)")
    print("  frames processed   : \(statistics.framesProcessed), engine avg \(fmt(statistics.engineProcessTime.averageSeconds * 1e6, 1)) µs/frame, max \(fmt(statistics.engineProcessTime.maxSeconds * 1e6, 1)) µs")
    print("  (synthetic audio: excludes the Core Audio HAL / AVAudioEngine cost of a real microphone — use `measure` on the app for that)")
}

// MARK: - measure (another process)

func measure(_ options: Options) async {
    guard let pid = options.pid, let first = ResourceSampler.sample(pid: pid) else {
        print("Cannot read process \(options.pid.map(String.init) ?? "(missing --pid)").")
        exit(2)
    }
    try? await Task.sleep(for: .seconds(options.seconds))
    guard let last = ResourceSampler.sample(pid: pid), let usage = ResourceSampler.usage(from: first, to: last) else {
        print("The process exited during the measurement.")
        exit(2)
    }
    if options.json {
        print("""
        {"pid":\(pid),"seconds":\(fmt(usage.intervalSeconds, 1)),"cpuPercent":\(fmt(usage.cpuPercent, 4)),"powerMilliwatts":\(usage.averagePowerMilliwatts.map { fmt($0, 3) } ?? "null"),"wakeupsPerSecond":\(fmt(usage.wakeupsPerSecond, 2)),"footprintMB":\(fmt(usage.footprintMegabytes, 1)),"peakFootprintMB":\(fmt(usage.peakFootprintMegabytes, 1))}
        """)
        return
    }
    print("Process \(pid) over \(fmt(usage.intervalSeconds, 1)) s")
    print("  CPU                : \(fmt(usage.cpuPercent, 3)) % of one core")
    print("  energy             : \(usage.averagePowerMilliwatts.map { fmt($0, 2) + " mW average" } ?? "n/a")")
    print("  wake-ups           : \(fmt(usage.wakeupsPerSecond, 1)) per second")
    print("  memory footprint   : \(fmt(usage.footprintMegabytes, 1)) MB (peak \(fmt(usage.peakFootprintMegabytes, 1)) MB)")
}


// MARK: - latency

/// Records when the assistant was notified.
final class TimingAssistant: AssistantActivationHandler, @unchecked Sendable {
    private let notified = Protected<[(event: WakeWordEvent, at: HostTime)]>([])
    var records: [(event: WakeWordEvent, at: HostTime)] { notified.get() }
    func onWakeWordDetected(_ event: WakeWordEvent, session: ActivationSession) async {
        notified.withLock { $0.append((event, .now)) }
        session.finish(.completed)
    }
}

func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
}

func summarise(_ title: String, _ samples: [Double]) {
    let sorted = samples.sorted()
    let mean = sorted.reduce(0, +) / Double(max(1, sorted.count))
    print("  \(title.padding(toLength: 44, withPad: " ", startingAt: 0)) mean \(fmt(mean * 1000, 2)) ms · p50 \(fmt(percentile(sorted, 0.5) * 1000, 2)) · p95 \(fmt(percentile(sorted, 0.95) * 1000, 2)) · max \(fmt((sorted.last ?? 0) * 1000, 2))")
}

/// Drives the real runtime through many full activations on a synthetic microphone that delivers
/// 100 ms buffers in real time (like AVAudioEngine's tap) and reports where the time goes.
func latency(_ options: Options) async {
    let engine = MockWakeWordEngine()
    let registry = WakeWordEngineRegistry([
        EngineDescriptor(
            id: "mock", displayName: "Mock", summary: "", capabilities: .init(supportsLiveSensitivity: true, reportsConfidence: false),
            makeEngine: { _ in engine }
        ),
    ])
    let source = SyntheticAudioSource(sampleRate: options.rate)
    source.setSignal(.whiteNoise(amplitude: 0.002))
    let assistant = TimingAssistant()
    var settings = RuntimeSettings(engineID: "mock")
    settings.cooldown = 0.5
    settings.postSessionHoldoff = 0
    let runtime = WakeWordRuntime(
        settings: settings,
        dependencies: RuntimeDependencies(
            registry: registry, credentials: InMemoryCredentialStore(), capture: source,
            devices: SimpleDevices(), permission: AlwaysAuthorized(), assistant: assistant
        )
    )
    await runtime.start()
    var snapshot = await runtime.snapshot()
    for _ in 0..<100 where snapshot.state != .listening { try? await Task.sleep(for: .milliseconds(20)); snapshot = await runtime.snapshot() }
    guard snapshot.state == .listening else { print("runtime did not start"); exit(2) }
    source.beginRealTimeGeneration(chunkDuration: 0.1)

    var done = 0
    while done < options.count {
        engine.trigger(afterFrames: Int.random(in: 0..<3))   // land on a random frame of the next 100 ms buffer
        let target = done + 1
        let deadline = ContinuousClock.now + .seconds(3)
        while assistant.records.count < target, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        guard assistant.records.count >= target else { print("timed out after \(done) activations"); break }
        done = target
        try? await Task.sleep(for: .milliseconds(650))   // let cooldown pass
    }
    await runtime.stop()

    let records = assistant.records
    print("Activation latency — \(records.count) full activations through the real runtime (mock engine, 100 ms microphone buffers)")
    print("  machine : \(machine())")
    summarise("end of detecting frame → engine reported", records.map(\.event.captureToDetectionLatency))
    summarise("engine reported → assistant notified", records.map { $0.at.seconds(since: $0.event.engineReturnTime) })
    summarise("end of detecting frame → assistant notified", records.map { max(0, $0.at.seconds(since: $0.event.audioEndTime)) })
    print("  Line 1 is how long the detecting frame waited inside the 100 ms microphone buffer plus DSP (0–100 ms, depends on where the word ends in the buffer);")
    print("  line 2 is the software path from the engine's answer to the assistant callback; on top of line 1 a word is recognised up to one frame (32 ms) after it ends.")
}


// MARK: - soak

final class DrivenSystemEvents: SystemEventSource, @unchecked Sendable {
    private let broadcaster = Broadcaster<SystemEvent>()
    func events() -> AsyncStream<SystemEvent> { broadcaster.stream() }
    func send(_ event: SystemEvent) { broadcaster.send(event) }
}

/// Starts real-time generation whenever the wrapped synthetic source is (re)started, like a microphone would.
final class RestartingSyntheticSource: AudioCaptureSource, @unchecked Sendable {
    let source: SyntheticAudioSource
    init(_ source: SyntheticAudioSource) { self.source = source }
    var isRunning: Bool { source.isRunning }
    func events() -> AsyncStream<AudioCaptureEvent> { source.events() }
    func stop() { source.stop() }
    @discardableResult
    func start(input: AudioInputSelection, handler: @escaping AudioChunkHandler) throws(AudioCaptureError) -> AudioCaptureInfo {
        let info = try source.start(input: input, handler: handler)
        source.beginRealTimeGeneration(chunkDuration: 0.1)
        return info
    }
}

/// Runs the whole runtime for a while under the events a real Mac produces — an activation every 3 s, a
/// microphone route change every 20 s, a sleep/wake cycle every 60 s — and checks that nothing accumulates.
func soak(_ options: Options) async {
    let engine = MockWakeWordEngine()
    let registry = WakeWordEngineRegistry([
        EngineDescriptor(
            id: "mock", displayName: "Mock", summary: "", capabilities: .init(supportsLiveSensitivity: true, reportsConfidence: false),
            makeEngine: { _ in engine }
        ),
    ])
    let synthetic = SyntheticAudioSource(sampleRate: options.rate)
    synthetic.setSignal(.whiteNoise(amplitude: 0.002))
    let system = DrivenSystemEvents()
    let assistant = TimingAssistant()
    var settings = RuntimeSettings(engineID: "mock")
    settings.cooldown = 0.5
    settings.postSessionHoldoff = 0.2
    let runtime = WakeWordRuntime(
        settings: settings,
        dependencies: RuntimeDependencies(
            registry: registry, credentials: InMemoryCredentialStore(), capture: RestartingSyntheticSource(synthetic),
            devices: SimpleDevices(), permission: AlwaysAuthorized(), systemEvents: system, assistant: assistant,
            timings: RuntimeTimings(captureRestartDebounce: .milliseconds(300), wakeSettleDelay: .milliseconds(800))
        )
    )
    await runtime.start()
    var snapshot = await runtime.snapshot()
    for _ in 0..<150 where snapshot.state != .listening { try? await Task.sleep(for: .milliseconds(20)); snapshot = await runtime.snapshot() }
    guard snapshot.state == .listening else { print("runtime did not start"); exit(2) }

    let events = await runtime.events()
    let counters = Protected((starts: 0, stops: 0, states: [String: Int]()))
    let listener = Task {
        for await event in events {
            counters.withLock { state in
                switch event {
                case .captureStarted: state.starts += 1
                case .captureStopped: state.stops += 1
                case .stateChanged(_, let to): state.states[String(describing: to).split(separator: "(").first.map(String.init) ?? "?", default: 0] += 1
                default: break
                }
            }
        }
    }

    let before = ResourceSampler.sample()!
    var footprints: [Double] = []
    var routeChanges = 0, sleeps = 0, triggers = 0
    for second in 1...Int(options.seconds) {
        try? await Task.sleep(for: .seconds(1))
        if second % 3 == 0 { engine.trigger(); triggers += 1 }
        if second % 20 == 10 { synthetic.simulateConfigurationChange(); routeChanges += 1 }
        if second % 60 == 30 {
            system.send(.willSleep); sleeps += 1
            try? await Task.sleep(for: .seconds(2))
            system.send(.didWake)
        }
        if second % 10 == 0, let sample = ResourceSampler.sample() { footprints.append(Double(sample.footprintBytes) / 1_048_576) }
    }
    // Let the last events settle, then require a healthy end state.
    try? await Task.sleep(for: .seconds(3))
    let final = await runtime.snapshot()
    let after = ResourceSampler.sample()!
    let usage = ResourceSampler.usage(from: before, to: after)!
    listener.cancel()
    let notified = assistant.records.count
    await runtime.stop()

    let summary = counters.get()
    print("Soak test — \(Int(options.seconds)) s with an activation every 3 s, a route change every 20 s, a sleep/wake every 60 s")
    print("  machine            : \(machine())")
    print("  triggers / notified: \(triggers) / \(notified)   (the rest fell inside the 0.5 s cooldown or a pause)")
    print("  route changes      : \(routeChanges)   sleep/wake cycles: \(sleeps)   microphone opened \(summary.starts)× / closed \(summary.stops)×")
    print("  final state        : \(final.state == .listening ? "listening ✓" : "NOT LISTENING: \(final.state)")   microphone \(final.capture != nil ? "open ✓" : "CLOSED")")
    if let first = footprints.first, let last = footprints.last, let peak = footprints.max() {
        print("  memory footprint   : first \(fmt(first, 1)) MB → last \(fmt(last, 1)) MB (peak \(fmt(peak, 1)) MB, growth \(fmt(last - first, 2)) MB)")
    }
    print("  CPU / energy       : \(fmt(usage.cpuPercent, 3)) % of one core, \(usage.averagePowerMilliwatts.map { fmt($0, 2) + " mW" } ?? "n/a"), \(fmt(usage.wakeupsPerSecond, 1)) wake-ups/s over the whole run")
    if final.state != .listening || final.capture == nil { exit(1) }
}

// MARK: - dispatch

let options = Options(CommandLine.arguments)
switch options.command {
case "probe": await probe(options)
case "devices": devices()
case "pipeline": await pipeline(options)
case "idle": await idle(options)
case "measure": await measure(options)
case "latency": await latency(options)
case "soak": await soak(options)
case "kws-eval": await kwsEval(CommandLine.arguments)
case "kws-wav": await kwsWAV(CommandLine.arguments)
case "kws-tune": await kwsTune(CommandLine.arguments)
case "kws-hear": await kwsHear(CommandLine.arguments)
default:
    print("""
    jarvis-bench — wake-word measurements (no audio is recorded)

      probe     [--vendor DIR]                       check the optional Porcupine engine's files, library and (if PICOVOICE_ACCESS_KEY is set) the key
      devices                                        list input devices and microphone permission
      pipeline  [--seconds 600] [--rate 48000] [--engine mock|sherpa|porcupine] [--sherpa DIR]
                                                     CPU cost of resample → frame → engine → validate, on accelerated synthetic audio
      idle      [--seconds 30] [--engine mock|sherpa|porcupine] [--sherpa DIR]
                                                     real-time idle listening of the full runtime on synthetic audio
      measure   --pid PID [--seconds 30] [--json]    CPU / energy / wake-ups / memory of another running process (for example the app)
      latency   [--count 200]                        activation latency of the full runtime over many simulated utterances (mock engine)
      soak      [--seconds 300]                      lifecycle stress: activations, microphone route changes and sleep/wake cycles; watches memory
      kws-tune  RECORDING… [--negatives RECORDING…] [--sensitivity S] [--install [--models DIR] | --out FILE]   |   --demo es --out FILE
                                                     find the pronunciations of "Jarvis" that suit YOUR voice from a few recordings; --install writes jarvis_pronunciations.txt
                                                     into the Models folder only if the list is better on utterances it did not learn from (the old file is kept as .previous)
      kws-hear  RECORDING…                           which sounds the model hears in each stretch of speech of a recording (why a “Jarvis” is missed)
      kws-eval  [--profile phone16|phone|phone16-fp32|phone-fp32|bpe] [--sweep] [--quick] [--boost B] [--threshold T] [--paths N] [--noise A] [--peak dBFS]
                [--set heldout|continuous|spanish] [--agc dBFS | --no-agc] [--crest K] [--click dBFS [--click-gap S]] [--verbose]
                                                     how well the free keyword spotter hears "Jarvis" (and what it wrongly hears), on voices synthesised with macOS `say`
      kws-wav   FILE.wav [--keywords "T T T/T T"] [--boost B] [--threshold T] [--profile P]
                                                     when does the free keyword spotter fire inside one 16 kHz mono WAV recording?
    """)
}
