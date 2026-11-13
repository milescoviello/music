import CCurl
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A file downloaded by libcurl itself, for the songs the stream cache fetches ahead.
///
/// Foundation's `URLSession` on Linux is libcurl underneath, but it hands every few
/// kilobytes of a download to Swift, which resets a timer, seeks to the end of the file
/// and writes the piece: on the 2009 MacBook that was nearly a whole core for as long as a
/// song was being fetched, while the decoding and playing of it took under a tenth. Here
/// libcurl writes straight into the file in half-megabyte reads, on a thread of its own.
///
/// It answers as `URLSession.download(from:)` does, a temporary file and the response,
/// with its failures as the `URLError`s `FetchRetry` already knows. The temporary file is
/// made in `directory`, so moving it into place is a rename rather than a copy.
enum CurlDownload {
    static let ensureInitialised: Void = { curl_global_init(Int(CURL_GLOBAL_DEFAULT)) }()

    /// For the progress callback, which is how a transfer learns it was cancelled.
    private final class Transfer: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        let file: Int32

        init(file: Int32) {
            self.file = file
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    static func download(from url: URL, in directory: URL, stallTimeout: Int = 30) async throws -> (URL, URLResponse) {
        _ = ensureInitialised
        let temporary = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        let file = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard file >= 0 else { throw URLError(.cannotCreateFile) }
        let transfer = Transfer(file: file)

        do {
            let (status, type) = try await withTaskCancellationHandler {
                try await onOwnThread { try perform(url, into: transfer, stallTimeout: stallTimeout) }
            } onCancel: {
                transfer.cancel()
            }
            close(file)
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: type.isEmpty ? [:] : ["Content-Type": type]
            ) ?? URLResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
            return (temporary, response)
        } catch {
            close(file)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Blocking: the whole transfer. The status code and Content-Type, or the failure.
    private static func perform(_ url: URL, into transfer: Transfer, stallTimeout: Int) throws -> (Int, String) {
        guard let curl = curl_easy_init() else { throw URLError(.unknown) }
        defer { curl_easy_cleanup(curl) }
        let context = Unmanaged.passUnretained(transfer).toOpaque()

        _ = ccurl_setopt_string(curl, CURLOPT_URL, url.absoluteString)
        _ = ccurl_setopt_long(curl, CURLOPT_FOLLOWLOCATION, 1)
        _ = ccurl_setopt_long(curl, CURLOPT_NOSIGNAL, 1)
        _ = ccurl_setopt_long(curl, CURLOPT_CONNECTTIMEOUT, 15)
        // As URLSession's timeoutIntervalForRequest: given up after this long with nothing.
        _ = ccurl_setopt_long(curl, CURLOPT_LOW_SPEED_LIMIT, 1)
        _ = ccurl_setopt_long(curl, CURLOPT_LOW_SPEED_TIME, stallTimeout)
        _ = ccurl_setopt_long(curl, CURLOPT_BUFFERSIZE, 512 * 1024)
        _ = ccurl_setopt_pointer(curl, CURLOPT_WRITEDATA, context)
        _ = ccurl_setopt_write_function(curl) { data, size, count, context in
            guard let data, let context else { return 0 }
            let transfer = Unmanaged<Transfer>.fromOpaque(context).takeUnretainedValue()
            let total = size * count
            var written = 0
            while written < total {
                let result = write(transfer.file, data + written, total - written)
                guard result > 0 else { return 0 }
                written += result
            }
            return total
        }
        _ = ccurl_setopt_long(curl, CURLOPT_NOPROGRESS, 0)
        _ = ccurl_setopt_pointer(curl, CURLOPT_XFERINFODATA, context)
        _ = ccurl_setopt_progress_function(curl) { context, _, _, _, _ in
            guard let context else { return 0 }
            return Unmanaged<Transfer>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
        }

        let code = curl_easy_perform(curl)
        guard code == CURLE_OK else {
            if transfer.isCancelled { throw CancellationError() }
            throw URLError(error(for: code))
        }
        var status = 0
        _ = ccurl_getinfo_long(curl, CURLINFO_RESPONSE_CODE, &status)
        var type: UnsafeMutablePointer<CChar>?
        _ = ccurl_getinfo_string(curl, CURLINFO_CONTENT_TYPE, &type)
        return (status, type.map { String(cString: $0) } ?? "")
    }

    /// A blocking transfer on a thread of its own. Not on Swift's own threads, of which
    /// there are as many as cores: on two, a launch's thirty requests went two at a time,
    /// each about fourteen seconds late, and everything else waited behind them.
    static func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }.start()
        }
    }

    static func error(for code: CURLcode) -> URLError.Code {
        switch code {
        case CURLE_OPERATION_TIMEDOUT: return .timedOut
        case CURLE_COULDNT_CONNECT: return .cannotConnectToHost
        case CURLE_COULDNT_RESOLVE_HOST: return .cannotFindHost
        case CURLE_RECV_ERROR, CURLE_SEND_ERROR, CURLE_PARTIAL_FILE, CURLE_GOT_NOTHING: return .networkConnectionLost
        case CURLE_SSL_CONNECT_ERROR: return .secureConnectionFailed
        case CURLE_WRITE_ERROR: return .cannotWriteToFile
        default: return .unknown
        }
    }
}

/// A request answered into memory by libcurl: what `URLSession.fetch` is on the desktop.
///
/// Handles are kept and reused, as libcurl keeps each one's connections open, so a
/// launch's dozens of requests to the same server share a few connections, as they did
/// under URLSession. Compressed answers are asked for and inflated, as URLSession does.
enum CurlFetch {
    private static let pool = HandlePool()

    private final class HandlePool: @unchecked Sendable {
        private let lock = NSLock()
        private var idle: [OpaquePointer] = []

        func take() -> OpaquePointer? {
            lock.lock()
            let handle = idle.popLast()
            lock.unlock()
            if let handle {
                curl_easy_reset(UnsafeMutableRawPointer(handle))
                return handle
            }
            return curl_easy_init().map { OpaquePointer($0) }
        }

        func give(_ handle: OpaquePointer) {
            lock.lock()
            defer { lock.unlock() }
            if idle.count < 8 { idle.append(handle) } else { curl_easy_cleanup(UnsafeMutableRawPointer(handle)) }
        }
    }

    /// The answer as it arrives, and whether the task asking for it was cancelled.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var body = Data()
        var headers: [String: String] = [:]

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    static func data(for request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let answer = Answer()
        let (status, finalURL) = try await withTaskCancellationHandler {
            try await CurlDownload.onOwnThread { try perform(request, url: url, into: answer, timeout: timeout) }
        } onCancel: {
            answer.cancel()
        }
        let response = HTTPURLResponse(url: finalURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: answer.headers)
            ?? URLResponse(url: finalURL, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
        return (answer.body, response)
    }

    private static func perform(_ request: URLRequest, url: URL, into answer: Answer, timeout: TimeInterval) throws -> (Int, URL) {
        _ = CurlDownload.ensureInitialised
        guard let handle = pool.take() else { throw URLError(.unknown) }
        let curl = UnsafeMutableRawPointer(handle)
        let context = Unmanaged.passUnretained(answer).toOpaque()
        var headers: UnsafeMutablePointer<curl_slist>?
        defer {
            curl_slist_free_all(headers)
            pool.give(handle)
        }

        let seconds = max(1, Int(timeout.rounded(.up)))
        _ = ccurl_setopt_string(curl, CURLOPT_URL, url.absoluteString)
        _ = ccurl_setopt_long(curl, CURLOPT_FOLLOWLOCATION, 1)
        _ = ccurl_setopt_long(curl, CURLOPT_NOSIGNAL, 1)
        _ = ccurl_setopt_long(curl, CURLOPT_CONNECTTIMEOUT, min(seconds, 15))
        // URLSession's timeoutIntervalForRequest is the longest wait for the next bytes.
        _ = ccurl_setopt_long(curl, CURLOPT_LOW_SPEED_LIMIT, 1)
        _ = ccurl_setopt_long(curl, CURLOPT_LOW_SPEED_TIME, seconds)
        _ = ccurl_setopt_string(curl, CURLOPT_ACCEPT_ENCODING, "")

        // No "Expect: 100-continue": curl waits a second for it on any larger body.
        headers = curl_slist_append(headers, "Expect:")
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers = curl_slist_append(headers, "\(name): \(value)")
        }
        _ = ccurl_setopt_pointer(curl, CURLOPT_HTTPHEADER, UnsafeMutableRawPointer(headers))

        _ = ccurl_setopt_pointer(curl, CURLOPT_WRITEDATA, context)
        _ = ccurl_setopt_write_function(curl) { data, size, count, context in
            guard let data, let context else { return 0 }
            let answer = Unmanaged<Answer>.fromOpaque(context).takeUnretainedValue()
            let total = size * count
            data.withMemoryRebound(to: UInt8.self, capacity: total) {
                answer.body.append($0, count: total)
            }
            return total
        }
        _ = ccurl_setopt_pointer(curl, CURLOPT_HEADERDATA, context)
        _ = ccurl_setopt_header_function(curl) { data, size, count, context in
            guard let data, let context else { return 0 }
            let answer = Unmanaged<Answer>.fromOpaque(context).takeUnretainedValue()
            let total = size * count
            let line = String(decoding: UnsafeRawBufferPointer(start: data, count: total), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("HTTP/") {
                // A redirect's headers give way to the next answer's.
                answer.headers = [:]
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                answer.headers[name] = value
            }
            return total
        }
        _ = ccurl_setopt_long(curl, CURLOPT_NOPROGRESS, 0)
        _ = ccurl_setopt_pointer(curl, CURLOPT_XFERINFODATA, context)
        _ = ccurl_setopt_progress_function(curl) { context, _, _, _, _ in
            guard let context else { return 0 }
            return Unmanaged<Answer>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
        }

        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? Data()
        let code: CURLcode = body.withUnsafeBytes { bytes in
            switch method {
            case "GET":
                break
            case "POST":
                _ = ccurl_setopt_long(curl, CURLOPT_POST, 1)
            default:
                _ = ccurl_setopt_string(curl, CURLOPT_CUSTOMREQUEST, method)
            }
            if method != "GET" {
                _ = ccurl_setopt_off(curl, CURLOPT_POSTFIELDSIZE_LARGE, curl_off_t(body.count))
                _ = ccurl_setopt_pointer(curl, CURLOPT_POSTFIELDS, UnsafeMutableRawPointer(mutating: bytes.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!))
            }
            return curl_easy_perform(curl)
        }
        guard code == CURLE_OK else {
            if answer.isCancelled { throw CancellationError() }
            throw URLError(CurlDownload.error(for: code))
        }
        var status = 0
        _ = ccurl_getinfo_long(curl, CURLINFO_RESPONSE_CODE, &status)
        var effective: UnsafeMutablePointer<CChar>?
        _ = ccurl_getinfo_string(curl, CURLINFO_EFFECTIVE_URL, &effective)
        return (status, effective.flatMap { URL(string: String(cString: $0)) } ?? url)
    }
}
