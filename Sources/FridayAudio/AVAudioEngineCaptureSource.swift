import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import WakeWordKit

/// Microphone capture with `AVAudioEngine`.
///
/// * **One stream, input only**: a private engine whose only job is a tap on the input node. No
///   output node is connected and nothing is written anywhere.
/// * **Cheap callback**: the tap hands channel 0 of the hardware buffer straight to the handler —
///   no conversion, no copy, no allocation in the callback. Sample-rate conversion happens
///   downstream, driven by what the active engine asks for.
/// * **Few wake-ups**: the tap is requested at 100 ms — the smallest size AVAudioEngine supports (its header
///   documents a 100–400 ms range) — i.e. about ten callbacks per second.
/// * **Self-healing signals**: route and format changes arrive as ``AudioCaptureEvent`` values;
///   the source stops itself and leaves restarting to its owner.
public final class AVAudioEngineCaptureSource: AudioCaptureSource, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Requested tap length in seconds (AVAudioEngine accepts 0.1–0.4). Longer means fewer
        /// wake-ups but proportionally later detection.
        public var bufferDuration: Double
        public init(bufferDuration: Double = 0.1) { self.bufferDuration = bufferDuration }
    }

    private struct Running {
        let engine: AVAudioEngine
        let observer: NSObjectProtocol
        let info: AudioCaptureInfo
    }

    private let configuration: Configuration
    private let permission: any MicrophonePermissionProviding
    private let broadcaster = Broadcaster<AudioCaptureEvent>()
    private let state = Protected<Running?>(nil)

    public init(configuration: Configuration = Configuration(), permission: any MicrophonePermissionProviding = SystemMicrophonePermission()) {
        self.configuration = configuration
        self.permission = permission
    }

    deinit { stop() }

    public var isRunning: Bool { state.withLock { $0?.engine.isRunning ?? false } }

    public func events() -> AsyncStream<AudioCaptureEvent> { broadcaster.stream() }

    @discardableResult
    public func start(input: AudioInputSelection, handler: @escaping AudioChunkHandler) throws(AudioCaptureError) -> AudioCaptureInfo {
        stop()

        let authorization = permission.status()
        guard authorization == .authorized else { throw .microphoneNotAuthorized(authorization) }

        // Never touch `inputNode` on a Mac with no input device: AVAudioEngine can raise an
        // Objective-C exception there, which Swift cannot catch.
        let selectedID: AudioDeviceID?
        switch input {
        case .systemDefault:
            guard CoreAudioDeviceCatalog.defaultInputDeviceID() != nil else { throw .noInputDevice }
            selectedID = nil
        case .device(let uid):
            guard let id = CoreAudioDeviceCatalog.deviceID(forUID: uid) else { throw .deviceUnavailable(uid: uid) }
            selectedID = id
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if let selectedID { try Self.select(device: selectedID, on: inputNode) }

        // A device that exists but reports no usable format is usually mid-switch (a Bluetooth headset changing
        // profile, a sample-rate change). That passes on its own, so it is a retryable engine failure — not
        // "no input device", which would leave the app waiting for the user.
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate >= 4_000, format.channelCount >= 1 else {
            throw .engineFailed("the input device reported an unusable audio format (\(Int(format.sampleRate)) Hz, \(format.channelCount) channels)")
        }

        // Round up: the supported tap range starts at 100 ms, and a hair under it is out of range.
        let tapFrames = AVAudioFrameCount(max(1_024, (format.sampleRate * configuration.bufferDuration).rounded(.up)))
        let scratch = Scratch()
        let tap: AVAudioNodeTapBlock = { buffer, time in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            let rate = buffer.format.sampleRate
            let hostTime = time.isHostTimeValid
                ? HostTime(ticks: time.hostTime)
                : HostTime.now.advanced(bySeconds: -Double(count) / rate)
            let stride = buffer.stride
            if stride == 1 {
                handler(UnsafeBufferPointer(start: channels[0], count: count), rate, hostTime)
            } else {
                // Interleaved layout (not what the input node normally delivers): pick channel 0.
                let mono = scratch.pointer(capacity: count)
                for index in 0..<count { mono[index] = channels[0][index * stride] }
                handler(UnsafeBufferPointer(start: mono, count: count), rate, hostTime)
            }
        }
        try Self.install(tap: tap, on: inputNode, frames: tapFrames, format: format)

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            self.engineConfigurationChanged(engine)
        }

        let device = (selectedID ?? CoreAudioDeviceCatalog.defaultInputDeviceID()).flatMap(CoreAudioDeviceCatalog.describe)
        let info = AudioCaptureInfo(
            deviceName: device?.name ?? "Microphone",
            deviceUID: device?.uid,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
        // Publish before starting: a configuration change that fires while the engine is still starting must
        // find this capture registered as the current one, or it would be ignored and the microphone would
        // silently stay deaf.
        state.withLock { $0 = Running(engine: engine, observer: observer, info: info) }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            let stillOurs = state.withLock { state -> Bool in
                guard state?.engine === engine else { return false }
                state = nil
                return true
            }
            if stillOurs {
                inputNode.removeTap(onBus: 0)
                NotificationCenter.default.removeObserver(observer)
            }
            throw .engineFailed(error.localizedDescription)
        }

        // If the route changed during the start, the change handler has already torn this capture down and told
        // the owner; reporting success for a capture that no longer exists would hide that.
        guard state.withLock({ $0?.engine === engine }), engine.isRunning else {
            throw .engineFailed("the audio configuration changed while the microphone was starting")
        }
        return info
    }

    public func stop() {
        let running = state.withLock { state -> Running? in
            let current = state
            state = nil
            return current
        }
        guard let running else { return }
        NotificationCenter.default.removeObserver(running.observer)
        running.engine.inputNode.removeTap(onBus: 0)
        running.engine.stop()
    }

    // MARK: - Private

    private func engineConfigurationChanged(_ engine: AVAudioEngine) {
        let isCurrent = state.withLock { $0?.engine === engine }
        guard isCurrent else { return }
        // The engine has already stopped itself; release it fully and let the owner decide.
        stop()
        broadcaster.send(.configurationChanged)
    }

    /// Installs the tap. On macOS 27+ this uses the variant that *reports* a bad format or state as an error;
    /// the older call raises an Objective-C exception, which Swift cannot catch and which would take the
    /// whole always-on app down. Older systems use the old call, guarded by the format checks in `start`.
    private static func install(
        tap: @escaping AVAudioNodeTapBlock, on node: AVAudioInputNode, frames: AVAudioFrameCount, format: AVAudioFormat
    ) throws(AudioCaptureError) {
        // The throwing variant only exists in the macOS 27 SDK (Xcode 27, Swift 6.4). Builds with an older SDK
        // (Xcode 26, e.g. CI runners) use the classic call, exactly as macOS 26 systems do at run time.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            do {
                try node.__installTap(onBus: 0, bufferSize: frames, format: format, error: (), block: tap)
            } catch {
                throw .engineFailed("the microphone tap could not be installed: \(error.localizedDescription)")
            }
            return
        }
        #endif
        node.installTap(onBus: 0, bufferSize: frames, format: format, block: tap)
    }

    private static func select(device: AudioDeviceID, on node: AVAudioInputNode) throws(AudioCaptureError) {
        guard let unit = node.audioUnit else { throw .engineFailed("the input node has no audio unit") }
        var deviceID = device
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw .engineFailed("could not select the input device (OSStatus \(status))") }
    }

    /// Lazily grown mono scratch buffer, touched only by the tap thread.
    private final class Scratch: @unchecked Sendable {
        private var storage: UnsafeMutablePointer<Float>?
        private var capacity = 0
        func pointer(capacity needed: Int) -> UnsafeMutablePointer<Float> {
            if needed > capacity || storage == nil {
                storage?.deallocate()
                storage = .allocate(capacity: needed)
                capacity = needed
            }
            return storage!
        }
        deinit { storage?.deallocate() }
    }
}
