import Foundation
import WakeWordCore
import Network
import WakeWordKit

/// Reachability from `NWPathMonitor`. The system calls back only when the network path changes, so
/// this costs nothing while connectivity is steady.
public final class NWPathNetworkMonitor: NetworkAvailability, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "jarvis.network", qos: .utility)
    /// Optimistic until the first path report, so start-up is not delayed by a false "offline".
    private let online = Protected(true)
    private let broadcaster = Broadcaster<Bool>()

    public init() {
        monitor.pathUpdateHandler = { [online, broadcaster] path in
            let isOnline = path.status == .satisfied
            let changed = online.withLock { state -> Bool in
                defer { state = isOnline }
                return state != isOnline
            }
            if changed { broadcaster.send(isOnline) }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public var isOnline: Bool { online.get() }

    public func changes() -> AsyncStream<Bool> { broadcaster.stream(bufferingPolicy: .bufferingNewest(1)) }
}
