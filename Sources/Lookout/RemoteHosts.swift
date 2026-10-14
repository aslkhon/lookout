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

    private var connections: [String: Connection] = [:]
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
            if case .hello = message { states[host] = .connected }
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
