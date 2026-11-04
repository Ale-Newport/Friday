import Darwin

/// A point on the machine's monotonic clock (the `mach_absolute_time` domain — the same domain
/// as `AVAudioTime.hostTime`). Audio frames are stamped with it so that latency can be measured
/// end to end without wall-clock jitter. The clock does not advance while the Mac sleeps.
public struct HostTime: Hashable, Comparable, Sendable {
    public var ticks: UInt64

    public init(ticks: UInt64) {
        self.ticks = ticks
    }

    /// The current host time.
    public static var now: HostTime { HostTime(ticks: mach_absolute_time()) }

    /// The clock's origin.
    public static let zero = HostTime(ticks: 0)

    /// A host time `seconds` after the clock's origin. Intended for tests and simulations.
    public init(seconds: Double) {
        self.init(ticks: UInt64(max(0, seconds) * 1_000_000_000 * Double(Self.timebase.denom) / Double(Self.timebase.numer)))
    }

    /// This instant moved by `seconds` (negative values move it earlier; saturates at zero).
    public func advanced(bySeconds seconds: Double) -> HostTime {
        let deltaTicks = seconds * 1_000_000_000 * Double(Self.timebase.denom) / Double(Self.timebase.numer)
        if deltaTicks >= 0 {
            return HostTime(ticks: ticks &+ UInt64(deltaTicks))
        }
        let magnitude = UInt64(-deltaTicks)
        return HostTime(ticks: ticks > magnitude ? ticks - magnitude : 0)
    }

    /// Signed seconds from `earlier` to `self`.
    public func seconds(since earlier: HostTime) -> Double {
        let numer = Double(Self.timebase.numer)
        let denom = Double(Self.timebase.denom)
        if ticks >= earlier.ticks {
            return Double(ticks - earlier.ticks) * numer / denom / 1_000_000_000
        }
        return -Double(earlier.ticks - ticks) * numer / denom / 1_000_000_000
    }

    public static func < (lhs: HostTime, rhs: HostTime) -> Bool { lhs.ticks < rhs.ticks }

    private static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer == 0 ? 1 : info.numer, info.denom == 0 ? 1 : info.denom)
    }()
}
