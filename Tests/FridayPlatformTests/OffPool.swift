import Foundation

/// Runs blocking work (a semaphore wait, a deliberately slow fake native call, a child process) on its own thread
/// and awaits the result, so a test never parks one of Swift concurrency's few cooperative threads. On a 3-core CI
/// runner the pool has 3 threads; tests that blocked them while waiting for work that needed a pool thread deadlocked
/// the whole run (#8).
func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: work()) }
        thread.start()
    }
}

extension DispatchSemaphore {
    /// `wait()` without holding a cooperative thread.
    func waitOffPool() async { await offPool { self.wait() } }
}
