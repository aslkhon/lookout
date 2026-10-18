// lookout-hook: invoked by Claude Code / Codex hooks as `lookout-hook <claude|codex>`.
// Reads the hook payload from stdin, adds process/terminal context, and forwards it to
// Lookout.app over a Unix socket. It must never print to stdout (Claude treats stdout as
// hook output), never block the agent, and always exit 0. The one exception: on a Claude
// PermissionRequest it waits for Allow or Deny from Lookout and prints that decision. Claude's
// own dialog stays usable meanwhile, and Lookout closes the connection once it's answered there.
// Claude's questions (AskUserQuestion) come as permission requests too; Lookout can answer those.

import Darwin
import Foundation
import LookoutCore

signal(SIGPIPE, SIG_IGN)

let source = CommandLine.arguments.dropFirst().first ?? "claude"
guard AgentSource(rawValue: source) != nil else { exit(0) }

// Read the payload; drop bulky fields the app doesn't need.
let input = FileHandle.standardInput.readDataToEndOfFile()
guard var payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
let fullToolInput = payload["tool_input"] as? [String: Any] ?? [:] // an answer goes back with all of it
payload.removeValue(forKey: "tool_response")
if var toolInput = payload["tool_input"] as? [String: Any] {
    for (key, value) in toolInput {
        if let s = value as? String, s.count > 300 { toolInput[key] = String(s.prefix(300)) }
        else if !(value is String || value is NSNumber) && key != "questions" { toolInput.removeValue(forKey: key) }
    }
    payload["tool_input"] = toolInput
}

// MARK: Process ancestry

struct ProcInfo { let ppid: pid_t; let comm: String; let tdev: dev_t }

func procInfo(_ pid: pid_t) -> ProcInfo? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return ProcInfo(ppid: info.kp_eproc.e_ppid, comm: comm, tdev: info.kp_eproc.e_tdev)
}

func executablePath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
    return String(cString: buf)
}

/// Whether `pid` is the agent binary. Native Claude installs run from `…/claude/versions/<version>`,
/// so their process name is the version number; match on the executable path too.
func isAgent(_ pid: pid_t, _ info: ProcInfo) -> Bool {
    if info.comm == source { return true }
    let path = executablePath(pid)
    return (path as NSString).lastPathComponent == source || path.contains("/\(source)/versions/")
}

/// Walks up from our parent to the agent process (`claude`/`codex`, or `node` for npm installs).
func findAgent() -> (pid: pid_t, info: ProcInfo)? {
    var pid = getppid()
    var fallback: (pid_t, ProcInfo)?
    for _ in 0..<12 {
        guard pid > 1, let info = procInfo(pid) else { break }
        if isAgent(pid, info) { return (pid, info) }
        if fallback == nil, info.comm == "node" { fallback = (pid, info) }
        pid = info.ppid
    }
    return fallback
}

let agent = findAgent()
var tty: String?
if let dev = agent?.info.tdev, dev != -1 /* NODEV */, let name = devname(dev, S_IFCHR) {
    tty = "/dev/" + String(cString: name)
}

let env = ProcessInfo.processInfo.environment
var context: [String: Any] = ["timestamp": Date().timeIntervalSince1970]
context["agentPID"] = agent.map { Int($0.pid) }
context["tty"] = tty
context["termProgram"] = env["TERM_PROGRAM"]
context["hostBundleID"] = env["__CFBundleIdentifier"]
let awaitsDecision = source == "claude" && payload["hook_event_name"] as? String == "PermissionRequest"
if awaitsDecision { context["awaitsDecision"] = true }

let envelope: [String: Any] = ["source": source, "context": context, "payload": payload]
guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { exit(0) }

// MARK: Send

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var timeout = timeval(tv_sec: 1, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
var noSigPipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let path = LookoutPaths.socket.path
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    let bytes = Array(path.utf8.prefix(buf.count - 1))
    buf.copyBytes(from: bytes)
    buf[bytes.count] = 0
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
if connected == 0 {
    body.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { break }
            offset += n
        }
    }
    if awaitsDecision {
        shutdown(fd, SHUT_WR) // sent: Lookout replies on this connection, or closes it without a decision
        var wait = timeval(tv_sec: 590, tv_usec: 0) // under Claude's 600 s hook timeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while reply.count < 1 << 20 { // until Lookout closes the connection
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(buf, count: n)
        }
        if let decision = PermissionDecision(wire: String(decoding: reply, as: UTF8.self)) {
            FileHandle.standardOutput.write(decision.hookOutput(toolInput: fullToolInput))
        }
    }
}
close(fd)
exit(0)
