import Foundation
import Network
import Security

/// SSE transport that pins the connection to **HTTP/1.1** via TLS ALPN.
///
/// Why this exists:
///   iOS URLSession (any variant — dataTask, bytes, AsyncSequence)
///   negotiates HTTP/2 with any server that advertises `h2` in ALPN —
///   there's no public API to opt out. HTTP/2 multiplexes streams over
///   shared frames; intermediaries that buffer below a frame threshold
///   (notably ngrok-free, some CDNs) will hold small SSE response
///   bytes indefinitely, and the response headers never reach the
///   client. We've reproduced this exact failure mode.
///
///   Browsers and OkHttp's `EventSources` factory negotiate HTTP/1.1
///   for `Accept: text/event-stream`, which is why web + Android work
///   against the same backend.
///
///   This client uses `Network.framework`'s `NWConnection` and adds
///   `"http/1.1"` to the TLS ALPN application-protocol list — the
///   *only* protocol advertised — so the server has no choice but to
///   speak HTTP/1.1. We then hand-roll the request, parse the
///   response status + headers, decode the body (chunked or
///   identity), and pipe each parsed SSE record back as a tuple
///   `(eventName, eventId, data)`.
///
/// Scope: long-lived SSE GET streams only. The short-lived
/// PUT/POST/DELETE legs of graphql-sse stay on URLSession (HTTP/2 is
/// fine there — those responses are finite and small).
@available(iOS 13.0, macOS 10.15, *)
final class HTTP1EventSource {

    // MARK: - Public surface (mirrors the LACEventSource shape)

    let url: URL
    private(set) var headers: [String: String]

    /// Fires once when the response status line is parsed as 2xx.
    var onOpen: (() -> Void)?

    /// Fires for each parsed SSE record. `event` is the `event:` field
    /// ("next" / "complete" / nil for a plain message), `id` is the
    /// `id:` field, `data` is the joined `data:` lines.
    var onEvent: ((_ event: String?, _ id: String?, _ data: String?) -> Void)?

    /// Fires exactly once when the stream ends (peer half-close,
    /// transport error, non-2xx response, or explicit `disconnect()`).
    /// `statusCode` is nil if we never made it past TLS / received any
    /// response status line.
    var onComplete: ((_ statusCode: Int?, _ error: Error?) -> Void)?

    // MARK: - Construction

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var completed = false
    private var disconnected = false

    init(url: URL, headers: [String: String], queue: DispatchQueue) {
        self.url = url
        self.headers = headers
        self.queue = queue
    }

    // MARK: - State machine

    private enum Stage {
        case waitingHeaders
        case streamingChunked
        case streamingIdentity(remaining: Int?)  // nil = until close
        case closed
    }
    private var stage: Stage = .waitingHeaders
    private var status: Int?
    private var headerBuffer = Data()
    private var chunkedBuffer = Data()
    private var chunkedRemaining: Int = -1
    private let parser = LACEventStreamParser()

    // MARK: - Lifecycle

    func connect() {
        guard let host = url.host, !host.isEmpty else {
            finish(error: URLError(.badURL))
            return
        }
        let port: NWEndpoint.Port
        if let p = url.port {
            port = NWEndpoint.Port(integerLiteral: UInt16(p))
        } else if url.scheme == "https" {
            port = .https
        } else if url.scheme == "http" {
            port = .http
        } else {
            finish(error: URLError(.unsupportedURL))
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        let parameters: NWParameters
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        tcpOpts.connectionTimeout = 30
        if url.scheme == "https" {
            let tls = NWProtocolTLS.Options()
            // CORE OF THE FIX: advertise ONLY http/1.1 in ALPN. With
            // no `h2` in the offered protocol set the server must
            // either pick http/1.1 or fail the handshake. We never
            // get HTTP/2 frames as a result.
            sec_protocol_options_add_tls_application_protocol(
                tls.securityProtocolOptions, "http/1.1"
            )
            parameters = NWParameters(tls: tls, tcp: tcpOpts)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcpOpts)
        }
        // We want SSE events delivered as they arrive, not held by
        // any send-side buffering.
        parameters.allowFastOpen = true

        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        SseLog.debug("HTTP1 connect → \(url.absoluteString) (ALPN=http/1.1)")
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }
        connection.start(queue: queue)
    }

    /// Tear the connection down. Idempotent.
    func disconnect() {
        if disconnected { return }
        disconnected = true
        stage = .closed
        connection?.cancel()
        connection = nil
        // `onComplete` will be invoked by the resulting state update.
    }

    // MARK: - NWConnection state

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            SseLog.debug("HTTP1 TLS ready — sending GET")
            sendRequest()
            receiveLoop()
        case .failed(let error):
            SseLog.warn("HTTP1 connection failed: \(error.localizedDescription)")
            finish(error: error)
        case .cancelled:
            finish(error: nil)
        case .waiting(let error):
            // Generally transient — Network.framework will retry until
            // `timeoutIntervalForRequest`/connection timeout. Log so
            // it shows up in the host diagnostic stream.
            SseLog.warn("HTTP1 waiting: \(error.localizedDescription)")
        default:
            break
        }
    }

    // MARK: - Request

    private func sendRequest() {
        guard let host = url.host else { return }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }

        var lines: [String] = []
        lines.append("GET \(path) HTTP/1.1")
        lines.append("Host: \(host)")
        // Connection: close — when the server eventually ends the
        // response stream (or we cancel) the TCP socket closes
        // naturally; the SDK reconnect loop spins up a fresh
        // connection. Avoids the keep-alive bookkeeping cliff.
        lines.append("Connection: close")

        var hasAccept = false
        var hasCacheControl = false
        for (k, v) in headers {
            let lower = k.lowercased()
            if lower == "accept" { hasAccept = true }
            if lower == "cache-control" { hasCacheControl = true }
            // Host / Connection are ours to set; skip if caller passed them.
            if lower == "host" || lower == "connection" { continue }
            lines.append("\(k): \(v)")
        }
        if !hasAccept { lines.append("Accept: text/event-stream") }
        if !hasCacheControl { lines.append("Cache-Control: no-cache") }
        // Disable response compression — we want raw bytes for SSE
        // parsing; HTTP/1.1 gzip could buffer in proxies.
        lines.append("Accept-Encoding: identity")

        lines.append("")  // header/body separator
        lines.append("")
        guard let data = lines.joined(separator: "\r\n").data(using: .utf8) else { return }
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                SseLog.warn("HTTP1 send error: \(error.localizedDescription)")
                self?.finish(error: error)
            }
        })
    }

    // MARK: - Response

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleIncoming(data)
            }
            if let error {
                SseLog.warn("HTTP1 recv error: \(error.localizedDescription)")
                self.finish(error: error)
                return
            }
            if isComplete {
                SseLog.debug("HTTP1 peer half-closed (stream end)")
                self.finish(error: nil)
                return
            }
            if !self.isClosed {
                self.receiveLoop()
            }
        }
    }

    private var isClosed: Bool {
        if case .closed = stage { return true }
        return completed
    }

    private func handleIncoming(_ data: Data) {
        switch stage {
        case .waitingHeaders:
            headerBuffer.append(data)
            if headerBuffer.count > 64 * 1024 {
                // Defensive cap — well above any reasonable response
                // header set; if we hit this the peer is misbehaving.
                finish(error: URLError(.cannotParseResponse))
                return
            }
            tryParseHeaders()
        case .streamingChunked:
            handleChunkedBody(data)
        case .streamingIdentity(let remaining):
            for event in parser.append(data: data) {
                onEvent?(event.event, event.id, event.data)
            }
            if let remaining {
                let after = remaining - data.count
                if after <= 0 {
                    stage = .closed
                    finish(error: nil)
                }
            }
        case .closed:
            break
        }
    }

    private func tryParseHeaders() {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // CRLF CRLF
        guard let range = headerBuffer.range(of: separator) else { return }
        let headerPart = headerBuffer.subdata(in: 0..<range.lowerBound)
        let leftover = headerBuffer.subdata(in: range.upperBound..<headerBuffer.count)
        headerBuffer = Data()

        guard let raw = String(data: headerPart, encoding: .utf8) else {
            finish(error: URLError(.cannotParseResponse))
            return
        }
        let lines = raw.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            finish(error: URLError(.cannotParseResponse))
            return
        }
        // "HTTP/1.1 200 OK"
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let code = Int(parts[1]) else {
            SseLog.warn("HTTP1 unparseable status line: \(statusLine)")
            finish(error: URLError(.cannotParseResponse))
            return
        }
        status = code
        guard (200...299).contains(code) else {
            SseLog.warn("HTTP1 non-2xx response: \(statusLine)")
            finish(error: nil)
            return
        }

        var transferEncoding: String?
        var contentLength: Int?
        var contentType: String?
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch name {
            case "transfer-encoding": transferEncoding = value.lowercased()
            case "content-length": contentLength = Int(value)
            case "content-type": contentType = value.lowercased()
            default: break
            }
        }
        SseLog.debug("HTTP1 response status=\(code) ctype=\(contentType ?? "?") te=\(transferEncoding ?? "?") cl=\(contentLength.map(String.init) ?? "?")")

        onOpen?()

        if transferEncoding?.contains("chunked") == true {
            stage = .streamingChunked
        } else if let length = contentLength {
            stage = .streamingIdentity(remaining: length)
        } else {
            // Server didn't declare length or chunked — read until
            // peer half-close. Valid HTTP/1.1 for `Connection: close`.
            stage = .streamingIdentity(remaining: nil)
        }

        if !leftover.isEmpty {
            handleIncoming(leftover)
        }
    }

    // MARK: - Chunked body decoder
    //
    // Wire format:
    //   chunk-size CRLF chunk-data CRLF
    //   …repeat until chunk-size = 0…
    //   0 CRLF [trailer-headers] CRLF
    //
    // `chunk-size` may carry a `;extension` suffix that we ignore.

    private func handleChunkedBody(_ data: Data) {
        chunkedBuffer.append(data)
        while true {
            if chunkedRemaining < 0 {
                // Need the next chunk-size line.
                let crlf = Data([0x0D, 0x0A])
                guard let range = chunkedBuffer.range(of: crlf) else {
                    return  // wait for more bytes
                }
                let sizeData = chunkedBuffer.subdata(in: 0..<range.lowerBound)
                chunkedBuffer = chunkedBuffer.subdata(in: range.upperBound..<chunkedBuffer.count)
                guard let sizeLine = String(data: sizeData, encoding: .utf8) else {
                    finish(error: URLError(.cannotParseResponse))
                    return
                }
                let hexPart = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
                let trimmed = hexPart.trimmingCharacters(in: .whitespaces)
                guard let size = Int(trimmed, radix: 16) else {
                    SseLog.warn("HTTP1 invalid chunk size: \(sizeLine.prefix(40))")
                    finish(error: URLError(.cannotParseResponse))
                    return
                }
                chunkedRemaining = size
                if size == 0 {
                    // Terminal chunk; we don't bother parsing trailers.
                    stage = .closed
                    finish(error: nil)
                    return
                }
            }

            // Need the full chunk + its trailing CRLF before consuming.
            if chunkedBuffer.count >= chunkedRemaining + 2 {
                let chunk = chunkedBuffer.subdata(in: 0..<chunkedRemaining)
                let dropTo = chunkedRemaining + 2
                chunkedBuffer = chunkedBuffer.subdata(in: dropTo..<chunkedBuffer.count)
                for event in parser.append(data: chunk) {
                    onEvent?(event.event, event.id, event.data)
                }
                chunkedRemaining = -1
            } else {
                // Partial chunk — feed what we have, keep state.
                let take = min(chunkedRemaining, chunkedBuffer.count)
                if take > 0 {
                    let chunk = chunkedBuffer.subdata(in: 0..<take)
                    chunkedBuffer = chunkedBuffer.subdata(in: take..<chunkedBuffer.count)
                    chunkedRemaining -= take
                    for event in parser.append(data: chunk) {
                        onEvent?(event.event, event.id, event.data)
                    }
                }
                return
            }
        }
    }

    // MARK: - Termination

    private func finish(error: Error?) {
        if completed { return }
        completed = true
        let s = status
        stage = .closed
        connection?.cancel()
        connection = nil
        onComplete?(s, error)
    }
}
