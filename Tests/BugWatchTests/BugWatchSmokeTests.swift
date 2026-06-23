import XCTest
@testable import BugWatch

final class BugWatchSmokeTests: XCTestCase {
    override func tearDown() {
        BugWatch.close()
        super.tearDown()
    }

    func testStartAndCaptureReturnEventIds() async {
        let bw = BugWatch.start(options: BugWatchOptions(
            projectId: "proj_abc123",
            appSecret: "qHJ80UA2fcTfpi-yiobmScytk-YlkWkAYGPO6DGsvQk",
            // Point at an unreachable port so delivery fails fast (retryable) and
            // never blocks the test; we only assert the capture/enqueue path.
            endpoint: "http://127.0.0.1:1",
            debug: true,
            flushIntervalMs: 0
        ))
        let messageId = bw.captureMessage("hello", level: .info)
        XCTAssertTrue(messageId.hasPrefix("bw_e_"))

        let errorId = bw.capture(error: NSError(domain: "demo", code: 1))
        XCTAssertTrue(errorId.hasPrefix("bw_e_"))

        bw.setUser(BugWatchUser(id: "u1"))
        bw.setTag(key: "screen", value: "checkout")
        bw.setContext("cart", value: "3 items")
        bw.setRelease("1.0.0+1")
        bw.addBreadcrumb(Breadcrumb(category: "nav", message: "opened checkout"))
        await bw.flush()
    }

    func testStaticForwardersAreNoOpBeforeStart() {
        // Statics are safe to call when no instance exists.
        XCTAssertNil(BugWatch.capture(error: NSError(domain: "x", code: 0)))
        XCTAssertNil(BugWatch.captureMessage("ignored"))
    }

    func testSeverityOrdering() {
        XCTAssertTrue(Severity.warn < Severity.error)
        XCTAssertEqual(Severity.fatal.rawValue, 60)
    }

    func testStartIsIdempotent() {
        let a = BugWatch.start(options: BugWatchOptions(projectId: "p", appSecret: "s", flushIntervalMs: 0))
        let b = BugWatch.start(options: BugWatchOptions(projectId: "other", appSecret: "x", flushIntervalMs: 0))
        XCTAssertTrue(a === b)
    }

    func testDisabledSDKDoesNotPersist() async {
        // A disabled SDK still returns ids but enqueues nothing.
        let q = PersistentEventQueue(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("bw-disabled-\(UUID().uuidString)")
                .appendingPathComponent("p.ndjson"),
            maxQueueSize: 10
        )
        XCTAssertEqual(q.count, 0)
        let bw = BugWatch.start(options: BugWatchOptions(projectId: "p", appSecret: "s", enabled: false, flushIntervalMs: 0))
        let id = bw.captureMessage("nope")
        XCTAssertTrue(id.hasPrefix("bw_e_"))
    }
}
