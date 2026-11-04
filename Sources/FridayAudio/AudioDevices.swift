import CoreAudio
import Foundation
import WakeWordKit

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public enum Transport: String, Sendable {
        case builtIn, usb, bluetooth, virtual, aggregate, other
    }

    /// Persistent identifier (survives reboots and re-plugging). Use this for stored preferences.
    public let uid: String
    public let name: String
    public let transport: Transport
    public let inputChannelCount: Int

    public var id: String { uid }

    public init(uid: String, name: String, transport: Transport, inputChannelCount: Int) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.inputChannelCount = inputChannelCount
    }
}

public enum AudioDeviceChange: Equatable, Sendable {
    /// A device appeared or disappeared.
    case deviceListChanged
    /// The system default input device changed.
    case defaultInputChanged
}

/// Lists input devices and reports when they change.
public protocol AudioDeviceProviding: Sendable {
    func inputDevices() -> [AudioInputDevice]
    func defaultInputDevice() -> AudioInputDevice?
    /// Each call returns an independent stream. Event-driven (Core Audio property listeners).
    func changes() -> AsyncStream<AudioDeviceChange>
}

/// Core Audio HAL implementation. Enumeration is on demand; change notification uses property
/// listeners, so nothing runs while devices stay the same.
public final class CoreAudioDeviceCatalog: AudioDeviceProviding, @unchecked Sendable {
    private let broadcaster = Broadcaster<AudioDeviceChange>()
    private let listenerQueue = DispatchQueue(label: "jarvis.audio.device-listener", qos: .utility)
    private let registration = Protected<[(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]>([])

    public init() {}

    deinit {
        let listeners = registration.withLock { state -> [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] in
            let current = state
            state = []
            return current
        }
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        }
    }

    // MARK: AudioDeviceProviding

    public func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap(Self.describe).filter { $0.inputChannelCount > 0 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func defaultInputDevice() -> AudioInputDevice? {
        guard let id = Self.defaultInputDeviceID() else { return nil }
        return Self.describe(id)
    }

    public func changes() -> AsyncStream<AudioDeviceChange> {
        registerListenersIfNeeded()
        return broadcaster.stream()
    }

    // MARK: Lookups used by capture

    /// The current Core Audio object for a persistent UID, if the device is connected.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { describeUID($0) == uid }
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    public static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = describeUID(id), !isHidden(id) else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
        return AudioInputDevice(
            uid: uid, name: name, transport: transport(of: id), inputChannelCount: inputChannelCount(of: id)
        )
    }

    // MARK: Core Audio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    private func allDeviceIDs() -> [AudioDeviceID] { Self.allDeviceIDs() }

    private static func describeUID(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func transport(of id: AudioDeviceID) -> AudioInputDevice.Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr else { return .other }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        default: return .other
        }
    }

    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func registerListenersIfNeeded() {
        registration.withLock { listeners in
            guard listeners.isEmpty else { return }
            let selectors: [(AudioObjectPropertySelector, AudioDeviceChange)] = [
                (kAudioHardwarePropertyDevices, .deviceListChanged),
                (kAudioHardwarePropertyDefaultInputDevice, .defaultInputChanged),
            ]
            for (selector, change) in selectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
                )
                let broadcaster = self.broadcaster
                let block: AudioObjectPropertyListenerBlock = { _, _ in broadcaster.send(change) }
                if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block) == noErr {
                    listeners.append((address, block))
                }
            }
        }
    }
}
