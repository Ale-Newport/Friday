import Foundation
import WakeWordKit

/// Receives one buffer of mono `Float` samples. The pointer is valid only for the duration of
/// the call; the callee must copy anything it keeps. Called on a thread owned by the capture
/// source (never the main thread), so it must be quick and must not block.
public typealias AudioChunkHandler = @Sendable (_ samples: UnsafeBufferPointer<Float>, _ sampleRate: Double, _ hostTime: HostTime) -> Void

/// Which microphone to capture from.
public enum AudioInputSelection: Hashable, Sendable {
    /// Follow the system's default input device, including when it changes.
    case systemDefault
    /// A specific device, identified by its persistent Core Audio UID.
    case device(uid: String)
}

/// What a running capture is actually using (which may differ from what was asked for).
public struct AudioCaptureInfo: Equatable, Sendable {
    public var deviceName: String
    public var deviceUID: String?
    public var sampleRate: Double
    public var channelCount: Int

    public init(deviceName: String, deviceUID: String?, sampleRate: Double, channelCount: Int) {
        self.deviceName = deviceName
        self.deviceUID = deviceUID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Things that happen to a capture session on its own. Event-driven; there is no polling.
public enum AudioCaptureEvent: Equatable, Sendable {
    /// The audio route or format changed (device plugged/unplugged, sample rate switched, a Bluetooth
    /// headset changed profile …). The source has stopped itself; the owner should restart it.
    case configurationChanged
    /// Capture ended unexpectedly.
    case interrupted(reason: String)
    // Contract for both: the source is already stopped (`isRunning` is false) when it reports one. An owner that finds
    // the source running when the news reaches it has therefore restarted it in the meantime, and can ignore the news.
}

public enum AudioCaptureError: Error, Equatable, Sendable {
    case microphoneNotAuthorized(MicrophoneAuthorization)
    case noInputDevice
    case deviceUnavailable(uid: String)
    case engineFailed(String)
}

extension AudioCaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .microphoneNotAuthorized(.denied): "Microphone access is turned off for Jarvis."
        case .microphoneNotAuthorized(.restricted): "Microphone access is restricted on this Mac."
        case .microphoneNotAuthorized: "Jarvis has not been given microphone access yet."
        case .noInputDevice: "No microphone is available."
        case .deviceUnavailable: "The selected microphone is not connected."
        case .engineFailed(let detail): "The audio engine could not start: \(detail)"
        }
    }
}

/// A source of microphone audio. The detection pipeline depends only on this protocol, so tests
/// and benchmarks run on synthetic audio and the real microphone is one implementation among
/// several.
public protocol AudioCaptureSource: AnyObject, Sendable {
    /// Starts delivering audio to `handler`. Replaces any capture already running.
    @discardableResult
    func start(input: AudioInputSelection, handler: @escaping AudioChunkHandler) throws(AudioCaptureError) -> AudioCaptureInfo

    /// Stops delivery and releases the audio hardware. Idempotent.
    func stop()

    var isRunning: Bool { get }

    /// Events about the running capture. Each call returns an independent stream.
    func events() -> AsyncStream<AudioCaptureEvent>
}
