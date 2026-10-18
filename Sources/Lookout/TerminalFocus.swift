import AppKit
import Darwin
import LookoutCore

/// Exact-tab focus in terminals that can find a tab by its tty: iTerm2 and Terminal.app through
/// AppleScript, WezTerm through its CLI, and tmux panes in any of them.
extension Focuser {
    static let itermID = "com.googlecode.iterm2"
    static let terminalID = "com.apple.Terminal"
    static let weztermID = "com.github.wez.wezterm"

    /// Focuses the tab on `tty` in the terminal app `bundleID`; false when the app or tab isn't one it can find.
    static func focusTab(bundleID: String, tty: String) -> Bool {
        switch bundleID {
        case itermID: return focusITerm(tty: tty)
        case terminalID: return focusTerminalApp(tty: tty)
        case weztermID: return focusWezTerm(tty: tty)
        default: return false
        }
    }

    static func focusITerm(tty: String) -> Bool {
        runAppleScript("""
        tell application id "\(itermID)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return ""
        """) == "found"
    }

    static func focusTerminalApp(tty: String) -> Bool {
        runAppleScript("""
        tell application id "\(terminalID)"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "found"
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """) == "found"
    }

    static func focusWezTerm(tty: String) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: weztermID) else { return false }
        let cli = app.appendingPathComponent("Contents/MacOS/wezterm").path
        guard let listing = run(cli, ["cli", "list", "--format", "json"]),
              let panes = try? JSONSerialization.jsonObject(with: Data(listing.utf8)) as? [[String: Any]],
              let pane = panes.first(where: { $0["tty_name"] as? String == tty }),
              let paneID = (pane["pane_id"] as? NSNumber)?.stringValue else { return false }
        if let tabID = (pane["tab_id"] as? NSNumber)?.stringValue { _ = run(cli, ["cli", "activate-tab", "--tab-id", tabID]) }
        _ = run(cli, ["cli", "activate-pane", "--pane-id", paneID])
        activate(bundleID: weztermID)
        return true
    }

    // MARK: tmux

    static var tmuxPath: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Makes the tmux pane on `tty` current, in a client showing its session if there is one,
    /// else in another attached client. Returns that client's tty and pid, or nil.
    static func selectTmuxPane(tty: String) -> (tty: String, pid: pid_t)? {
        guard let tmux = tmuxPath,
              let panes = run(tmux, ["list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{session_name}"]),
              let pane = rows(panes).first(where: { $0.count == 3 && $0[0] == tty }),
              let clients = run(tmux, ["list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{client_session}"]) else { return nil }
        let attached = rows(clients).filter { $0.count == 3 }
        guard let client = attached.first(where: { $0[2] == pane[2] }) ?? attached.first,
              let pid = pid_t(client[1]) else { return nil }
        if client[2] != pane[2] { _ = run(tmux, ["switch-client", "-c", client[0], "-t", pane[1]]) }
        _ = run(tmux, ["select-window", "-t", pane[1]])
        _ = run(tmux, ["select-pane", "-t", pane[1]])
        return (client[0], pid)
    }

    /// The app among `pid`'s ancestors, e.g. the terminal a tmux client runs in.
    static func appBundleID(owning pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<32 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app.bundleIdentifier
            }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            current = info.kp_eproc.e_ppid
        }
        return nil
    }

    // MARK: Helpers

    private static func rows(_ text: String) -> [[String]] {
        text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// Output of a short command, or nil if it fails.
    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
