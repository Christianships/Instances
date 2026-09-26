import AppKit
import Darwin
import IOKit

/// One process as seen by the kernel, with CPU and memory from the latest sample.
struct Proc: Identifiable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String
    let path: String
    /// Physical footprint in bytes -- the "Memory" column in Activity Monitor.
    let memory: UInt64
    /// Percent of one core since the previous sample (can exceed 100).
    let cpu: Double
    /// Percent of GPU time since the previous sample.
    let gpu: Double
    /// False for processes we may not inspect (other users' without root).
    let hasStats: Bool
    var id: pid_t { pid }
}

/// Walks every pid via libproc. CPU usage needs two readings, so the sampler
/// keeps the previous cumulative CPU time per pid and diffs against it.
final class Sampler {
    private var lastTimes: [pid_t: UInt64] = [:]
    private var lastGPU: [pid_t: UInt64] = [:]
    private var lastStamp: UInt64 = 0
    private let numer: UInt64
    private let denom: UInt64

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer)
        denom = UInt64(tb.denom)
    }

    /// rusage CPU times are in Mach ticks on Apple Silicon, not nanoseconds.
    private func nanos(_ ticks: UInt64) -> UInt64 { ticks * numer / denom }

    func sample() -> [Proc] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard n > 0 else { return [] }

        let now = mach_absolute_time()
        let wall = lastStamp == 0 ? 0 : nanos(now - lastStamp)
        var times: [pid_t: UInt64] = [:]
        let gpuTimes = gpuTimesByPid()
        var out: [Proc] = []
        out.reserveCapacity(Int(n))

        var pathBuf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let haveBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize

            let path = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 ? String(cString: pathBuf) : ""
            var name = path.isEmpty ? "" : (path as NSString).lastPathComponent
            if name.isEmpty, haveBSD {
                name = withUnsafePointer(to: bsd.pbi_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                }
            }
            if name.isEmpty {
                var buf = [CChar](repeating: 0, count: 256)
                proc_name(pid, &buf, UInt32(buf.count))
                name = String(cString: buf)
            }
            if name.isEmpty { name = "pid \(pid)" }

            var ru = rusage_info_v4()
            let haveRU = withUnsafeMutablePointer(to: &ru) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            } == 0

            var cpu = 0.0
            if haveRU {
                let t = nanos(ru.ri_user_time + ru.ri_system_time)
                times[pid] = t
                if wall > 0, let prev = lastTimes[pid], t >= prev {
                    cpu = Double(t - prev) / Double(wall) * 100
                }
            }

            var gpu = 0.0
            if wall > 0, let t = gpuTimes[pid], let prev = lastGPU[pid], t >= prev {
                gpu = min(Double(t - prev) / Double(wall) * 100, 100)
            }

            out.append(Proc(
                pid: pid,
                ppid: haveBSD ? pid_t(bsd.pbi_ppid) : 0,
                uid: haveBSD ? bsd.pbi_uid : 0,
                name: name,
                path: path,
                memory: haveRU ? ru.ri_phys_footprint : 0,
                cpu: cpu,
                gpu: gpu,
                hasStats: haveRU
            ))
        }

        lastTimes = times
        lastGPU = gpuTimes
        lastStamp = now
        return out
    }
}

/// Visible, normal-layer windows per owning pid. Window titles need Screen
/// Recording permission, but owner pids and bounds do not.
func windowCounts() -> [pid_t: Int] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [:] }
    var counts: [pid_t: Int] = [:]
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              (b["Width"] ?? 0) >= 60, (b["Height"] ?? 0) >= 60
        else { continue }
        counts[pid, default: 0] += 1
    }
    return counts
}

/// Cumulative GPU time in nanoseconds per pid. Every process that talks to
/// the GPU owns a user client under the IOAccelerator service, which records
/// its creator ("pid 123, name") and per-queue accumulatedGPUTime. Readable
/// without root, unlike powermetrics.
func gpuTimesByPid() -> [pid_t: UInt64] {
    var out: [pid_t: UInt64] = [:]
    var services: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &services)
            == KERN_SUCCESS else { return out }
    defer { IOObjectRelease(services) }

    var service = IOIteratorNext(services)
    while service != 0 {
        var children: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS {
            var child = IOIteratorNext(children)
            while child != 0 {
                if let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString,
                                                                 kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                   creator.hasPrefix("pid "),
                   let pid = pid_t(creator.dropFirst(4).prefix { $0.isNumber }),
                   let usage = IORegistryEntryCreateCFProperty(child, "AppUsage" as CFString,
                                                               kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]] {
                    for u in usage {
                        if let t = (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value {
                            out[pid, default: 0] += t
                        }
                    }
                }
                IOObjectRelease(child)
                child = IOIteratorNext(children)
            }
            IOObjectRelease(children)
        }
        IOObjectRelease(service)
        service = IOIteratorNext(services)
    }
    return out
}
