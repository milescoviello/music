import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSession {
    /// `data(for:)`, except on the Linux desktop, where libcurl does the request itself
    /// (`CurlFetch`): Foundation's URLSession there drives libcurl through a timer and a
    /// dispatch source per socket, reset at every few kilobytes, which on the 2009 MacBook
    /// was most of what a launch's requests cost. The phone keeps Apple's URLSession.
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        #if os(Linux) && canImport(CCurl)
        try await CurlFetch.data(for: request, timeout: configuration.timeoutIntervalForRequest)
        #else
        try await data(for: request)
        #endif
    }

    func fetch(from url: URL) async throws -> (Data, URLResponse) {
        try await fetch(URLRequest(url: url))
    }
}
