import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The smallest HTTP/1.1 server the remote needs: one request per connection, answered
/// and closed, except an event stream, which stays open for writing.
///
/// Plain sockets and a thread per connection. There are a phone or two on the other end,
/// not thousands, and blocking reads on threads of their own keep the parsing in order
/// and off the main loop; only the request, parsed, goes to the main actor, which answers
/// it before the thread goes on. Writes go through a queue per connection, so a phone
/// that stops reading stalls nobody else.
///
/// IPv4 only, which is what the phone resolves and what a person types; and only peers on
/// the LAN, which is all the remote is for.
final class HTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Names lowercased.
        var headers: [String: String]
        var body: Data
        var peer: String
    }

    typealias Handler = @MainActor @Sendable (Request, HTTPConnection) -> Void

    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private(set) var port: UInt16 = 0

    /// Large enough for a phone sending a whole smart playlist to play.
    static let maximumBody = 64 << 20

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Listens on `preferred`, or on any free port if it is taken. False if neither works.
    func start(port preferred: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0 else { return true }
        for candidate in [preferred, 0] {
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
            guard fd >= 0 else { return false }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = candidate.bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 16) == 0 else {
                close(fd)
                continue
            }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            listener = fd
            port = UInt16(bigEndian: actual.sin_port)
            let thread = Thread { [self] in acceptLoop(fd) }
            thread.name = "remote-accept"
            thread.start()
            return true
        }
        return false
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard listener >= 0 else { return }
        // Shutting the socket down is what wakes a thread blocked in `accept`; closing it
        // alone does not, on Linux.
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
        listener = -1
        port = 0
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &length)
                }
            }
            if client >= 0 { _ = fcntl(client, F_SETFD, FD_CLOEXEC) }
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            let host = UInt32(bigEndian: address.sin_addr.s_addr)
            guard Self.isLocal(host) else {
                close(client)
                continue
            }
            let connection = HTTPConnection(fd: client, peer: Self.dotted(host))
            let thread = Thread { [self] in serve(connection) }
            thread.name = "remote-connection"
            thread.start()
        }
    }

    private func serve(_ connection: HTTPConnection) {
        guard let request = connection.readRequest() else {
            connection.respond(400)
            return
        }
        // Answered on the main actor while this thread waits, so that whether the
        // connection became an event stream is known here.
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { handler(request, connection) }
        }
        // An event stream stays open until the phone goes. Nothing more is read from it,
        // so this read returns only when the connection ends.
        if connection.isStreaming { connection.waitForClose() }
    }

    // MARK: - Addresses

    /// Loopback, RFC 1918 and link-local.
    static func isLocal(_ host: UInt32) -> Bool {
        let a = host >> 24, b = (host >> 16) & 0xff
        return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 169 && b == 254)
    }

    static func dotted(_ host: UInt32) -> String {
        "\(host >> 24).\((host >> 16) & 0xff).\((host >> 8) & 0xff).\(host & 0xff)"
    }

    /// This computer's addresses on the LAN, for someone adding it to a phone by hand.
    static func localAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let host = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard isLocal(host), host >> 24 != 127 else { continue }
            let dotted = dotted(host)
            if !addresses.contains(dotted) { addresses.append(dotted) }
        }
        return addresses
    }
}

/// One phone's connection.
final class HTTPConnection: @unchecked Sendable {
    let peer: String
    private let fd: Int32
    private let writes = DispatchQueue(label: "remote.connection.write")
    private let lock = NSLock()
    private var closed = false
    private(set) var isStreaming = false
    /// Called once, on whichever thread finds the connection gone.
    var onClose: (@Sendable () -> Void)?

    init(fd: Int32, peer: String) {
        self.fd = fd
        self.peer = peer
        // A request has ten seconds to arrive, so a connection that never sends one does
        // not keep a thread forever.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Data a phone has not acknowledged in 30 seconds means it has gone -- out of Wi-Fi,
        // asleep -- and the connection with it, rather than after TCP's quarter of an hour.
        var unacknowledged: UInt32 = 30_000
        setsockopt(fd, Int32(IPPROTO_TCP), Self.tcpUserTimeout, &unacknowledged, socklen_t(MemoryLayout<UInt32>.size))
    }

    /// `TCP_USER_TIMEOUT`, which Glibc's module does not export.
    private static let tcpUserTimeout: Int32 = 18

    // MARK: - Reading

    fileprivate func readRequest() -> HTTPServer.Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let separator = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            headEnd = buffer.range(of: separator)
            if headEnd == nil, buffer.count > 32_768 { return nil }
        }
        guard let headEnd,
              let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8)
        else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var body = Data(buffer[headEnd.upperBound...])
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= HTTPServer.maximumBody else { return nil }
        while body.count < length {
            let count = recv(fd, &chunk, min(chunk.count, length - body.count), 0)
            guard count > 0 else { return nil }
            body.append(contentsOf: chunk[0..<count])
        }
        let path = requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return HTTPServer.Request(
            method: String(requestLine[0]),
            path: path,
            headers: headers,
            body: body.prefix(length),
            peer: peer
        )
    }

    fileprivate func waitForClose() {
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        while recv(fd, &byte, 1, 0) > 0 {}
        close()
    }

    // MARK: - Writing

    /// Answers and closes.
    func respond(_ status: Int, json: Data? = nil) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nConnection: close\r\nContent-Length: \(json?.count ?? 0)\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        let data = Data(head.utf8) + (json ?? Data())
        writes.async { [self] in
            _ = write(data)
            close()
        }
    }

    /// Begins an event stream: the headers, and then whatever `send` is given.
    func startEvents() {
        isStreaming = true
        send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n")
    }

    func send(_ text: String) {
        let data = Data(text.utf8)
        writes.async { [self] in
            if !write(data) { close() }
        }
    }

    private func write(_ data: Data) -> Bool {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                // MSG_NOSIGNAL: a phone that has gone must be an error here, not a SIGPIPE
                // that ends the app.
                let count = Glibc.send(fd, base + sent, raw.count - sent, Int32(MSG_NOSIGNAL))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let onClose = onClose
        self.onClose = nil
        lock.unlock()
        shutdown(fd, Int32(SHUT_RDWR))
        Glibc.close(fd)
        onClose?()
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 410: return "Gone"
        default: return "Error"
        }
    }
}
