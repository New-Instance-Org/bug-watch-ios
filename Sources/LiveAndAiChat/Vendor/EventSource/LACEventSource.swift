// Vendored from inaka/EventSource 3.0.1
// https://github.com/inaka/EventSource — Apache License 2.0
//
// Source file: EventSource/EventSource.swift
// Local changes:
//   - Type renamed `EventSource` → `LACEventSource` to avoid colliding
//     with any consumer-facing types.
//   - `EventSourceProtocol` and `EventSourceState` similarly renamed.
//   - Symbols kept internal (no `public`) — vendoring as an
//     implementation detail of the SDK, not as a re-export.
//   - `urlSession` callbacks remain delegate-style so the class can
//     stay `NSObject`-derived and `URLSessionDataDelegate`-conformant.

import Foundation

enum LACEventSourceState {
    case connecting
    case open
    case closed
}

protocol LACEventSourceProtocol {
    var headers: [String: String] { get }

    /// RetryTime: This can be changed remotely if the server sends an event `retry:`.
    var retryTime: Int { get }

    /// URL where EventSource will listen for events.
    var url: URL { get }

    /// The last event id received from server.
    var lastEventId: String? { get }

    /// Current state of EventSource.
    var readyState: LACEventSourceState { get }

    /// Connect to server. Optional `lastEventId` is sent in the
    /// `Last-Event-Id` header (used by some servers to replay missed
    /// events on reconnect).
    func connect(lastEventId: String?)

    /// Tear the connection down.
    func disconnect()

    /// Returns the list of event names currently listened for.
    func events() -> [String]

    /// Called when the connection is established.
    func onOpen(_ onOpenCallback: @escaping (() -> Void))

    /// Called when the connection completes (success or failure).
    /// Signature: (statusCode, reconnect, error).
    func onComplete(_ onComplete: @escaping ((Int?, Bool?, NSError?) -> Void))

    /// Called for events with name "message" or no name set.
    func onMessage(_ onMessageCallback: @escaping ((_ id: String?, _ event: String?, _ data: String?) -> Void))

    /// Register a handler for a specific event name.
    func addEventListener(
        _ event: String,
        handler: @escaping ((_ id: String?, _ event: String?, _ data: String?) -> Void)
    )

    /// Unregister a handler for a specific event name.
    func removeEventListener(_ event: String)
}

class LACEventSource: NSObject, LACEventSourceProtocol, URLSessionDataDelegate {
    static let DefaultRetryTime = 3000

    let url: URL
    private(set) var lastEventId: String?
    private(set) var retryTime = LACEventSource.DefaultRetryTime
    private(set) var headers: [String: String]
    private(set) var readyState: LACEventSourceState

    private var onOpenCallback: (() -> Void)?
    private var onComplete: ((Int?, Bool?, NSError?) -> Void)?
    private var onMessageCallback: ((_ id: String?, _ event: String?, _ data: String?) -> Void)?
    private var eventListeners: [String: (_ id: String?, _ event: String?, _ data: String?) -> Void] = [:]

    private var eventStreamParser: LACEventStreamParser?
    private var operationQueue: OperationQueue
    private var mainQueue = DispatchQueue.main
    private var urlSession: URLSession?

    init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers

        readyState = .closed
        operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1

        super.init()
    }

    func connect(lastEventId: String? = nil) {
        eventStreamParser = LACEventStreamParser()
        readyState = .connecting

        let configuration = sessionConfiguration(lastEventId: lastEventId)
        let headerKeys = (configuration.httpAdditionalHeaders ?? [:]).keys.compactMap { $0 as? String }.sorted()
        SseLog.debug("ES connect url=\(url.absoluteString) timeoutReq=\(configuration.timeoutIntervalForRequest) headers=\(headerKeys)")
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: operationQueue)
        let task = urlSession!.dataTask(with: url)
        SseLog.debug("ES dataTask created, calling resume()")
        task.resume()
        SseLog.debug("ES dataTask resumed (state=\(task.state.rawValue))")
    }

    func disconnect() {
        readyState = .closed
        urlSession?.invalidateAndCancel()
    }

    func onOpen(_ onOpenCallback: @escaping (() -> Void)) {
        self.onOpenCallback = onOpenCallback
    }

    func onComplete(_ onComplete: @escaping ((Int?, Bool?, NSError?) -> Void)) {
        self.onComplete = onComplete
    }

    func onMessage(_ onMessageCallback: @escaping ((_ id: String?, _ event: String?, _ data: String?) -> Void)) {
        self.onMessageCallback = onMessageCallback
    }

    func addEventListener(
        _ event: String,
        handler: @escaping ((_ id: String?, _ event: String?, _ data: String?) -> Void)
    ) {
        eventListeners[event] = handler
    }

    func removeEventListener(_ event: String) {
        eventListeners.removeValue(forKey: event)
    }

    func events() -> [String] {
        return Array(eventListeners.keys)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        SseLog.debug("ES rx \(data.count)B state=\(readyState) preview=\(String(data: data.prefix(80), encoding: .utf8)?.replacingOccurrences(of: "\n", with: "⏎") ?? "<binary>")")
        if readyState != .open {
            return
        }
        if let events = eventStreamParser?.append(data: data) {
            SseLog.debug("ES parsed \(events.count) event(s) from chunk")
            notifyReceivedEvents(events)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        SseLog.debug("ES response http=\(http?.statusCode ?? -1) ctype=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "?") tenc=\(http?.value(forHTTPHeaderField: "Transfer-Encoding") ?? "?")")
        completionHandler(.allow)
        readyState = .open
        mainQueue.async { [weak self] in self?.onOpenCallback?() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let code = (task.response as? HTTPURLResponse)?.statusCode
        SseLog.debug("ES didComplete code=\(code ?? -1) err=\(error?.localizedDescription ?? "nil")")
        guard let responseStatusCode = code else {
            mainQueue.async { [weak self] in self?.onComplete?(nil, nil, error as NSError?) }
            return
        }

        let reconnect = shouldReconnect(statusCode: responseStatusCode)
        mainQueue.async { [weak self] in self?.onComplete?(responseStatusCode, reconnect, nil) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var newRequest = request
        self.headers.forEach { newRequest.setValue($1, forHTTPHeaderField: $0) }
        completionHandler(newRequest)
    }
}

extension LACEventSource {

    func sessionConfiguration(lastEventId: String?) -> URLSessionConfiguration {
        var additionalHeaders = headers
        if let eventID = lastEventId {
            additionalHeaders["Last-Event-Id"] = eventID
        }

        additionalHeaders["Accept"] = "text/event-stream"
        additionalHeaders["Cache-Control"] = "no-cache"

        // Ephemeral config (matches the PUT/POST session we use elsewhere) —
        // avoids cookie/cache state that can break SSE on iOS.
        // `waitsForConnectivity = false` is deliberate: when true,
        // URLSession can swallow the request indefinitely if it thinks
        // the connection is "still establishing", and the delegate
        // never fires (not even on timeout). We've reproduced exactly
        // that against ngrok-free + HTTP/2 SSE.
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 60 * 60 * 12 // 12h
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.httpAdditionalHeaders = additionalHeaders

        return sessionConfiguration
    }
}

private extension LACEventSource {

    func notifyReceivedEvents(_ events: [LACEvent]) {
        for event in events {
            lastEventId = event.id
            retryTime = event.retryTime ?? LACEventSource.DefaultRetryTime

            if event.onlyRetryEvent == true {
                SseLog.debug("ES retry-only event time=\(retryTime)")
                continue
            }

            let listenedKeys = Array(eventListeners.keys)
            SseLog.debug("ES event name=\(event.event ?? "<nil>") id=\(event.id ?? "<nil>") dataLen=\(event.data?.count ?? 0) listeners=\(listenedKeys)")

            if event.event == nil || event.event == "message" {
                mainQueue.async { [weak self] in
                    self?.onMessageCallback?(event.id, "message", event.data)
                }
            }

            if let eventName = event.event, let eventHandler = eventListeners[eventName] {
                mainQueue.async { eventHandler(event.id, event.event, event.data) }
            } else if let eventName = event.event {
                SseLog.warn("ES no listener for event '\(eventName)' — keys=\(listenedKeys)")
            }
        }
    }

    /// Per W3C EventSource processing model — 2xx responses other than
    /// 200 indicate "reconnect"; everything else is terminal.
    func shouldReconnect(statusCode: Int) -> Bool {
        switch statusCode {
        case 200:
            return false
        case _ where statusCode > 200 && statusCode < 300:
            return true
        default:
            return false
        }
    }
}
