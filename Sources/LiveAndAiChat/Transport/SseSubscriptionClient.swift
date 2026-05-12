import Foundation
import Combine
import os.log

/// GraphQL-over-SSE single-connection client. Wire protocol per
/// `graphql-sse` PROTOCOL.md (and matches the Android implementation
/// in `SseSubscriptionClient.kt`):
///
///   1. **Reservation**:  `PUT  {endpoint}`       → 201 + token in body
///   2. **Stream**:       `GET  {endpoint}`       + `X-GraphQL-Event-Stream-Token: <token>` header
///   3. **Subscribe**:    `POST {endpoint}` body  `{query, variables, extensions: {operationId: <uuid>}}`
///   4. **Complete**:     `DELETE {endpoint}?operationId=<uuid>`
///
/// Stream events:
///   - `event: next`     `data: {id: "<opId>", payload: ExecutionResult}`
///   - `event: complete` `data: {id: "<opId>"}`
///
/// **Step 2 (the long-lived GET stream)** is handled by the vendored
/// `LACEventSource` from inaka/EventSource. We tried URLSession.dataTask
/// + delegate and URLSession.bytes(for:) — neither delivered reliably
/// against streaming responses behind proxies (ngrok in particular).
/// `LACEventSource` is purpose-built for SSE and matches what OkHttp's
/// `EventSources` factory does on Android, which is the proven path.
///
/// Steps 1, 3, 4 are plain HTTPS round-trips and stay on URLSession.
///
/// Reconnect: exponential backoff (`Backoff`) with ±50% jitter.
/// Heartbeat: any inbound event resets `lastEventAt`. A watchdog
/// force-reconnects if no event arrives within `heartbeatTimeoutMs`.
///
/// React Native parity note: when Phase 3 lands we'll wrap
/// https://github.com/binaryminds/react-native-sse — its `EventSource`
/// API is near-identical (`addEventListener('next', ...)`, `close()`),
/// so the routing layer below can be mirrored exactly.
final class SseSubscriptionClient: NSObject, SubscriptionClient {

    // MARK: - Public surface

    private let _connectionState = CurrentValueSubject<ConnectionState, Never>(.idle)
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        _connectionState.eraseToAnyPublisher()
    }

    // MARK: - Construction

    private let endpoint: URL
    private let apiKey: String
    private let reconnect: ReconnectPolicy
    private let heartbeatTimeoutMs: Int
    private let session: URLSession

    init(
        endpoint: URL,
        apiKey: String,
        reconnect: ReconnectPolicy = ReconnectPolicy(),
        heartbeatTimeoutMs: Int = 30_000,
        urlSessionConfig: URLSessionConfiguration = .ephemeral
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.reconnect = reconnect
        self.heartbeatTimeoutMs = heartbeatTimeoutMs
        let cfg = urlSessionConfig
        // PUT/POST/DELETE are short-lived requests — the SDK-wide default
        // timeoutIntervalForRequest of 60s is plenty. We leave it alone.
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    // MARK: - Lifecycle

    private let queue = DispatchQueue(label: "com.cinstance.liveandaichat.sse", qos: .utility)
    private var stopped = false
    private var connectTask: Task<Void, Never>?
    private var watchdogTimer: DispatchSourceTimer?
    /// The streaming GET connection. Closed by the server (via `complete`
    /// or transport error) or by `stop()`.
    ///
    /// We use `HTTP1EventSource` (Network.framework / NWConnection with
    /// TLS ALPN pinned to `http/1.1`) instead of the vendored
    /// `LACEventSource` (URLSession). URLSession always negotiates
    /// HTTP/2 when the server advertises it — there's no public API
    /// to disable that — and proxies like ngrok-free buffer small
    /// HTTP/2 SSE responses indefinitely. Pinning ALPN to http/1.1
    /// guarantees chunked transfer-encoding which streams through any
    /// HTTP/1.1-aware proxy without buffering.
    private var eventSource: HTTP1EventSource?
    /// Resumed once when the EventSource closes, so `connectLoop` can
    /// run its backoff and re-enter.
    private var streamClosedContinuation: CheckedContinuation<Void, Never>?
    private var token: String?
    private var lastEventAt = Date()
    private var attempts = 0

    private struct LiveOp {
        let request: SubscriptionRequest
        let subject: PassthroughSubject<[String: Any], Never>
    }
    private var operations: [String: LiveOp] = [:]
    private let opsLock = NSLock()

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.stopped { return }
            if self.connectTask != nil { return }
            self.connectTask = Task.detached { [weak self] in
                await self?.connectLoop()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.connectTask?.cancel()
            self.connectTask = nil
            self.watchdogTimer?.cancel()
            self.watchdogTimer = nil
            self.eventSource?.disconnect()
            self.eventSource = nil
            self.resumeStreamClosed()
            self.token = nil
            self.opsLock.lock()
            for (_, op) in self.operations { op.subject.send(completion: .finished) }
            self.operations.removeAll()
            self.opsLock.unlock()
            self._connectionState.send(.idle)
        }
    }

    // MARK: - Subscribe

    func subscribe(_ request: SubscriptionRequest) -> AnyPublisher<[String: Any], Never> {
        let opId = UUID().uuidString
        let subject = PassthroughSubject<[String: Any], Never>()
        opsLock.lock()
        operations[opId] = LiveOp(request: request, subject: subject)
        let opCount = operations.count
        opsLock.unlock()
        let opName = request.operationName ?? Self.inferOperationName(from: request.query) ?? "?"
        SseLog.debug("subscribe op=\(opName) opId=\(opId.suffix(8)) state=\(_connectionState.value) total=\(opCount)")
        if _connectionState.value == .connected {
            sendSubscribe(opId: opId, request: request)
        }
        return subject
            .handleEvents(
                receiveOutput: { data in
                    let topKey = data.keys.sorted().first ?? "<empty>"
                    SseLog.debug("emit op=\(opName) opId=\(opId.suffix(8)) topKey=\(topKey)")
                },
                receiveCompletion: { _ in
                    SseLog.debug("complete op=\(opName) opId=\(opId.suffix(8))")
                },
                receiveCancel: { [weak self] in
                    guard let self else { return }
                    SseLog.debug("cancel op=\(opName) opId=\(opId.suffix(8))")
                    self.opsLock.lock()
                    self.operations.removeValue(forKey: opId)
                    self.opsLock.unlock()
                    self.sendComplete(opId: opId)
                }
            )
            .eraseToAnyPublisher()
    }

    /// Best-effort sniff of `subscription Foo(...)` operation name from a
    /// raw GraphQL document so logs are readable without our caller
    /// having to pass `operationName` explicitly.
    private static func inferOperationName(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for keyword in ["subscription", "query", "mutation"] {
            if trimmed.hasPrefix(keyword) {
                let after = trimmed.dropFirst(keyword.count)
                    .drop(while: { $0 == " " || $0 == "\t" })
                let name = after.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
                if !name.isEmpty { return String(name) }
            }
        }
        return nil
    }

    // MARK: - Connect loop

    private func connectLoop() async {
        while !stopped {
            SseLog.debug("connectLoop attempt=\(attempts + 1)/\(reconnect.maxAttempts)")
            _connectionState.send(.connecting)
            let ok = await reserveToken()
            if !ok {
                _connectionState.send(.disconnected)
            } else {
                await openStreamAndWait()
            }
            if stopped { break }
            attempts += 1
            if attempts > reconnect.maxAttempts {
                SseLog.warn("connectLoop exhausted attempts (\(attempts)) — giving up")
                _connectionState.send(.disconnected)
                return
            }
            let delay = Backoff.delayMillis(policy: reconnect, attempt: attempts - 1)
            SseLog.debug("connectLoop backoff \(delay)ms before retry")
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
    }

    private func reserveToken() async -> Bool {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PUT"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        // ngrok-free's interstitial otherwise breaks streaming behind
        // dev tunnels. No-op against any non-ngrok backend.
        req.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.setValue("LiveAndAiChat-iOS/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = Data()
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                SseLog.warn("reserveToken http=\(code) body=\(body.prefix(200))")
                return false
            }
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if body.isEmpty {
                SseLog.warn("reserveToken returned empty body")
                return false
            }
            // graphql-sse always returns a short opaque token. If the
            // body looks like HTML or whitespace-bearing text, the
            // upstream gave us something else (e.g. an ngrok / proxy
            // interstitial); refuse to use it as a token.
            if body.contains("<") || body.contains(">") || body.contains(" ") {
                SseLog.warn("reserveToken got non-token body: \(body.prefix(120))")
                return false
            }
            SseLog.debug("reserveToken OK http=\(http.statusCode) tokenLen=\(body.count)")
            token = body
            return true
        } catch {
            SseLog.warn("reserveToken threw: \(error)")
            return false
        }
    }

    /// Open the SSE stream and await its closure. Returns when the
    /// EventSource completes (server-side complete / transport error /
    /// `stop()` was called).
    private func openStreamAndWait() async {
        guard let t = token else { return }

        let headers: [String: String] = [
            "x-api-key": apiKey,
            "X-GraphQL-Event-Stream-Token": t,
            "ngrok-skip-browser-warning": "true",
            "User-Agent": "LiveAndAiChat-iOS/1.0",
        ]

        // HTTP1EventSource pins TLS ALPN to `http/1.1` — the server
        // cannot negotiate HTTP/2, so the response streams through
        // any HTTP/1.1-aware proxy (incl. ngrok-free) without frame
        // buffering. Replaces the URLSession-based LACEventSource.
        let es = HTTP1EventSource(url: endpoint, headers: headers, queue: queue)
        eventSource = es
        SseLog.debug("openStream — GET \(endpoint.absoluteString)")

        es.onOpen = { [weak self] in
            self?.onStreamOpened()
        }
        es.onEvent = { [weak self] name, _, data in
            // `next` events carry subscription payloads, `complete`
            // events tell us a specific operationId is done. Anything
            // else (default / "message") still routes through the
            // same handler so we don't miss events from older server
            // versions.
            self?.onStreamEvent(name: name, data: data ?? "")
        }
        es.onComplete = { [weak self] statusCode, error in
            SseLog.debug("HTTP1EventSource complete code=\(statusCode ?? -1) err=\(error?.localizedDescription ?? "nil")")
            self?.onStreamClosed()
        }

        es.connect()

        // Open-stream watchdog. URLSession can silently hang on
        // HTTP/2 SSE responses behind proxies that buffer below the
        // frame threshold (we've reproduced this against ngrok-free):
        // dataTask is .running but no delegate callback EVER fires,
        // including the configured request timeout. To recover, we
        // arm our own timer; if `onStreamOpened` hasn't been called
        // within `openTimeoutSeconds` we forcibly disconnect, which
        // triggers `onComplete` → `onStreamClosed` and lets the
        // connect loop back off and retry.
        let openTimeoutSeconds = 12
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + .seconds(openTimeoutSeconds))
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            if self._connectionState.value != .connected {
                SseLog.warn("open-stream watchdog: no headers/response after \(openTimeoutSeconds)s — forcing disconnect")
                self.eventSource?.disconnect()
                self.onStreamClosed()
            }
            watchdog.cancel()
        }
        watchdog.resume()

        // Block here until the stream closes — connectLoop's backoff
        // then decides whether to reopen.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume()
                    return
                }
                if self.stopped {
                    cont.resume()
                    return
                }
                if self.eventSource == nil {
                    // Stream already closed by the time we got here.
                    cont.resume()
                    return
                }
                self.streamClosedContinuation = cont
            }
        }

        watchdog.cancel()
    }

    private func resumeStreamClosed() {
        let cont = streamClosedContinuation
        streamClosedContinuation = nil
        cont?.resume()
    }

    private func onStreamOpened() {
        queue.async { [weak self] in
            guard let self else { return }
            self.attempts = 0
            self.lastEventAt = Date()
            self._connectionState.send(.connected)
            self.opsLock.lock()
            let snapshot = self.operations
            self.opsLock.unlock()
            SseLog.debug("stream OPEN — replaying \(snapshot.count) subscription(s)")
            for (id, op) in snapshot {
                self.sendSubscribe(opId: id, request: op.request)
            }
            self.armWatchdog()
        }
    }

    private func onStreamEvent(name: String?, data: String) {
        lastEventAt = Date()
        guard !data.isEmpty else { return }
        guard let bytes = data.data(using: .utf8) else {
            SseLog.warn("event UTF-8 decode failed for data=\(data.prefix(120))")
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: bytes, options: []) as? [String: Any] else {
            SseLog.warn("event JSON parse failed for data=\(data.prefix(200))")
            return
        }
        guard let opId = obj["id"] as? String else {
            SseLog.warn("event missing 'id' field: \(obj)")
            return
        }

        switch name {
        case "next":
            opsLock.lock()
            let op = operations[opId]
            let opCount = operations.count
            opsLock.unlock()
            if op == nil {
                SseLog.warn("next opId=\(opId.suffix(8)) not in \(opCount) live ops")
            }
            if let payload = obj["payload"] as? [String: Any] {
                if let errors = payload["errors"] {
                    SseLog.warn("next opId=\(opId.suffix(8)) errors=\(errors)")
                }
                if let dataField = payload["data"] as? [String: Any] {
                    SseLog.debug("next opId=\(opId.suffix(8)) keys=\(Array(dataField.keys))")
                    op?.subject.send(dataField)
                }
            }
        case "complete":
            opsLock.lock()
            let op = operations.removeValue(forKey: opId)
            opsLock.unlock()
            SseLog.debug("complete opId=\(opId.suffix(8)) (op=\(op == nil ? "missing" : "found"))")
            op?.subject.send(completion: .finished)
        default:
            SseLog.debug("event name=\(name ?? "<nil>") opId=\(opId.suffix(8))")
            opsLock.lock()
            let op = operations[opId]
            opsLock.unlock()
            if let payload = obj["payload"] as? [String: Any],
               let dataField = payload["data"] as? [String: Any] {
                op?.subject.send(dataField)
            }
        }
    }

    private func onStreamClosed() {
        queue.async { [weak self] in
            guard let self else { return }
            SseLog.debug("stream CLOSED (stopped=\(self.stopped))")
            self.eventSource = nil
            if !self.stopped { self._connectionState.send(.disconnected) }
            self.resumeStreamClosed()
        }
    }

    // MARK: - Watchdog

    private func armWatchdog() {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(1, heartbeatTimeoutMs / 2)
        timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Int(Date().timeIntervalSince(self.lastEventAt) * 1000)
            if elapsed > self.heartbeatTimeoutMs {
                SseLog.warn("watchdog: no event for \(elapsed)ms — tearing down stream")
                self.eventSource?.disconnect()
                self.eventSource = nil
                self._connectionState.send(.disconnected)
                self.watchdogTimer?.cancel()
                self.watchdogTimer = nil
                self.resumeStreamClosed()
            }
        }
        watchdogTimer = timer
        timer.resume()
    }

    // MARK: - Subscribe / complete (HTTPS round-trips on URLSession)

    private func sendSubscribe(opId: String, request: SubscriptionRequest) {
        guard let t = token else { return }
        var body: [String: Any] = ["query": request.query]
        if let v = request.variables { body["variables"] = v }
        if let n = request.operationName { body["operationName"] = n }
        body["extensions"] = ["operationId": opId]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(t, forHTTPHeaderField: "X-GraphQL-Event-Stream-Token")
        req.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.setValue("LiveAndAiChat-iOS/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        let task = session.dataTask(with: req) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let error = error {
                SseLog.warn("sendSubscribe opId=\(opId.suffix(8)) error=\(error)")
            } else if !(200...299).contains(code) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                SseLog.warn("sendSubscribe opId=\(opId.suffix(8)) http=\(code) body=\(body.prefix(200))")
            } else {
                SseLog.debug("sendSubscribe opId=\(opId.suffix(8)) accepted (http=\(code))")
            }
        }
        task.resume()
    }

    private func sendComplete(opId: String) {
        guard let t = token else { return }
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "operationId", value: opId))
        comps.queryItems = items
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(t, forHTTPHeaderField: "X-GraphQL-Event-Stream-Token")
        req.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.setValue("LiveAndAiChat-iOS/1.0", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req).resume()
    }
}

/// Lightweight SSE diagnostic logger. Uses stdout so messages show up
/// in Xcode's console, the simulator log app, and `xcrun simctl spawn
/// log show --process LiveAndAiChatExample`. We also fan out to OSLog
/// at the `error` type so messages aren't dropped by the default log
/// filter.
enum SseLog {
    private static let logger = OSLog(subsystem: "liveandaichat", category: "sse")

    static func debug(_ message: String) {
        let line = "[LAC/SSE] \(message)"
        print(line)
        os_log("%{public}@", log: logger, type: .error, line)
        LACDiagnosticLog.emit(line)
    }

    static func warn(_ message: String) {
        let line = "[LAC/SSE WARN] \(message)"
        print(line)
        os_log("%{public}@", log: logger, type: .error, line)
        LACDiagnosticLog.emit(line)
    }
}
