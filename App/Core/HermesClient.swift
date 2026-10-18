#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talking to the Hermes agent: one signed write, then poll for the answer.
///
/// The webhook is write-only — it returns 202 the moment it accepts a request and the
/// agent's reply goes to its own delivery channel, which the app cannot read. So anything
/// that needs an answer back uses a mailbox: the app mints a request id, the agent writes
/// `<id>.json` into a directory on the server, and a read-only static server hands it over.
/// **404 means the run is still going; 200 means it finished** — which is why a missing file
/// is `pending` rather than an error.
///
/// Signing is the gateway's V2 scheme: HMAC-SHA256 over `"<timestamp>.<body>"`. V1 signs the
/// body alone, so a captured request replays forever; this only ever sends V2, and the
/// gateway rejects anything older than five minutes.
struct HermesClient: Sendable {
    struct Configuration: Codable, Sendable, Equatable {
        /// The full URL of the acquisition route, e.g.
        /// `http://192.168.1.148:8644/webhooks/music-request`. Other routes are addressed
        /// as siblings of it, so Settings keeps a single URL field.
        var endpoint: URL
        var secret: String
        /// Where answers are read from, e.g. `http://192.168.1.148:8645`.
        ///
        /// **Optional, not defaulted** — Keychain items written before this field existed
        /// must still decode, and a default value does not achieve that. Nil simply means
        /// the agent features that need an answer are unavailable.
        var resultsBase: URL?
    }

    /// The gateway's answer to a submission.
    enum Acceptance: Sendable, Equatable {
        case accepted
        /// The gateway had already seen this id and **did not run the agent**. It answers
        /// HTTP 200 for this, so a naive 2xx check reads it as success — which is why it
        /// is a distinct case. Retries must always mint a fresh id.
        case duplicate
        case rejected(Int)
    }

    var configuration: Configuration

    private var session: URLSession { .shared }

    // MARK: - Writing

    /// Posts to a route beside the configured endpoint.
    func send(
        route: String,
        requestID: UUID,
        fields: [String: String]
    ) async throws -> Acceptance {
        var payload = fields
        payload["request_id"] = requestID.uuidString
        payload["source"] = "Music iOS"

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw HermesError.encoding
        }

        let timestamp = String(Int(Date.now.timeIntervalSince1970))
        let signed = Data(timestamp.utf8) + Data(".".utf8) + body
        let signature = HMAC<SHA256>
            .authenticationCode(
                for: signed,
                using: SymmetricKey(data: Data(configuration.secret.utf8))
            )
            .map { String(format: "%02x", $0) }
            .joined()

        var request = URLRequest(url: url(forRoute: route))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "X-Webhook-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Webhook-Signature-V2")
        // The gateway adopts this as its delivery id, which is what lets the app choose
        // the correlation id instead of having to parse one back out.
        request.setValue(requestID.uuidString, forHTTPHeaderField: "X-Request-ID")
        // Acceptance is immediate; a longer timeout would only hide a bad address.
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200...299).contains(status) else {
            await Diagnostics.shared.record("hermes", "\(route) rejected: HTTP \(status)")
            return .rejected(status)
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reported = object["status"] as? String,
           reported == "duplicate" {
            await Diagnostics.shared.record("hermes", "\(route): duplicate id, agent not run")
            return .duplicate
        }

        return .accepted
    }

    /// Route URLs are siblings of the configured endpoint — every route lives under
    /// `/webhooks/`, so one URL in Settings addresses all of them.
    private func url(forRoute route: String) -> URL {
        configuration.endpoint
            .deletingLastPathComponent()
            .appendingPathComponent(route)
    }

    // MARK: - Reading

    /// The raw answer, or nil while the run is still going.
    func result(for requestID: UUID) async throws -> Data? {
        guard let base = configuration.resultsBase else { throw HermesError.noResultsAddress }

        var request = URLRequest(url: base.appendingPathComponent("\(requestID.uuidString).json"))
        request.timeoutInterval = 8
        // `http.server` sends no cache headers, and a cached 404 would make polling never
        // finish.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch status {
        case 200: return data
        case 404: return nil
        default:
            await Diagnostics.shared.record("hermes", "results read: HTTP \(status)")
            throw HermesError.badStatus(status)
        }
    }

    /// Decoded, with a missing file reported as `pending`.
    func outcome<T: HermesPayload>(
        for requestID: UUID,
        as type: T.Type
    ) async -> HermesOutcome<T> {
        do {
            guard let data = try await result(for: requestID) else { return .pending }

            let decoder = JSONDecoder()
            // No `.convertFromSnakeCase`: the payload types spell their wire keys out, and
            // the strategy would rewrite the incoming key before the lookup and miss them.
            decoder.dateDecodingStrategy = .custom { decoder in
                let text = try decoder.singleValueContainer().decode(String.self)
                return ServerDate.parse(text) ?? .now
            }

            guard let payload = try? decoder.decode(T.self, from: data) else {
                let preview = String(decoding: data.prefix(200), as: UTF8.self)
                await Diagnostics.shared.record("hermes", "undecodable result: \(preview)")
                return .failed("Hermes sent something I couldn't read.")
            }

            return payload.isOK ? .ok(payload) : .failed(payload.failureText)
        } catch HermesError.noResultsAddress {
            return .failed("No results address set. Add one in Settings → Music Requests.")
        } catch {
            // Still pending as far as anyone knows: the mailbox being unreachable is not
            // the same as the agent having failed.
            await Diagnostics.shared.record("hermes", "results unreachable: \(error.localizedDescription)")
            return .pending
        }
    }

    /// Backs the Test button in Settings, proving both legs before any feature relies on
    /// them.
    func ping() async -> Bool {
        guard let base = configuration.resultsBase else { return false }
        var request = URLRequest(url: base.appendingPathComponent("ping.json"))
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    enum HermesError: Error {
        case encoding
        case noResultsAddress
        case badStatus(Int)
    }
}
