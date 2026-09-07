import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Outcome of an ingest POST, used by the delivery worker to decide whether to
/// drop the batch, retry it, or mark it delivered.
enum TransportResult: Equatable {
    /// 2xx — batch accepted; remove from the queue.
    case success
    /// 5xx, 429, or a transport/network failure — keep the batch and retry with backoff.
    case retryable
    /// Other 4xx (bad token, payload rejected, …) — non-recoverable; drop the batch.
    case drop
}

/// Posts NDJSON event batches to the BugWatch mobile ingest endpoint per the
/// pinned contract:
///
/// ```
/// POST {endpoint}/api/v1/bugwatch/ingest/mobile
/// x-bugwatch-token: <token>
/// Content-Type:     application/x-ndjson
/// <event-json>\n<event-json>\n…
/// ```
///
/// The `URLSession` is injectable so tests can drive it with a mock
/// `URLProtocol`.
struct HttpTransport {
    let endpoint: String
    let requestTimeoutMs: Int
    let session: URLSession
    let outcomeSink: TransportOutcomeSink

    init(endpoint: String, requestTimeoutMs: Int, session: URLSession = .shared, outcomeSink: TransportOutcomeSink = TransportOutcomeSink()) {
        self.endpoint = endpoint
        self.requestTimeoutMs = requestTimeoutMs
        self.session = session
        self.outcomeSink = outcomeSink
    }

    var helloURL: URL? {
        var base = endpoint
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/api/v1/bugwatch/ingest/mobile/hello")
    }

    static func jsonString(_ data: Data, _ key: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }

    static func jsonInt64(_ data: Data, _ key: String) -> Int64? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let n = obj[key] as? NSNumber { return n.int64Value }
        return nil
    }

    func hello(token: String, body: Data) async -> ConnectionCheck {
        let now = Date()
        guard let url = helloURL else { return ConnectionCheck(state: .rejected, reason: "bad_endpoint", checkedAt: now) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(1.0, Double(requestTimeoutMs) / 1000.0)
        request.setValue(token, forHTTPHeaderField: "x-bugwatch-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await session.bwData(for: request)
            guard let http = response as? HTTPURLResponse else { return ConnectionCheck(state: .disconnected, reason: "no_http_response", checkedAt: now) }
            switch http.statusCode {
            case 200...299:
                let serverTimeMs = Self.jsonInt64(data, "serverTimeMs")
                let nowMs = Int64(now.timeIntervalSince1970 * 1000)
                return ConnectionCheck(state: .connected, httpStatus: http.statusCode, serverTimeMs: serverTimeMs,
                                       clockSkewMs: serverTimeMs.map { $0 - nowMs }, checkedAt: now)
            case 429:
                return ConnectionCheck(state: .disconnected, httpStatus: 429, reason: "rate_limited", checkedAt: now)
            case 500...599:
                return ConnectionCheck(state: .disconnected, httpStatus: http.statusCode, reason: "server_error", checkedAt: now)
            default:
                return ConnectionCheck(state: .rejected, httpStatus: http.statusCode,
                                       reason: Self.jsonString(data, "reason") ?? "http_\(http.statusCode)",
                                       hint: Self.jsonString(data, "hint"), checkedAt: now)
            }
        } catch {
            return ConnectionCheck(state: .offline, reason: "unreachable", hint: error.localizedDescription, checkedAt: now)
        }
    }

    /// Full ingest URL (endpoint with any trailing slash trimmed + the path).
    var ingestURL: URL? {
        var base = endpoint
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/api/v1/bugwatch/ingest/mobile")
    }

    /// Classifies an HTTP status code into a delivery decision.
    static func classify(statusCode: Int) -> TransportResult {
        switch statusCode {
        case 200...299: return .success
        case 429, 500...599: return .retryable
        default: return .drop          // 3xx + other 4xx → non-recoverable
        }
    }

    /// POSTs an NDJSON body with the given signed token. `ndjsonBody` is the
    /// already-joined event lines (one JSON object per line). A transport-level
    /// error (no response/network failure) is treated as `.retryable`.
    func send(ndjsonBody: Data, token: String) async -> TransportResult {
        guard let url = ingestURL else { return .drop }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(1.0, Double(requestTimeoutMs) / 1000.0)
        request.setValue(token, forHTTPHeaderField: "x-bugwatch-token")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.httpBody = ndjsonBody

        do {
            let (data, response) = try await session.bwData(for: request)
            guard let http = response as? HTTPURLResponse else { return .retryable }
            let result = Self.classify(statusCode: http.statusCode)
            let rejected = result == .drop
            outcomeSink.handler?(TransportOutcome(
                result: result, httpStatus: http.statusCode,
                reason: rejected ? (Self.jsonString(data, "reason") ?? "http_\(http.statusCode)") : nil,
                hint: rejected ? Self.jsonString(data, "hint") : nil,
                error: nil))
            return result
        } catch {
            // DNS/connection/timeout/offline — recoverable, keep and retry.
            outcomeSink.handler?(TransportOutcome(result: .retryable, httpStatus: nil, reason: nil, hint: nil, error: error.localizedDescription))
            return .retryable
        }
    }
}

extension URLSession {
    /// `data(for:)` shim that works across Apple platforms and Linux
    /// (FoundationNetworking lacks the async overload on some toolchains).
    func bwData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let response else {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                continuation.resume(returning: (data ?? Data(), response))
            }
            task.resume()
        }
        #else
        return try await self.data(for: request)
        #endif
    }
}
