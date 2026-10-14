import Foundation

public enum CodexTrustError: LocalizedError {
    case codexNotFound
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotFound: "Couldn't find the `codex` command."
        case .protocolError(let msg): "Codex app-server error: \(msg)"
        }
    }
}

/// Marks Lookout's hooks as trusted in Codex by talking to `codex app-server`
/// (`hooks/list` + `config/batchWrite`), so Codex itself writes `[hooks.state]` in config.toml.
public enum CodexTrust {
    /// The user's login-shell PATH. GUI apps get a minimal PATH, and the npm `codex`
    /// launcher is a `#!/usr/bin/env node` script that needs `node` on PATH.
    public static func shellPath() -> String {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Markers guard against shell startup files that print to stdout.
        guard let out = try? run(shell, ["-lc", "printf '__PATH__%s__END__' \"$PATH\""]),
              let start = out.range(of: "__PATH__"), let end = out.range(of: "__END__", range: start.upperBound..<out.endIndex)
        else { return fallback }
        let path = String(out[start.upperBound..<end.lowerBound])
        return path.isEmpty ? fallback : path
    }

    /// Locates `codex` on the login-shell PATH.
    public static func findCodex(path: String = shellPath()) -> String? {
        let dirs = path.split(separator: ":").map(String.init)
            + [LookoutPaths.home.appendingPathComponent(".local/bin").path]
        return dirs.map { ($0 as NSString).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Trusts every untrusted hook in `hooksFile` whose command contains `lookout-hook`.
    /// Returns how many hooks were newly trusted.
    @discardableResult
    public static func trustLookoutHooks(hooksFile: String, codexPath: String, path: String = shellPath()) throws -> Int {
        let rpc = try AppServer(codexPath: codexPath, path: path)
        defer { rpc.close() }
        _ = try rpc.call("initialize", ["clientInfo": ["name": "lookout", "version": "1.0"]])
        try rpc.notify("initialized")

        let list = try rpc.call("hooks/list", ["cwds": [LookoutPaths.home.path]])
        let entries = ((list["data"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]) ?? []
        var state: [String: Any] = [:]
        for hook in entries {
            guard hook["sourcePath"] as? String == hooksFile,
                  (hook["command"] as? String)?.contains(HookInstaller.marker) == true,
                  hook["trustStatus"] as? String != "trusted",
                  let key = hook["key"] as? String, let hash = hook["currentHash"] as? String else { continue }
            state[key] = ["trusted_hash": hash]
        }
        guard !state.isEmpty else { return 0 }
        _ = try rpc.call("config/batchWrite", [
            "edits": [["keyPath": "hooks.state", "mergeStrategy": "upsert", "value": state]],
        ])
        return state.count
    }

    /// Minimal line-delimited JSON-RPC client over a `codex app-server` child process.
    private final class AppServer {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        var buffer = Data()
        var nextID = 1

        init(codexPath: String, path: String) throws {
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = ["app-server"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            process.environment = env
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
        }

        func notify(_ method: String) throws {
            try send(["jsonrpc": "2.0", "method": method])
        }

        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            let id = nextID
            nextID += 1
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            while true {
                let msg = try readMessage()
                guard msg["id"] as? Int == id else { continue } // skip notifications
                if let error = msg["error"] as? [String: Any] {
                    throw CodexTrustError.protocolError(error["message"] as? String ?? "\(error)")
                }
                return msg["result"] as? [String: Any] ?? [:]
            }
        }

        func close() {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        private func send(_ obj: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: obj)
            data.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: data)
        }

        private func readMessage() throws -> [String: Any] {
            while true {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return obj }
                    continue
                }
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty {
                    let err = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw CodexTrustError.protocolError(err.isEmpty ? "app-server exited unexpectedly" : String(err.prefix(300)))
                }
                buffer.append(chunk)
            }
        }
    }

    private static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
