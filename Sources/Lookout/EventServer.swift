import Darwin
import Foundation

/// Unix-domain socket server. Each `lookout-hook` connection sends one JSON envelope; a hook waiting
/// for a permission decision then keeps the connection open for the reply.
final class EventServer: @unchecked Sendable {
    private let path: String
    private let onMessage: @Sendable (Data, Responder) -> Void
    private let queue = DispatchQueue(label: "lookout.event-server")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, onMessage: @escaping @Sendable (Data, Responder) -> Void) {
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
        let responder = Responder(fd: fd) // closes the connection once dropped
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < 4 * 1024 * 1024 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        if !data.isEmpty { onMessage(data, responder) }
    }
}

/// A hook's connection, to answer it. Dropping it, answered or not, closes the connection; a waiting
/// hook then exits without a decision.
final class Responder: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) { self.fd = fd }

    func reply(_ text: String) {
        lock.withLock {
            guard fd >= 0 else { return }
            _ = text.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
            close(fd)
            fd = -1
        }
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}
