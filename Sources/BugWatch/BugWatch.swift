import Foundation

/// BugWatch — crash, error, and log observability for iOS.
///
/// Public entry point. In this skeleton the capture methods normalize an event
/// and enqueue it into an in-memory bounded queue (emitting a diagnostic line
/// when `debug` is on). Real delivery, crash handling, device collection, and
/// session tracking arrive in later milestones.
public final class BugWatch {
    /// The shared instance created by `start(options:)`, if any.
    public private(set) static var shared: BugWatch?

    public static let sdkName = "bugwatch-ios"
    public static let sdkVersion = "0.1.0"

    private let options: BugWatchOptions
    private let queue: EventQueue
    private let monitor = NetworkMonitor()
    private let lock = NSLock()
    private var user: BugWatchUser?
    private var tags: [String: String] = [:]
    private var contexts: [String: String] = [:]
    private var release: String?
    private var breadcrumbs: [Breadcrumb] = []

    private init(options: BugWatchOptions) {
        self.options = options
        self.queue = EventQueue(maxSize: options.maxQueueSize)
        self.release = options.release
    }

    // MARK: Lifecycle

    /// Starts the SDK. Idempotent — subsequent calls return the existing
    /// instance without reconfiguring.
    @discardableResult
    public static func start(options: BugWatchOptions) -> BugWatch {
        if let existing = shared { return existing }
        let instance = BugWatch(options: options)
        shared = instance
        instance.monitor.start()
        instance.log("started (env=\(options.environment ?? "-"), release=\(options.release ?? "-"))")
        return instance
    }

    /// Stops the SDK and tears down the shared instance.
    public static func close() {
        shared?.closeInstance()
        shared = nil
    }

    private func closeInstance() {
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

    // MARK: Delivery (stub)

    /// Drains pending events. In this skeleton there is no network I/O — the
    /// queue is emptied and a diagnostic line is logged. Real delivery arrives
    /// in a later milestone.
    public static func flush() { shared?.flush() }
    public func flush() {
        let batch = queue.dequeue(upTo: options.batchSize)
        if !batch.isEmpty {
            log("flush drained \(batch.count) queued event(s) — delivery not yet implemented")
        }
    }

    // MARK: Internals

    @discardableResult
    private func enqueue(level: Severity, message: String?, exception: NormalizedException?) -> String {
        let id = "bw_e_" + UUID().uuidString.lowercased()
        guard options.enabled else { return id }

        lock.lock()
        let snapshotUser = user
        let snapshotTags = tags.isEmpty ? nil : tags
        let snapshotRelease = release
        let snapshotCrumbs = breadcrumbs.isEmpty ? nil : breadcrumbs
        lock.unlock()

        let event = BugWatchEvent(
            eventId: id,
            time: Int64(Date().timeIntervalSince1970 * 1000),
            level: level.rawValue,
            message: message,
            exception: exception,
            release: snapshotRelease,
            environment: options.environment,
            tags: snapshotTags,
            user: snapshotUser,
            breadcrumbs: snapshotCrumbs,
            sdk: SdkInfo(name: BugWatch.sdkName, version: BugWatch.sdkVersion)
        )
        queue.enqueue(event)
        log("captured \(level) event \(id) (queued=\(queue.count))")
        return id
    }

    private func log(_ line: String) {
        guard options.debug else { return }
        BugWatchDiagnosticLog.emit("[BugWatch] \(line)")
    }
}
