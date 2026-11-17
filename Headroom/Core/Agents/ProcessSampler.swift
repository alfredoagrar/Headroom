import Darwin
import Foundation

/// Minimal process-table entry from `PROC_PIDTBSDINFO`.
struct ProcessEntry: Sendable, Hashable {
    let pid: Int32
    let ppid: Int32
    let uid: uid_t
    let startTime: Date
    /// Executable name truncated to 16 characters by the kernel.
    let command: String
}

/// Thin wrappers over libproc. Never reads argv or environment of other processes.
enum LibProc {
    static func allProcesses() -> [ProcessEntry] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap(entry(pid:))
    }

    static func entry(pid: Int32) -> ProcessEntry? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        return ProcessEntry(pid: pid, ppid: Int32(info.pbi_ppid), uid: info.pbi_uid, startTime: start,
                            command: cString(info.pbi_comm))
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// Paths of regular files the process has open.
    static func openFilePaths(pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 8)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        return fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            let path = cString(info.pvip.vip_path)
            return path.isEmpty ? nil : path
        }
    }

    /// CPU time (ns) and memory footprint (bytes, what Activity Monitor shows).
    static func resourceUsage(pid: Int32) -> (cpuNanos: UInt64, footprint: UInt64)? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // rusage times are mach absolute time units (not ns on Apple silicon).
        let ticks = usage.ri_user_time + usage.ri_system_time
        return (ticks * timebase.numer / timebase.denom, usage.ri_phys_footprint)
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Decodes a fixed-size C `char[]` tuple up to its first NUL.
    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let end = raw.firstIndex(of: 0) ?? raw.count
            return String(decoding: raw[..<end], as: UTF8.self)
        }
    }
}

/// Pure helpers over a process table, unit-tested with synthetic data.
enum ProcessTree {
    static func children(_ entries: [ProcessEntry]) -> [Int32: [Int32]] {
        var map: [Int32: [Int32]] = [:]
        for entry in entries where entry.pid != entry.ppid {
            map[entry.ppid, default: []].append(entry.pid)
        }
        return map
    }

    /// Descendants of `root`, not descending into `excluded` pids (nested agents) and safe against cycles.
    static func descendants(of root: Int32, children: [Int32: [Int32]], excluding excluded: Set<Int32> = []) -> [Int32] {
        var result: [Int32] = []
        var seen: Set<Int32> = [root]
        var stack = children[root] ?? []
        while let pid = stack.popLast() {
            guard !excluded.contains(pid), seen.insert(pid).inserted else { continue }
            result.append(pid)
            stack.append(contentsOf: children[pid] ?? [])
        }
        return result
    }

    /// Whether any ancestor of `pid` is in `candidates`.
    static func hasAncestor(_ pid: Int32, in candidates: Set<Int32>, parents: [Int32: Int32]) -> Bool {
        var current = parents[pid]
        var hops = 0
        while let parent = current, parent > 1, hops < 128 {
            if candidates.contains(parent) { return true }
            current = parents[parent]
            hops += 1
        }
        return false
    }

    static func cpuPercent(previousNanos: UInt64, currentNanos: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, currentNanos >= previousNanos else { return 0 }
        return Double(currentNanos - previousNanos) / (elapsed * 1_000_000_000) * 100
    }
}
