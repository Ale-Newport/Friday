import Darwin
import Foundation
import WakeWordKit

/// A cumulative reading of one process's resource counters (from `proc_pid_rusage`).
public struct ResourceSample: Equatable, Sendable {
    public var pid: Int32
    public var takenAt: HostTime
    /// User + system CPU time since the process started, in seconds.
    public var cpuSeconds: Double
    /// Energy attributed to the process since it started, in joules (`ri_energy_nj`).
    public var energyJoules: Double
    /// Physical memory footprint — the number Activity Monitor calls "Memory".
    public var footprintBytes: UInt64
    public var peakFootprintBytes: UInt64
    /// Wake-ups of the CPU from idle caused by interrupts / package idle exits.
    public var interruptWakeups: UInt64
    public var packageIdleWakeups: UInt64
    public var cycles: UInt64
    public var instructions: UInt64
}

/// Rates over the interval between two samples.
public struct ResourceUsage: Equatable, Sendable {
    public var intervalSeconds: Double
    /// 100 = one core fully busy.
    public var cpuPercent: Double
    /// Average power drawn by the process, in milliwatts; `nil` if the system reports no energy data.
    public var averagePowerMilliwatts: Double?
    public var wakeupsPerSecond: Double
    public var footprintMegabytes: Double
    public var peakFootprintMegabytes: Double
    public var instructionsPerSecond: Double
}

/// Reads real, OS-reported resource usage for a process — no estimates. Works for the current
/// process and for other processes owned by the same user, and needs no special privileges.
public enum ResourceSampler {
    public static func sample(pid: Int32 = getpid()) -> ResourceSample? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard status == 0 else { return nil }
        // CPU times are in mach ticks, not nanoseconds.
        let cpuTicks = info.ri_user_time &+ info.ri_system_time
        return ResourceSample(
            pid: pid,
            takenAt: .now,
            cpuSeconds: HostTime(ticks: cpuTicks).seconds(since: .zero),
            energyJoules: Double(info.ri_energy_nj) / 1e9,
            footprintBytes: info.ri_phys_footprint,
            peakFootprintBytes: info.ri_lifetime_max_phys_footprint,
            interruptWakeups: info.ri_interrupt_wkups,
            packageIdleWakeups: info.ri_pkg_idle_wkups,
            cycles: info.ri_cycles,
            instructions: info.ri_instructions
        )
    }

    public static func usage(from earlier: ResourceSample, to later: ResourceSample) -> ResourceUsage? {
        let interval = later.takenAt.seconds(since: earlier.takenAt)
        guard interval > 0.001, earlier.pid == later.pid else { return nil }
        let energy = later.energyJoules - earlier.energyJoules
        let wakeups = Double((later.interruptWakeups &- earlier.interruptWakeups) &+ (later.packageIdleWakeups &- earlier.packageIdleWakeups))
        return ResourceUsage(
            intervalSeconds: interval,
            cpuPercent: max(0, (later.cpuSeconds - earlier.cpuSeconds) / interval * 100),
            averagePowerMilliwatts: later.energyJoules > 0 ? max(0, energy / interval * 1000) : nil,
            wakeupsPerSecond: wakeups / interval,
            footprintMegabytes: Double(later.footprintBytes) / 1_048_576,
            peakFootprintMegabytes: Double(later.peakFootprintBytes) / 1_048_576,
            instructionsPerSecond: Double(later.instructions &- earlier.instructions) / interval
        )
    }
}

/// Convenience for the diagnostics window: remembers the previous sample and reports the rates
/// since then each time it is asked.
public final class ResourceMeter: @unchecked Sendable {
    private let pid: Int32
    private let last: Protected<ResourceSample?>

    public init(pid: Int32 = getpid()) {
        self.pid = pid
        self.last = Protected(ResourceSampler.sample(pid: pid))
    }

    /// Usage since the previous call (or since creation); `nil` if the process cannot be read.
    public func measure() -> ResourceUsage? {
        guard let current = ResourceSampler.sample(pid: pid) else { return nil }
        let previous = last.withLock { state -> ResourceSample? in
            let previous = state
            state = current
            return previous
        }
        guard let previous else { return nil }
        return ResourceSampler.usage(from: previous, to: current)
    }
}
