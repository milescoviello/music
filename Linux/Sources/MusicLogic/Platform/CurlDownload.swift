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
    private static let initialised: Void = { curl_global_init(Int(CURL_GLOBAL_DEFAULT)) }()

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
        _ = initialised
        let temporary = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        let file = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard file >= 0 else { throw URLError(.cannotCreateFile) }
        let transfer = Transfer(file: file)

        do {
            let (status, type) = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try perform(url, into: transfer, stallTimeout: stallTimeout)
                }.value
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

    private static func error(for code: CURLcode) -> URLError.Code {
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
