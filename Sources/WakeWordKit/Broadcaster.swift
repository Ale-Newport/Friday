import Foundation

/// Fans one stream of events out to any number of `AsyncStream` subscribers. Event-driven: there
/// are no timers or polling loops; a subscriber that stops listening is removed automatically.
public final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let continuations = Protected<[UUID: AsyncStream<Element>.Continuation]>([:])

    public init() {}

    /// A new stream that receives every element sent from now on, optionally starting with `initial`.
    public func stream(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded,
        initial: Element? = nil
    ) -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        if let initial { continuation.yield(initial) }
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }
        return stream
    }

    public func send(_ element: Element) {
        let current = continuations.withLock { Array($0.values) }
        for continuation in current { continuation.yield(element) }
    }

    /// Ends every subscriber's stream.
    public func finish() {
        let current = continuations.withLock { state -> [AsyncStream<Element>.Continuation] in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        for continuation in current { continuation.finish() }
    }

    public var subscriberCount: Int { continuations.withLock { $0.count } }
}
