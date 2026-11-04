import Darwin

/// A minimal `os_unfair_lock` wrapper. Unfair locks are the right primitive for audio-adjacent
/// code: no allocation or syscall on the uncontended path, and priority donation protects a
/// high-priority audio thread from a low-priority lock holder.
public final class UnfairLock: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// Runs `body` while holding the lock. Generic over the error type so typed throws
    /// (`throws(WakeWordError)`) propagate unchanged; non-throwing closures need no `try`.
    @inline(__always)
    public func withLock<Result, Failure: Error>(_ body: () throws(Failure) -> Result) throws(Failure) -> Result {
        os_unfair_lock_lock(storage)
        defer { os_unfair_lock_unlock(storage) }
        return try body()
    }
}

/// A value guarded by an unfair lock. The "unchecked" Sendable conformance is sound because the
/// only way to touch the value is through `withLock`.
public final class Protected<Value>: @unchecked Sendable {
    private let lock = UnfairLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    @inline(__always)
    public func withLock<Result, Failure: Error>(_ body: (inout Value) throws(Failure) -> Result) throws(Failure) -> Result {
        try lock.withLock { () throws(Failure) -> Result in try body(&value) }
    }

    /// A copy of the current value.
    public func get() -> Value {
        lock.withLock { value }
    }
}
