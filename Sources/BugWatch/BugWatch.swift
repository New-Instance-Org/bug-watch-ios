import Foundation

/// BugWatch — crash, error, and log observability for iOS.
///
/// Public entry point. Capture methods build a full, redacted event (device +
/// platform + install/session context + breadcrumbs + release/env/tags/user),
/// persist it to a disk-backed queue, then nudge a serial delivery worker that
/// signs a fresh ingest token per attempt and POSTs NDJSON batches to the
/// BugWatch mobile ingest endpoint. Delivery also runs on a timer and resumes
/// when connectivity returns. Crash/ANR capture and session telemetry arrive in
/// later milestones.
public final class BugWatch {
    /// The shared instance created by `start(options:)`, if any.
    public private(set) static var shared: BugWatch?

    public static let sdkName = "bugwatch-ios"
    public static let sdkVersion = "0.1.0"

    private let options: BugWatchOptions
    private let queue: PersistentEventQueue
    private let monitor = NetworkMonitor()
    private let signer: TokenSigner
    private let transport: HttpTransport
    private let worker: DeliveryWorker
    private let redactor: Redactor
    private let device: DeviceInfo
    private let installId: String
    private let sessionId: String

    private let lock = NSLock()
    private var user: BugWatchUser?
    private var tags: [String: String] = [:]
    private var contexts: [String: String] = [:]
    private var release: String?
    private var breadcrumbs: [Breadcrumb] = []

    private var flushTimer: DispatchSourceTimer?

    private init(options: BugWatchOptions) {
        self.options = options
        self.release = options.release
        self.queue = PersistentEventQueue(maxQueueSize: options.maxQueueSize)
        self.redactor = Redactor(sensitiveFields: options.sensitiveFields)
        self.device = DeviceContext.collect()
        self.installId = DeviceContext.installId()
        self.sessionId = "bw_s_" + UUID().uuidString.lowercased()

        let signer = TokenSigner(appSecret: options.appSecret)
        self.signer = signer
        let session = BugWatch.makeSession(timeoutMs: options.requestTimeoutMs)
        let transport = HttpTransport(
            endpoint: options.endpoint,
            requestTimeoutMs: options.requestTimeoutMs,
            session: session
        )
        self.transport = transport
        let debug = options.debug
        self.worker = DeliveryWorker(
            signer: signer,
            transport: transport,
            queue: queue,
            pid: options.projectId,
            env: options.environment,
            batchSize: options.batchSize,
            retry: options.retry,
            log: { line in
                guard debug else { return }
                BugWatchDiagnosticLog.emit("[BugWatch] \(line)")
            }
        )
    }

    // MARK: Lifecycle

    /// Starts the SDK. Idempotent — subsequent calls return the existing
    /// instance without reconfiguring.
    @discardableResult
    public static func start(options: BugWatchOptions) -> BugWatch {
        if let existing = shared { return existing }
        let instance = BugWatch(options: options)
        shared = instance
        instance.boot()
        instance.log("started (env=\(options.environment), release=\(options.release ?? "-"), session=\(instance.sessionId))")
        return instance
    }

    private func boot() {
        // Resume delivery as soon as connectivity returns.
        monitor.onBecameOnline = { [weak self] in
            self?.drainAsync()
        }
        monitor.start()
        startFlushTimer()
        // Attempt to deliver anything left over from a previous run.
        drainAsync()
    }

    /// Stops the SDK and tears down the shared instance.
    public static func close() {
        shared?.closeInstance()
        shared = nil
    }

    private func closeInstance() {
        flushTimer?.cancel()
        flushTimer = nil
        monitor.onBecameOnline = nil
        monitor.stop()
        log("closed")
    }

    // MARK: Capture

    @discardableResult
    public static func capture(error: Error) -> String? { shared?.capture(error: error) }

    @discardableResult
    public func capture(error: Error) -> String {
        let nsError = error as NSError
        let exception = NormalizedException(
            type: String(reflecting: type(of: error)),
            value: nsError.localizedDescription,
            stacktrace: nil
        )
        return enqueue(level: .error, message: nil, exception: exception)
    }

    @discardableResult
    public static func captureMessage(_ message: String, level: Severity = .info) -> String? {
        shared?.captureMessage(message, level: level)
    }

    @discardableResult
    public func captureMessage(_ message: String, level: Severity = .info) -> String {
        enqueue(level: level, message: message, exception: nil)
    }

    // MARK: Scope

    public static func setUser(_ user: BugWatchUser?) { shared?.setUser(user) }
    public func setUser(_ user: BugWatchUser?) {
        lock.lock(); self.user = user; lock.unlock()
    }

    public static func setTag(key: String, value: String) { shared?.setTag(key: key, value: value) }
    public func setTag(key: String, value: String) {
        lock.lock(); tags[key] = value; lock.unlock()
    }

    public static func setContext(_ key: String, value: String) { shared?.setContext(key, value: value) }
    public func setContext(_ key: String, value: String) {
        lock.lock(); contexts[key] = value; lock.unlock()
    }

    public static func setRelease(_ release: String) { shared?.setRelease(release) }
    public func setRelease(_ release: String) {
        lock.lock(); self.release = release; lock.unlock()
    }

    public static func addBreadcrumb(_ crumb: Breadcrumb) { shared?.addBreadcrumb(crumb) }
    public func addBreadcrumb(_ crumb: Breadcrumb) {
        lock.lock()
        breadcrumbs.append(crumb)
        if breadcrumbs.count > 100 {
            breadcrumbs.removeFirst(breadcrumbs.count - 100)
        }
        lock.unlock()
    }

    // MARK: Delivery

    /// Forces an immediate drain and returns once it completes (or the queue is
    /// empty). Use before shutdown to flush pending events.
    public static func flush() async { await shared?.flush() }

    public func flush() async {
        await worker.drain()
    }

    /// Fire-and-forget flush variant for call sites that can't await.
    public static func flush(completion: (() -> Void)? = nil) {
        guard let shared else { completion?(); return }
        Task { await shared.flush(); completion?() }
    }

    // MARK: Internals

    @discardableResult
    private func enqueue(level: Severity, message: String?, exception: NormalizedException?) -> String {
        let id = "bw_e_" + UUID().uuidString.lowercased()
        guard options.enabled else { return id }

        // Sampling — drop a fraction of events deterministically per call.
        if options.sampleRate < 1.0 {
            if options.sampleRate <= 0.0 || Double.random(in: 0..<1) >= options.sampleRate {
                log("sampled out \(level) event \(id)")
                return id
            }
        }

        lock.lock()
        let snapshotUser = user
        let snapshotTags = tags.isEmpty ? nil : tags
        let snapshotRelease = release
        let snapshotCrumbs = breadcrumbs.isEmpty ? nil : breadcrumbs
        lock.unlock()

        // Redact sensitive values before the event ever touches disk.
        let redactedTags = redactor.redact(snapshotTags)
        let redactedUser = redactor.redact(snapshotUser)
        let redactedCrumbs = redactor.redact(snapshotCrumbs)

        let event = BugWatchEvent(
            eventId: id,
            time: Int64(Date().timeIntervalSince1970 * 1000),
            level: level.rawValue,
            message: message,
            exception: exception,
            release: snapshotRelease,
            environment: options.environment,
            tags: redactedTags,
            user: redactedUser,
            breadcrumbs: redactedCrumbs,
            sdk: SdkInfo(name: BugWatch.sdkName, version: BugWatch.sdkVersion),
            platform: "ios",
            installId: installId,
            sessionId: sessionId,
            device: device
        )
        queue.enqueue(event)
        log("captured \(level) event \(id) (queued=\(queue.count))")
        drainAsync()
        return id
    }

    /// Kicks the delivery worker without blocking the caller.
    private func drainAsync() {
        let worker = self.worker
        Task { await worker.drain() }
    }

    private func startFlushTimer() {
        guard options.flushIntervalMs > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let interval = DispatchTimeInterval.milliseconds(options.flushIntervalMs)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.drainAsync()
        }
        timer.resume()
        flushTimer = timer
    }

    private static func makeSession(timeoutMs: Int) -> URLSession {
        let config = URLSessionConfiguration.default
        let seconds = max(1.0, Double(timeoutMs) / 1000.0)
        config.timeoutIntervalForRequest = seconds
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    private func log(_ line: String) {
        guard options.debug else { return }
        BugWatchDiagnosticLog.emit("[BugWatch] \(line)")
    }
}
