import Darwin
import Foundation

/// Unix-domain socket server. Each `lookout-hook` connection sends one JSON envelope and closes.
final class EventServer: @unchecked Sendable {
    private let path: String
    private let onMessage: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "lookout.event-server")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, onMessage: @escaping @Sendable (Data) -> Void) {
        self.path = path
        self.onMessage = onMessage
    }

    func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 64) == 0 else {
            let err = errno
            close(listenFD)
            throw POSIXError(.init(rawValue: err) ?? .EIO)
        }
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        self.source = source
    }

    private func acceptConnection() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < 4 * 1024 * 1024 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        if !data.isEmpty { onMessage(data) }
    }
}
