import Darwin
import Foundation

/// Thin wrappers over sysctl/libproc for inspecting other processes.
public enum ProcessInspector {
    public struct Info {
        public let pid: pid_t
        public let ppid: pid_t
        /// Kernel process name (≤16 chars). Native Claude installs report their version number here.
        public let comm: String
        let tdev: dev_t
    }

    public static func info(_ pid: pid_t) -> Info? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
        let comm = withUnsafeBytes(of: kinfo.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return Info(pid: pid, ppid: kinfo.kp_eproc.e_ppid, comm: comm, tdev: kinfo.kp_eproc.e_tdev)
    }

    public static func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    public static func cwd(_ pid: pid_t) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else { return nil }
        let path = withUnsafeBytes(of: vpi.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// Controlling terminal, e.g. "/dev/ttys011", or nil for background processes.
    public static func tty(_ info: Info) -> String? {
        guard info.tdev != -1, let name = devname(info.tdev, S_IFCHR) else { return nil }
        let s = String(cString: name)
        return s == "??" ? nil : "/dev/" + s
    }

    public static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(n, 0)))).filter { $0 > 0 }
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Bundle identifier of the GUI app hosting `pid`: the first ancestor whose executable lives
    /// inside an `.app` bundle (outermost bundle, so VS Code's "Code Helper" resolves to VS Code).
    public static func hostBundleID(of pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<16 {
            guard current > 1, let info = info(current) else { return nil }
            let path = executablePath(current)
            if let range = path.range(of: ".app/") {
                return Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
            }
            current = info.ppid
        }
        return nil
    }
}
