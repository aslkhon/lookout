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
    /// Locates `codex` via the user's login shell, since GUI apps don't inherit the shell PATH.
    public static func findCodex() -> String? {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          LookoutPaths.home.appendingPathComponent(".local/bin/codex").path]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let out = try? run(shell, ["-lc", "command -v codex"]) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Trusts every untrusted hook in `hooksFile` whose command contains `lookout-hook`.
    /// Returns how many hooks were newly trusted.
    @discardableResult
    public static func trustLookoutHooks(hooksFile: String, codexPath: String) throws -> Int {
        let rpc = try AppServer(codexPath: codexPath)
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
        var buffer = Data()
        var nextID = 1

        init(codexPath: String) throws {
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = ["app-server"]
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
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
                if chunk.isEmpty { throw CodexTrustError.protocolError("app-server exited unexpectedly") }
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
