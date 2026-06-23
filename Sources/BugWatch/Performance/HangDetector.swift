import Foundation

/// App-hang (main-thread stall) detection — A4.
///
/// Detects when the **main thread** stops servicing work for longer than a
/// threshold and emits ONE non-fatal hang event through the SDK's existing
/// enqueue → deliver pipe. A hang is *not* a crash: the app keeps running, so
/// unlike A2 crash capture this produces an `.error` event (not `.fatal`) and the
/// process is never terminated by us.
///
/// ## How it works
/// A watchdog loop runs on a dedicated background queue (never the main thread).
/// On each tick it raises an atomic `pendingPing` flag and asks the main thread to
/// clear it (`DispatchQueue.main.async { … }`). When the main thread is healthy it
/// drains that block quickly and the flag is already clear by the next tick. When
/// the main thread is blocked, the block sits in its queue undelivered and the flag
/// stays raised. Once the flag has been continuously raised for ≥ `thresholdMs`,
/// a hang is in progress and we emit exactly one event for it. The hang "latch"
/// (`inHang`) prevents duplicate events for one continuous stall — it only resets
/// once the main thread services a ping again (i.e. recovers).
///
/// ## Main-thread stack limitation (read this)
/// We deliberately do **not** attach a stack trace. The watchdog runs on a
/// background queue, so `Thread.callStackSymbols` here would capture the *watchdog's*
/// frames, not the suspended main thread's — attaching that would be actively
/// misleading. Capturing the *real* blocked main-thread backtrace requires
/// suspending it and walking its registers/stack via the Mach `thread_suspend` /
/// `thread_get_state` / unwind APIs, which is out of scope for this MVP and is
/// deferred. We therefore attach only a clear watchdog note plus `hang.threshold_ms`
/// / `hang.duration_ms` tags, and we never claim this is a watchdog/OS termination
/// (it isn't — it's our own cooperative detector).
///
/// ## Testability seam
/// All wall-clock and scheduling dependencies are injected so the loop is fully
/// deterministic without ever blocking a real thread for seconds:
///   - `now` — the clock. Production passes `Date().timeIntervalSince1970`; tests
///     pass a mutable closure they advance by hand.
///   - `scheduleMainClear` — "schedule the flag-clear on the main thread".
///     Production passes `DispatchQueue.main.async`; tests pass a fake that can
///     *withhold* the clear (simulating a stalled main thread) or run it (healthy).
///   - `scheduleNextTick` — drives the loop cadence. Production reschedules itself
///     on the watchdog queue after `pollInterval`; tests pass a no-op and call
///     `tick()` directly, stepping the simulated clock between calls.
///
/// `start()` / `stop()` are idempotent and cheap; nothing here can crash the host.
final class HangDetector {
    /// Emits a fully-built hang event into the delivery pipe. Supplied by the SDK
    /// facade (`BugWatch`), mirroring the `enqueue` closures used by A1/A3 so this
    /// type stays free of any queue/sampling/redaction concern.
    typealias Emit = (BugWatchEvent) -> Void

    /// Wire-level exception type for a detected app hang.
    static let exceptionType = "AppHang"

    private let thresholdMs: Int
    private let pollInterval: TimeInterval
    private let now: () -> TimeInterval
    private let scheduleMainClear: (@escaping () -> Void) -> Void
    private let scheduleNextTick: (@escaping () -> Void) -> Void
    private let emit: Emit
    private let metaFactory: () -> EventMeta

    /// Static identity/context stamped onto the emitted event (release, env,
    /// device, ids, …). Captured fresh at emit time via `metaFactory` so it tracks
    /// the live scope (e.g. a `setRelease` after start).
    struct EventMeta {
        var release: String?
        var environment: String
        var device: DeviceInfo?
        var installId: String?
        var sessionId: String?
        var user: BugWatchUser?
        var sdk: SdkInfo
    }

    // MARK: State (only ever touched on the watchdog queue / under `lock` for the
    // cross-thread `pendingPing` flag the main thread clears).

    private let lock = NSLock()
    /// Raised by the watchdog on each tick; cleared by the main thread when it
    /// services the scheduled block. The one piece of cross-thread state.
    private var pendingPing = false
    /// Wall-clock time the current outstanding ping was raised (to measure how
    /// long the main thread has been unresponsive).
    private var pingRaisedAt: TimeInterval = 0
    /// Latches once we've emitted for the current continuous hang; reset only when
    /// the main thread responds again. Prevents duplicate events per hang.
    private var inHang = false
    private var running = false

    /// Default production watchdog queue. Background, low priority — cheap.
    private let watchdogQueue = DispatchQueue(
        label: "cloud.newinstance.bugwatch.hang", qos: .utility
    )

    /// Designated initializer with full dependency injection (used by tests).
    ///
    /// - Parameters:
    ///   - thresholdMs: stall duration that counts as a hang (default 2000).
    ///   - pollIntervalMs: how often the watchdog pings the main thread (default 500).
    ///   - now: clock source (seconds). Inject a fake to control time in tests.
    ///   - scheduleMainClear: schedules the flag-clear "on main". Inject a fake to
    ///     simulate a stalled (never runs it) or healthy (runs it) main thread.
    ///   - scheduleNextTick: schedules the next loop tick. Inject a no-op + call
    ///     `tick()` manually for deterministic stepping.
    ///   - metaFactory: produces the static event context at emit time.
    ///   - emit: receives the built hang event.
    init(
        thresholdMs: Int = 2000,
        pollIntervalMs: Int = 500,
        now: @escaping () -> TimeInterval,
        scheduleMainClear: @escaping (@escaping () -> Void) -> Void,
        scheduleNextTick: @escaping (@escaping () -> Void) -> Void,
        metaFactory: @escaping () -> EventMeta,
        emit: @escaping Emit
    ) {
        self.thresholdMs = max(1, thresholdMs)
        self.pollInterval = TimeInterval(max(1, pollIntervalMs)) / 1000.0
        self.now = now
        self.scheduleMainClear = scheduleMainClear
        self.scheduleNextTick = scheduleNextTick
        self.metaFactory = metaFactory
        self.emit = emit
    }

    /// Production convenience initializer: real clock, real main-queue scheduling,
    /// and a self-rescheduling watchdog-queue loop.
    convenience init(
        thresholdMs: Int = 2000,
        pollIntervalMs: Int = 500,
        metaFactory: @escaping () -> EventMeta,
        emit: @escaping Emit
    ) {
        // Forward-declared so `scheduleNextTick` can reschedule onto the same
        // queue this instance owns.
        var detector: HangDetector!
        self.init(
            thresholdMs: thresholdMs,
            pollIntervalMs: pollIntervalMs,
            now: { Date().timeIntervalSince1970 },
            scheduleMainClear: { block in DispatchQueue.main.async(execute: block) },
            scheduleNextTick: { block in
                let interval = detector?.pollInterval ?? 0.5
                (detector?.watchdogQueue ?? DispatchQueue.global(qos: .utility))
                    .asyncAfter(deadline: .now() + interval, execute: block)
            },
            metaFactory: metaFactory,
            emit: emit
        )
        detector = self
    }

    // MARK: Lifecycle

    /// Begins watching. Idempotent. The first tick is scheduled on the watchdog
    /// queue so this returns immediately and never runs on the caller's (main)
    /// thread.
    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        pendingPing = false
        inHang = false
        lock.unlock()

        // Kick the loop off the calling thread.
        watchdogQueue.async { [weak self] in
            self?.tick()
        }
    }

    /// Stops watching. Idempotent. Any already-scheduled tick observes `running ==
    /// false` and bails without rescheduling.
    func stop() {
        lock.lock()
        running = false
        pendingPing = false
        inHang = false
        lock.unlock()
    }

    // MARK: Watchdog tick (the unit under test)

    /// One iteration of the watchdog loop. Synchronous and side-effect-scoped so a
    /// test can call it directly between manual clock steps.
    ///
    /// Order each tick:
    ///  1. If a previous ping is still outstanding, measure how long — if it has
    ///     been ≥ threshold and we haven't already reported this hang, emit once.
    ///     (We do *not* clear the latch here; it clears only on recovery.)
    ///  2. If no ping is outstanding (main responded since last tick, or first
    ///     tick), the main thread is healthy: clear the hang latch, then raise a
    ///     fresh ping and ask the main thread to clear it.
    ///  3. Reschedule the next tick (unless stopped).
    func tick() {
        lock.lock()
        guard running else { lock.unlock(); return }

        if pendingPing {
            // A ping is still outstanding → main thread hasn't serviced it.
            let elapsedMs = Int((now() - pingRaisedAt) * 1000.0)
            if elapsedMs >= thresholdMs && !inHang {
                inHang = true
                let durationMs = elapsedMs
                lock.unlock()
                emitHang(durationMs: durationMs)
                scheduleNextTickIfRunning()
                return
            }
            // Either below threshold, or already reported this continuous hang —
            // leave the outstanding ping in place and wait.
            lock.unlock()
            scheduleNextTickIfRunning()
            return
        }

        // No outstanding ping → the main thread serviced the last one (or this is
        // the first tick). It's responsive, so the previous hang (if any) is over.
        inHang = false
        pendingPing = true
        pingRaisedAt = now()
        lock.unlock()

        // Ask the main thread to clear the flag. If main is blocked this block is
        // never delivered and the flag stays raised → detected on a later tick.
        scheduleMainClear { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingPing = false
            self.lock.unlock()
        }

        scheduleNextTickIfRunning()
    }

    // MARK: Internals

    private func scheduleNextTickIfRunning() {
        lock.lock()
        let go = running
        lock.unlock()
        guard go else { return }
        scheduleNextTick { [weak self] in
            self?.tick()
        }
    }

    /// Builds and emits the single hang event for the current stall.
    private func emitHang(durationMs: Int) {
        let meta = metaFactory()
        let event = HangDetector.buildHangEvent(
            durationMs: durationMs,
            thresholdMs: thresholdMs,
            meta: meta
        )
        emit(event)
    }

    /// Builds the hang `BugWatchEvent` — pure (no I/O / no clock dependency beyond
    /// the injected `now` used by the caller), so it's trivially unit-testable.
    ///
    /// `level = .error` (non-fatal), exception type `AppHang`, value naming the
    /// threshold, plus `hang.duration_ms` / `hang.threshold_ms` tags and a
    /// `platform: "ios"` stamp. No stacktrace (see the type doc on why).
    static func buildHangEvent(
        durationMs: Int,
        thresholdMs: Int,
        meta: EventMeta,
        now: Date = Date()
    ) -> BugWatchEvent {
        let exception = NormalizedException(
            type: HangDetector.exceptionType,
            value: "Main thread unresponsive for ≥\(thresholdMs)ms",
            // Deferred: real blocked-main-thread backtrace via Mach thread APIs.
            stacktrace: nil
        )
        var tags: [String: String] = [
            "hang.duration_ms": String(durationMs),
            "hang.threshold_ms": String(thresholdMs),
        ]
        // A note that makes the limitation explicit in the payload itself, so a
        // reader never mistakes the absent stack for a watchdog/OS termination.
        tags["hang.detector"] = "bugwatch-cooperative-watchdog"

        return BugWatchEvent(
            eventId: "bw_e_" + UUID().uuidString.lowercased(),
            time: Int64(now.timeIntervalSince1970 * 1000),
            level: Severity.error.rawValue,
            message: "Application not responding (main thread blocked)",
            exception: exception,
            release: meta.release,
            environment: meta.environment,
            tags: tags,
            user: meta.user,
            breadcrumbs: nil,
            sdk: meta.sdk,
            platform: "ios",
            installId: meta.installId,
            sessionId: meta.sessionId,
            device: meta.device
        )
    }
}
