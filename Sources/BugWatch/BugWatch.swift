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

    /// Whether the previous run ended in a native crash, read from a tiny
    /// persisted flag. Available even before `start` (e.g. to gate release-health
    /// reporting). Reflects the most recent processed crash.
    public static var didCrashOnPreviousExecution: Bool {
        UserDefaults(suiteName: DeviceContext.suiteName)?.bool(forKey: crashedLastRunKey) ?? false
    }

    /// UserDefaults key for the persisted previous-run-crashed flag.
    private static let crashedLastRunKey = "bw_crashed_last_run"

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
    private let crashSidecar: CrashContextSidecar
    private let sessionTracker: SessionTracker

    /// `true` when the *previous* run ended in a native crash (set during
    /// `start` while processing the pending artifact). Useful for release-health.
    public private(set) var crashedLastRun: Bool = false

    private let lock = NSLock()
    private var user: BugWatchUser?
    private var tags: [String: String] = [:]
    private var contexts: [String: String] = [:]
    private var release: String?
    private var breadcrumbs: [Breadcrumb] = []

    private var flushTimer: DispatchSourceTimer?

    /// SDK working directory for the queue / crash sidecar / session descriptor.
    /// Defaults to the shared Application-Support namespace; overridable only via
    /// the internal test seam so facade tests run against an isolated directory.
    private let directory: URL

    private init(options: BugWatchOptions, directory: URL? = nil) {
        self.options = options
        self.release = options.release
        let dir = directory ?? CrashContextSidecar.defaultDirectory()
        self.directory = dir
        self.queue = PersistentEventQueue(
            fileURL: dir.appendingPathComponent("pending-events.ndjson", isDirectory: false),
            maxQueueSize: options.maxQueueSize
        )
        self.redactor = Redactor(sensitiveFields: options.sensitiveFields)
        self.device = DeviceContext.collect()
        self.installId = DeviceContext.installId()
        self.sessionId = "bw_s_" + UUID().uuidString.lowercased()
        self.crashSidecar = CrashContextSidecar(directory: dir)
        self.sessionTracker = SessionTracker(directory: dir)

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
        start(options: options, directory: nil)
    }

    /// Internal test seam: like `start(options:)` but pins the SDK working
    /// directory so tests can drive the real boot flow against an isolated queue /
    /// sidecar / session descriptor. Not part of the public SDK surface.
    @discardableResult
    static func start(options: BugWatchOptions, directory: URL?) -> BugWatch {
        if let existing = shared { return existing }
        let instance = BugWatch(options: options, directory: directory)
        shared = instance
        instance.boot()
        instance.log("started (env=\(options.environment), release=\(options.release ?? "-"), session=\(instance.sessionId))")
        return instance
    }

    private func boot() {
        // 1. BEFORE installing handlers: turn any crash from the *previous* run
        //    into a fatal event on the A1 pipe, then drop the artifact. Done
        //    first so a crash-on-launch from re-installing handlers can't shadow
        //    the report we already owe. This also resolves `crashedLastRun` /
        //    `didCrashOnPreviousExecution`, which session finalization (next)
        //    depends on to pick `crashed` vs `exited` for the prior run.
        processPendingCrash()

        // 1b. Release health (A3): finalize the PRIOR run's session, then open
        //     this run's. MUST run after processPendingCrash so the prior
        //     session's terminal status reflects whether that run crashed.
        handleSessionsOnBoot()

        // 2. Write the context sidecar for *this* session so the next launch can
        //    enrich a crash, and start a fresh breadcrumb ring.
        crashSidecar.resetBreadcrumbs()
        writeCrashSidecar()

        // 3. Install crash capture (idempotent) now that A1 is fully initialized.
        if options.enabled {
            CrashReporter.install(directory: directory)
        }

        // Resume delivery as soon as connectivity returns.
        monitor.onBecameOnline = { [weak self] in
            self?.drainAsync()
        }
        monitor.start()
        startFlushTimer()
        // Attempt to deliver anything left over from a previous run (incl. the
        // fatal event just enqueued from a crash).
        drainAsync()
    }

    /// Reads a pending crash artifact (if any), builds a `.fatal` event from it
    /// plus the persisted sidecar context, enqueues it on the A1 pipe, then
    /// deletes the artifact so it can never be double-reported. Best-effort —
    /// never throws into the host.
    private func processPendingCrash() {
        let dir = directory
        let processed = CrashReporter.processPending(
            directory: dir,
            sidecar: crashSidecar,
            sdk: SdkInfo(name: BugWatch.sdkName, version: BugWatch.sdkVersion),
            environmentFallback: options.environment,
            enqueue: { [weak self] event in
                guard let self else { return }
                // A disabled SDK still clears the artifact but uploads nothing.
                guard self.options.enabled else { return }
                let redactedCrumbs = self.redactor.redact(event.breadcrumbs)
                var enriched = event
                enriched.breadcrumbs = redactedCrumbs
                self.queue.enqueue(enriched)
                self.log("recovered fatal crash event \(enriched.eventId) from previous run")
            }
        )
        crashedLastRun = processed
        Self.persistCrashedLastRun(processed)
    }

    /// Release-health session handling at boot (A3). Two phases, in order:
    ///
    /// 1. **Finalize the prior run** — if a persisted session from a previous run
    ///    exists, emit one terminal session event for *its* id with status
    ///    `crashed` when this boot's `processPendingCrash` recovered a crash
    ///    (`crashedLastRun`), else `exited`. Then delete the persisted descriptor
    ///    so it can never be finalized twice. The terminal event carries the
    ///    prior run's release/environment (read from the descriptor), not this
    ///    run's.
    /// 2. **Open this run** — persist this run's descriptor and emit an `ok`
    ///    session event for the current `sessionId`.
    ///
    /// No-op when `autoSessionTracking` is off. Best-effort; never throws into the
    /// host. Must run AFTER `processPendingCrash` (see `boot`).
    private func handleSessionsOnBoot() {
        guard options.autoSessionTracking else { return }
        let context = SessionTracker.BootContext(
            newSessionId: sessionId,
            release: release,
            environment: options.environment,
            device: device,
            installId: installId,
            user: currentUserSnapshot(),
            sdk: SdkInfo(name: BugWatch.sdkName, version: BugWatch.sdkVersion)
        )
        sessionTracker.runBoot(crashedLastRun: crashedLastRun, context: context) { [weak self] event in
            guard let self else { return }
            self.enqueueSessionEvent(event)
            if let s = event.session {
                self.log("session \(s.id) → \(s.status)")
            }
        }
    }

    /// Enqueues a pre-built session event through the normal delivery pipe but
    /// **bypassing sampling** — sessions must never be sampled out or crash-free
    /// rates would be wrong. Still respects `enabled`, redacts the user, and
    /// nudges the worker.
    private func enqueueSessionEvent(_ event: BugWatchEvent) {
        guard options.enabled else { return }
        var enriched = event
        enriched.user = redactor.redact(event.user)
        queue.enqueue(enriched)
        drainAsync()
    }

    /// Thread-safe snapshot of the current scope user (used to stamp session
    /// events with the same user identity as ordinary events).
    private func currentUserSnapshot() -> BugWatchUser? {
        lock.lock(); defer { lock.unlock() }
        return user
    }

    /// Persists the current session context to the crash sidecar so a crash in
    /// this run can be enriched on the next launch.
    private func writeCrashSidecar() {
        let context = CrashContextSidecar.Context(
            installId: installId,
            sessionId: sessionId,
            release: release,
            environment: options.environment,
            device: device,
            startedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
        crashSidecar.writeContext(context)
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
        // Restore the host's previous crash handlers; a clean shutdown is not a
        // crash, so drop the sidecar so it can't mis-enrich a future report.
        CrashReporter.uninstall()
        crashSidecar.clear()
        // Drop the persisted session descriptor too: an explicit close is a clean
        // teardown, so the next launch shouldn't finalize a phantom session for it.
        sessionTracker.clear()
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
        // Keep the crash sidecar's release current so a later crash reports the
        // release that was actually live when it happened.
        writeCrashSidecar()
    }

    public static func addBreadcrumb(_ crumb: Breadcrumb) { shared?.addBreadcrumb(crumb) }
    public func addBreadcrumb(_ crumb: Breadcrumb) {
        lock.lock()
        breadcrumbs.append(crumb)
        if breadcrumbs.count > 100 {
            breadcrumbs.removeFirst(breadcrumbs.count - 100)
        }
        lock.unlock()
        // Mirror into the bounded crash sidecar (best-effort) so a crash carries
        // the trail of what happened just before it. Redact first.
        if let redacted = redactor.redact([crumb])?.first {
            crashSidecar.appendBreadcrumb(redacted)
        }
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

    /// Persists the previous-run-crashed flag so `didCrashOnPreviousExecution`
    /// can report it on subsequent launches.
    private static func persistCrashedLastRun(_ value: Bool) {
        let defaults = UserDefaults(suiteName: DeviceContext.suiteName) ?? .standard
        defaults.set(value, forKey: crashedLastRunKey)
    }
}
