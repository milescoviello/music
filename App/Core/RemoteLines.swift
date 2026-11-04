import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A response read a line at a time as it arrives: a remote player's event stream.
///
/// `URLSession.bytes(for:)` does this on Apple's platforms and does not exist in Linux's
/// Foundation, so playing to another computer from the desktop needs its own. A data
/// task's delegate hands over each piece as it comes; the lines are cut from those, so
/// one split across two pieces is still one line.
enum RemoteLines {
    /// The status code once the headers arrive, and the lines after them.
    static func open(
        _ request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (status: Int, lines: AsyncThrowingStream<String, any Error>) {
        let reader = Reader()
        let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
        let (lines, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        reader.continuation = continuation
        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in
            task.cancel()
            session.invalidateAndCancel()
        }
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (headers: CheckedContinuation<Int, any Error>) in
                reader.setHeaders(headers)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (status, lines)
    }

    private final class Reader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var headers: CheckedContinuation<Int, any Error>?
        var continuation: AsyncThrowingStream<String, any Error>.Continuation?
        private var buffer = Data()

        func setHeaders(_ continuation: CheckedContinuation<Int, any Error>) {
            lock.lock()
            headers = continuation
            lock.unlock()
        }

        private func resolveHeaders(_ result: Result<Int, any Error>) {
            lock.lock()
            let waiting = headers
            headers = nil
            lock.unlock()
            waiting?.resume(with: result)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            resolveHeaders(.success((response as? HTTPURLResponse)?.statusCode ?? 0))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // Should the response callback above not be called (its signature differs a
            // little between SDKs), the first data says the headers have come.
            resolveHeaders(.success((dataTask.response as? HTTPURLResponse)?.statusCode ?? 0))
            lock.lock()
            buffer.append(data)
            var lines: [String] = []
            while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[buffer.startIndex..<end]
                if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                lines.append(String(decoding: line, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...end)
            }
            lock.unlock()
            for line in lines { continuation?.yield(line) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            resolveHeaders(.failure(error ?? URLError(.networkConnectionLost)))
            if let error {
                continuation?.finish(throwing: error)
            } else {
                continuation?.finish()
            }
            session.finishTasksAndInvalidate()
        }
    }
}
