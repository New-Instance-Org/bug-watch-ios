import XCTest
@testable import BugWatch

final class BugWatchSmokeTests: XCTestCase {
    override func tearDown() {
        BugWatch.close()
        super.tearDown()
    }

    func testStartAndCaptureReturnEventIds() {
        let bw = BugWatch.start(options: BugWatchOptions(projectKey: "key:secret", debug: true))
        let messageId = bw.captureMessage("hello", level: .info)
        XCTAssertTrue(messageId.hasPrefix("bw_e_"))

        let errorId = bw.capture(error: NSError(domain: "demo", code: 1))
        XCTAssertTrue(errorId.hasPrefix("bw_e_"))

        bw.setUser(BugWatchUser(id: "u1"))
        bw.setTag(key: "screen", value: "checkout")
        bw.setContext("cart", value: "3 items")
        bw.setRelease("1.0.0+1")
        bw.addBreadcrumb(Breadcrumb(category: "nav", message: "opened checkout"))
        bw.flush()
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
}
