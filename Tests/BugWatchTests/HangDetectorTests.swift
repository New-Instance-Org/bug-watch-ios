import XCTest
@testable import BugWatch

/// A4 — main-thread app-hang detection. Drives `HangDetector` through its
/// dependency-injection seam so the watchdog loop is fully deterministic: a fake
/// clock we advance by hand, a fake "schedule clear on main" we can *withhold*
/// (simulating a stalled main thread) or run (a healthy one), and a no-op
/// next-tick scheduler so we step the loop by calling `tick()` directly — no real
/// thread is ever blocked for seconds.
final class HangDetectorTests: XCTestCase {

    /// A controllable test harness around a `HangDetector`.
    private final class Harness {
        /// Simulated wall clock (seconds). Advance with `advance(ms:)`.
        private(set) var clock: TimeInterval = 1_000.0
        /// Pending "clear on main" blocks. We choose if/when to run them: leaving
        /// them un-run models a blocked main thread.
        private var pendingMainBlocks: [() -> Void] = []
        /// Captured emitted hang events.
        private(set) var emitted: [BugWatchEvent] = []

        let detector: HangDetector

        init(thresholdMs: Int = 2000, pollIntervalMs: Int = 500) {
            // `weak`-free: harness outlives the detector within each test.
            var box: Harness?
            let meta = HangDetector.EventMeta(
                release: "1.0.0+test",
                environment: "staging",
                device: DeviceInfo(model: "iPhone15,2"),
                installId: "install-1",
                sessionId: "bw_s_test",
                user: BugWatchUser(id: "u-1"),
                sdk: SdkInfo(name: BugWatch.sdkName, version: BugWatch.sdkVersion)
            )
            self.detector = HangDetector(
                thresholdMs: thresholdMs,
                pollIntervalMs: pollIntervalMs,
                now: { box?.clock ?? 0 },
                scheduleMainClear: { block in box?.pendingMainBlocks.append(block) },
                scheduleNextTick: { _ in /* no-op: tests step via tick() */ },
                metaFactory: { meta },
                emit: { box?.emitted.append($0) }
            )
            box = self
        }

        /// Advances the simulated clock.
        func advance(ms: Int) { clock += TimeInterval(ms) / 1000.0 }

        /// Runs all queued "clear on main" blocks — models a responsive main
        /// thread servicing the watchdog ping.
        func mainResponds() {
            let blocks = pendingMainBlocks
            pendingMainBlocks = []
            blocks.forEach { $0() }
        }

        /// Drops all queued "clear on main" blocks without running them — models a
        /// main thread that stays blocked (the ping is never serviced).
        func mainStaysBlocked() { /* intentionally leave pendingMainBlocks intact */ }

        var hangEvents: [BugWatchEvent] {
            emitted.filter { $0.exception?.type == HangDetector.exceptionType }
        }
    }

    // MARK: - Hang detected after a stall beyond threshold

    /// When the "clear on main" block is never run (stalled main thread) and the
    /// clock advances past the threshold, exactly one `AppHang` event is emitted —
    /// `.error` level, with the duration tag.
    func testEmitsOneHangEventWhenMainStallsBeyondThreshold() {
        let h = Harness(thresholdMs: 2000, pollIntervalMs: 500)
        h.detector.start()

        // Tick 1: no outstanding ping → raises a ping + schedules a main-clear.
        h.detector.tick()
        // Main thread is blocked: we never run the clear.
        h.mainStaysBlocked()

        // Time passes beyond the threshold while main stays blocked.
        h.advance(ms: 2500)

        // Tick 2: the ping is still outstanding for 2500ms ≥ 2000 → emit once.
        h.detector.tick()

        XCTAssertEqual(h.hangEvents.count, 1, "exactly one hang event for the stall")
        let event = try! XCTUnwrap(h.hangEvents.first)
        XCTAssertEqual(event.exception?.type, "AppHang")
        XCTAssertEqual(event.level, Severity.error.rawValue, "hangs are non-fatal errors")
        XCTAssertEqual(event.platform, "ios")
        XCTAssertEqual(event.tags?["hang.threshold_ms"], "2000")
        // Duration tag is present and reflects the measured stall (≥ threshold).
        let duration = try! XCTUnwrap(event.tags?["hang.duration_ms"].flatMap { Int($0) })
        XCTAssertGreaterThanOrEqual(duration, 2000)
        XCTAssertEqual(duration, 2500)
        // No stacktrace is attached (background watchdog can't see main's stack).
        XCTAssertNil(event.exception?.stacktrace)
    }

    // MARK: - No event when the main thread responds within threshold

    /// When the main thread services the ping (clear runs) before the threshold
    /// elapses, no hang is reported, even across many ticks.
    func testNoEventWhenMainRespondsWithinThreshold() {
        let h = Harness(thresholdMs: 2000, pollIntervalMs: 500)
        h.detector.start()

        for _ in 0..<10 {
            h.detector.tick()       // raise a ping
            h.advance(ms: 500)      // a little time passes (< threshold)
            h.mainResponds()        // main services the ping promptly
        }

        XCTAssertTrue(h.hangEvents.isEmpty, "no hang while the main thread stays responsive")
    }

    /// A stall that never quite reaches the threshold does not fire.
    func testNoEventWhenStallStaysBelowThreshold() {
        let h = Harness(thresholdMs: 2000, pollIntervalMs: 500)
        h.detector.start()

        h.detector.tick()           // raise a ping
        h.mainStaysBlocked()
        h.advance(ms: 1999)         // just under the threshold
        h.detector.tick()           // outstanding 1999ms < 2000 → no emit

        XCTAssertTrue(h.hangEvents.isEmpty, "1999ms < 2000ms threshold → no hang")
    }

    // MARK: - No duplicate event for one continuous hang

    /// A single continuous hang spanning many ticks emits exactly one event — the
    /// `inHang` latch suppresses duplicates until the main thread recovers.
    func testNoDuplicateEventForOneContinuousHang() {
        let h = Harness(thresholdMs: 2000, pollIntervalMs: 500)
        h.detector.start()

        h.detector.tick()           // raise a ping
        h.mainStaysBlocked()        // main is wedged for the whole stretch

        // Many ticks pass while the same ping stays outstanding, well past
        // threshold each time.
        h.advance(ms: 2500)
        h.detector.tick()           // → emit (1st and only)
        for _ in 0..<5 {
            h.advance(ms: 1000)
            h.detector.tick()       // still the same outstanding ping → no re-emit
        }

        XCTAssertEqual(h.hangEvents.count, 1, "one continuous hang ⇒ one event")
    }

    /// After a hang is reported AND the main thread recovers, a *new* subsequent
    /// hang reports again (the latch resets on recovery).
    func testSecondHangAfterRecoveryEmitsAgain() {
        let h = Harness(thresholdMs: 2000, pollIntervalMs: 500)
        h.detector.start()

        // First hang.
        h.detector.tick()
        h.mainStaysBlocked()
        h.advance(ms: 2500)
        h.detector.tick()           // emit #1
        XCTAssertEqual(h.hangEvents.count, 1)

        // Recovery: main finally services the (stale) ping.
        h.mainResponds()
        h.detector.tick()           // sees no outstanding ping → healthy, latch reset
        h.mainResponds()

        // Second, independent hang.
        h.detector.tick()           // raise a fresh ping
        h.mainStaysBlocked()
        h.advance(ms: 3000)
        h.detector.tick()           // emit #2

        XCTAssertEqual(h.hangEvents.count, 2, "a new hang after recovery is reported")
    }

    // MARK: - Option gating (facade)

    /// `enableAppHangTracking == false` → no detector is armed (asserted through
    /// the internal test seam over the real boot flow).
    func testDisabledHangTrackingNeverStartsDetector() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-hang-\(UUID().uuidString)", isDirectory: true)
        defer { BugWatch.close(); try? FileManager.default.removeItem(at: dir) }

        let bw = BugWatch.start(options: hangOptions(enableAppHangTracking: false), directory: dir)
        XCTAssertFalse(bw.isHangDetectorActiveForTesting, "detector must not start when option is off")
    }

    /// `enableAppHangTracking == true` (default) → the detector IS armed after
    /// boot, and `close()` tears it down.
    func testEnabledHangTrackingArmsDetectorAndCloseTearsItDown() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-hang-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bw = BugWatch.start(options: hangOptions(enableAppHangTracking: true), directory: dir)
        XCTAssertTrue(bw.isHangDetectorActiveForTesting, "detector armed when option is on")
        BugWatch.close()
        XCTAssertFalse(bw.isHangDetectorActiveForTesting, "close() stops + drops the detector")
    }

    /// The master `enabled == false` switch also keeps the hang detector off, even
    /// with `enableAppHangTracking` on.
    func testMasterDisabledKeepsHangDetectorOff() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-hang-\(UUID().uuidString)", isDirectory: true)
        defer { BugWatch.close(); try? FileManager.default.removeItem(at: dir) }

        var opts = hangOptions(enableAppHangTracking: true)
        opts.enabled = false
        let bw = BugWatch.start(options: opts, directory: dir)
        XCTAssertFalse(bw.isHangDetectorActiveForTesting, "master kill-switch gates hang tracking too")
    }

    private func hangOptions(enableAppHangTracking: Bool) -> BugWatchOptions {
        BugWatchOptions(
            projectId: "p",
            appSecret: "qHJ80UA2fcTfpi-yiobmScytk-YlkWkAYGPO6DGsvQk",
            endpoint: "http://10.255.255.1:9",
            flushIntervalMs: 0,
            autoSessionTracking: false,
            enableAppHangTracking: enableAppHangTracking
        )
    }

    // MARK: - Event builder (pure)

    /// The builder stamps a non-fatal `AppHang` with the threshold-naming value,
    /// the duration/threshold tags, ios platform, and no stacktrace.
    func testBuildHangEventShape() {
        let meta = HangDetector.EventMeta(
            release: "9.9.9",
            environment: "production",
            device: DeviceInfo(model: "iPhone15,2"),
            installId: "i-1",
            sessionId: "bw_s_9",
            user: BugWatchUser(id: "u-9"),
            sdk: SdkInfo(name: BugWatch.sdkName, version: BugWatch.sdkVersion)
        )
        let event = HangDetector.buildHangEvent(durationMs: 3200, thresholdMs: 2000, meta: meta)

        XCTAssertEqual(event.exception?.type, "AppHang")
        XCTAssertEqual(event.exception?.value, "Main thread unresponsive for ≥2000ms")
        XCTAssertNil(event.exception?.stacktrace, "main-thread stack is deferred")
        XCTAssertEqual(event.level, Severity.error.rawValue)
        XCTAssertEqual(event.tags?["hang.duration_ms"], "3200")
        XCTAssertEqual(event.tags?["hang.threshold_ms"], "2000")
        XCTAssertEqual(event.platform, "ios")
        XCTAssertEqual(event.release, "9.9.9")
        XCTAssertEqual(event.environment, "production")
        XCTAssertEqual(event.installId, "i-1")
        XCTAssertEqual(event.sessionId, "bw_s_9")
        XCTAssertEqual(event.user?.id, "u-9")
        XCTAssertEqual(event.device?.model, "iPhone15,2")
        XCTAssertTrue(event.eventId.hasPrefix("bw_e_"))
    }
}
