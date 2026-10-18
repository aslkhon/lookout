import CryptoKit
import Foundation
import LookoutCore

/// ssh hosts Lookout watches. Each gets a long-lived `ssh <host> ~/.lookout/bin/lookout-hook --watch`
/// whose JSON lines feed AppModel, restarted with backoff when it drops.
@MainActor
final class RemoteHosts: ObservableObject {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var hosts: [String]
    @Published private(set) var states: [String: State] = [:]
    /// What each host's helper reported when it last connected.
    @Published private(set) var hellos: [String: RemoteHello] = [:]

    private var connections: [String: Connection] = [:]
    /// Hosts whose outdated helper was already reinstalled this launch (to never loop on failure).
    private var updated: Set<String> = []
    private let defaultsKey = "remoteHosts"
    var onMessage: ((String, RemoteMessage) -> Void)?

    init() {
        hosts = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    func start() {
        hosts.forEach(connect)
    }

    func add(_ host: String) {
        guard !hosts.contains(host) else { return connect(host) }
        hosts.append(host)
        UserDefaults.standard.set(hosts, forKey: defaultsKey)
        connect(host)
    }

    func remove(_ host: String) {
        connections.removeValue(forKey: host)?.stop()
        states[host] = nil
        hosts.removeAll { $0 == host }
        UserDefaults.standard.set(hosts, forKey: defaultsKey)
    }

    /// (Re)connects now, e.g. after installing the helper on the host.
    func connect(_ host: String) {
        connections.removeValue(forKey: host)?.stop()
        let connection = Connection(host: host) { [weak self] event in
            Task { @MainActor in self?.handle(host: host, event) }
        }
        connections[host] = connection
        states[host] = .connecting
        connection.start()
    }

    private func handle(host: String, _ event: Connection.Event) {
        switch event {
        case .message(let message):
            if case .hello(let hello) = message {
                states[host] = .connected
                hellos[host] = hello
                updateIfOutdated(host, remoteSHA256: hello.sha256)
            }
            onMessage?(host, message)
        case .exited(let error):
            guard let connection = connections[host], !connection.stopped else { return }
            states[host] = .failed(error)
            let delay = connection.nextBackoff()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak connection] in
                guard let connection, !connection.stopped else { return }
                self?.states[host] = .connecting
                connection.start()
            }
        }
    }

    /// After Lookout itself updates, servers still run the old helper: reinstall it, as Setup's
    /// Reinstall does, and reconnect.
    private func updateIfOutdated(_ host: String, remoteSHA256: String?) {
        guard let bundled = Self.bundledHelperSHA256, remoteSHA256 != bundled,
              !updated.contains(host) else { return }
        updated.insert(host)
        Task {
            do {
                _ = try await RemoteSetup.install(host: host)
                if hosts.contains(host) { connect(host) }
            } catch {
                NSLog("Lookout: couldn't update the helper on \(host): \(error.localizedDescription)")
            }
        }
    }

    static let bundledHelperSHA256: String? = {
        guard let url = Bundle.main.url(forResource: "remote-lookout-hook", withExtension: nil),
              let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }()

    // MARK: ssh

    /// Arguments for a non-interactive ssh to `host` that fails instead of prompting.
    nonisolated static func sshArguments(_ host: String, command: String) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
         "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=accept-new", host, command]
    }

    /// Runs `command` on `host`, feeding `input` on stdin; returns stdout or throws with ssh's stderr.
    nonisolated static func run(_ host: String, _ command: String, input: Data? = nil) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArguments(host, command: command)
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            if let input { stdin.fileHandleForWriting.write(input) }
            try? stdin.fileHandleForWriting.close()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SetupError(lastLine(err) ?? "ssh exited with status \(process.terminationStatus)")
            }
            return String(decoding: out, as: UTF8.self)
        }.value
    }

    /// A permission hook on `host` polling ~/.lookout/decisions/<id> for the answer.
    struct Approval: PendingApproval {
        let host: String
        let id: String

        init?(host: String, id: String?) {
            guard let id, PermissionDecision.isValidRequestID(id) else { return nil }
            self.host = host
            self.id = id
        }

        func answer(_ decision: PermissionDecision?) {
            // Moved into place whole, so the hook never reads half an answer.
            let dir = "~/.lookout/decisions"
            let command = "mkdir -p \(dir) && printf %s \(decision?.rawValue ?? "none") > \(dir)/\(id).tmp && mv \(dir)/\(id).tmp \(dir)/\(id)"
            Task { _ = try? await RemoteHosts.run(host, command) }
        }
    }

    nonisolated static func lastLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
    }

    /// One ssh process streaming `--watch` output.
    final class Connection: @unchecked Sendable {
        enum Event {
            case message(RemoteMessage)
            case exited(String)
        }

        let host: String
        private let onEvent: (Event) -> Void
        private var process: Process?
        private var buffer = Data()
        private var failures = 0
        private(set) var stopped = false

        init(host: String, onEvent: @escaping (Event) -> Void) {
            self.host = host
            self.onEvent = onEvent
        }

        func start() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = RemoteHosts.sshArguments(host, command: "~/.lookout/bin/lookout-hook --watch")
            let stdout = Pipe(), stderr = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            buffer = Data()
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self, !chunk.isEmpty else { handle.readabilityHandler = nil; return }
                self.consume(chunk)
            }
            process.terminationHandler = { [weak self] p in
                guard let self else { return }
                let err = RemoteHosts.lastLine(stderr.fileHandleForReading.readDataToEndOfFile())
                let message: String
                if p.terminationStatus == 127 || err?.contains("lookout-hook: not found") == true
                    || err?.contains("No such file") == true {
                    message = "Lookout isn't installed on this host"
                } else {
                    message = err ?? "Disconnected (status \(p.terminationStatus))"
                }
                self.onEvent(.exited(message))
            }
            do {
                try process.run()
                self.process = process
            } catch {
                onEvent(.exited(error.localizedDescription))
            }
        }

        func stop() {
            stopped = true
            process?.terminationHandler = nil
            process?.terminate()
        }

        /// 5s, 10s, 20s … capped at 2 minutes; reset once a connection delivers data.
        func nextBackoff() -> TimeInterval {
            failures += 1
            return min(120, 5 * pow(2, Double(failures - 1)))
        }

        private func consume(_ chunk: Data) {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let message = RemoteMessage.parse(Data(line), host: host) {
                    failures = 0
                    onEvent(.message(message))
                }
            }
        }
    }
}
