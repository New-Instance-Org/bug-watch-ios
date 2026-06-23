import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Automatic **network breadcrumbs** — A5.
///
/// A `URLProtocol` subclass that observes outbound HTTP(S) requests and drops one
/// breadcrumb per request (category `"network"`, with method / host / path /
/// status_code / duration_ms). All policy (what to record, path redaction) lives in
/// the pure ``NetworkBreadcrumbRecorder``; this type is just the `URLProtocol`
/// lifecycle plumbing around it.
///
/// ## How it intercepts (and why it doesn't recurse)
/// Once registered, the URL loading system asks every registered protocol whether it
/// can handle a request. We say yes (`canInit`) only when instrumentation is enabled
/// and the recorder wants this URL. We then *re-issue the very same request through
/// an internal `URLSession`* whose configuration does **not** include this protocol,
/// time it, forward the response/data/errors back to the original client, and record
/// the breadcrumb on completion. To stop the URL loading system from handing that
/// internal request straight back to us (infinite loop), the outgoing copy is tagged
/// with a private `URLProtocol` property; `canInit` rejects any request carrying it.
///
/// ## Limitation (documented intentionally)
/// `URLProtocol.registerClass` only affects requests made through `URLSession.shared`
/// and any session whose `URLSessionConfiguration.protocolClasses` includes this
/// class. To also cover the *default* configuration used by ad-hoc
/// `URLSession(configuration: .default)` instances, `install` additionally swaps the
/// protocol into `URLSessionConfiguration.default.protocolClasses`. Sessions built
/// from a **custom** configuration that the app constructed *before* `install` (or
/// that deliberately omits our class) are not covered — this is inherent to
/// `URLProtocol` and is the same limitation every URLProtocol-based interceptor has.
/// BugWatch's own ingest session is unaffected because the recorder always excludes
/// the ingest host/path, so even intercepted ingest requests are skipped.
final class NetworkInstrumentation: URLProtocol {

    // MARK: Shared configuration (URLProtocol instances are created by the URL
    // loading system, so configuration is reachable only via static state).

    /// Guards `enabled` / `recorder` / `sink`.
    private static let configLock = NSLock()
    private static var enabled = false
    private static var recorder: NetworkBreadcrumbRecorder?
    /// Sink for recorded breadcrumbs — the SDK's redacting `addBreadcrumb`.
    private static var sink: ((Breadcrumb) -> Void)?

    /// Property key used to mark our internal re-issued request so `canInit` ignores
    /// it (prevents infinite recursion).
    private static let handledKey = "cloud.newinstance.bugwatch.network.handled"

    /// Internal session used to actually perform the observed request. Its config
    /// deliberately has no `protocolClasses`, so requests it makes are never handed
    /// back to this protocol.
    private static let internalSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        return URLSession(configuration: config)
    }()

    /// The in-flight delegated task for the current intercept. (`URLProtocol` already
    /// declares a read-only `task` property, so this uses a distinct name.)
    private var proxyTask: URLSessionDataTask?
    private var startedAt: TimeInterval = 0

    // MARK: Install / uninstall

    /// Registers the protocol and arms recording. Idempotent. After this, requests
    /// through `URLSession.shared` and the default configuration are observed.
    static func install(recorder: NetworkBreadcrumbRecorder, sink: @escaping (Breadcrumb) -> Void) {
        configLock.lock()
        Self.recorder = recorder
        Self.sink = sink
        Self.enabled = true
        configLock.unlock()

        URLProtocol.registerClass(NetworkInstrumentation.self)
        // Also inject into the *default* configuration so ad-hoc
        // `URLSession(configuration: .default)` instances created afterwards are
        // covered. Prepend so we get first refusal.
        let defaultConfig = URLSessionConfiguration.default
        var classes = defaultConfig.protocolClasses ?? []
        if !classes.contains(where: { $0 == NetworkInstrumentation.self }) {
            classes.insert(NetworkInstrumentation.self, at: 0)
            defaultConfig.protocolClasses = classes
        }
    }

    /// Disarms recording and unregisters the protocol. Idempotent. Setting
    /// `enabled = false` makes `canInit` reject everything even if some session still
    /// references the class.
    static func uninstall() {
        configLock.lock()
        Self.enabled = false
        Self.recorder = nil
        Self.sink = nil
        configLock.unlock()
        URLProtocol.unregisterClass(NetworkInstrumentation.self)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        // Recursion guard: never handle the request we re-issued ourselves.
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }

        configLock.lock()
        let on = enabled
        let rec = recorder
        configLock.unlock()
        guard on, let rec else { return false }

        return rec.shouldRecord(url: request.url)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        startedAt = Date().timeIntervalSince1970

        // Re-issue the same request, tagged so we don't re-intercept it.
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            // Can't copy — fail the load cleanly so the host isn't left hanging.
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: NetworkInstrumentation.handledKey, in: mutable)
        let outbound = mutable as URLRequest

        let dataTask = NetworkInstrumentation.internalSession.dataTask(with: outbound) { [weak self] data, response, error in
            guard let self else { return }
            let durationMs = Int((Date().timeIntervalSince1970 - self.startedAt) * 1000.0)

            if let error {
                // Forward the failure to the original client, then record a
                // status-less breadcrumb (still useful: method/host/path/duration).
                self.client?.urlProtocol(self, didFailWithError: error)
                self.record(statusCode: nil, durationMs: durationMs)
                return
            }

            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
            let status = (response as? HTTPURLResponse)?.statusCode
            self.record(statusCode: status, durationMs: durationMs)
        }
        self.proxyTask = dataTask
        dataTask.resume()
    }

    override func stopLoading() {
        proxyTask?.cancel()
        proxyTask = nil
    }

    /// Records the breadcrumb for the just-completed request via the recorder + sink.
    private func record(statusCode: Int?, durationMs: Int) {
        NetworkInstrumentation.configLock.lock()
        let rec = NetworkInstrumentation.recorder
        let sink = NetworkInstrumentation.sink
        NetworkInstrumentation.configLock.unlock()
        guard let rec, let sink, let url = request.url else { return }
        let crumb = rec.breadcrumb(
            method: request.httpMethod ?? "GET",
            url: url,
            statusCode: statusCode,
            durationMs: durationMs
        )
        sink(crumb)
    }
}
