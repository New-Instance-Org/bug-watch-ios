import XCTest
@testable import BugWatch

/// A5 — auto-instrumentation wiring at the `BugWatch` facade level. Verifies the
/// option gating (lifecycle + network install only when their option *and* the
/// master switch are on, and `close()` tears them down) and a real end-to-end pass
/// through the network `URLProtocol`: a recorded request enriches the SDK breadcrumb
/// buffer, while a BugWatch ingest request never does.
///
/// The end-to-end network checks deliberately target `127.0.0.1:1` — a port nothing
/// listens on, so the connection is **refused immediately** (deterministic, fast, no
/// live server, no blackhole-timeout flakiness). A non-excluded host still records a
/// status-less breadcrumb on that failure; an excluded ingest host records nothing
/// because the protocol declines to handle it at all.
final class AutoInstrumentationFacadeTests: XCTestCase {

    override func tearDown() {
        BugWatch.close()
        super.tearDown()
    }

    private func makeOptions(
        enableAutoBreadcrumbs: Bool = true,
        enableNetworkBreadcrumbs: Bool = true,
        enabled: Bool = true,
        endpoint: String = "https://api.newinstance.cloud",
        allowed: [String] = [],
        denied: [String] = []
    ) -> BugWatchOptions {
        BugWatchOptions(
            projectId: "p",
            appSecret: "qHJ80UA2fcTfpi-yiobmScytk-YlkWkAYGPO6DGsvQk",
            endpoint: endpoint,
            enabled: enabled,
            flushIntervalMs: 0,
            autoSessionTracking: false,
            enableAppHangTracking: false,
            enableAutoBreadcrumbs: enableAutoBreadcrumbs,
            enableNetworkBreadcrumbs: enableNetworkBreadcrumbs,
            networkBreadcrumbAllowedHosts: allowed,
            networkBreadcrumbDeniedHosts: denied
        )
    }

    private func freshDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-a5-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Gating

    /// Both instrumentations are armed by default (options on, master on), and
    /// `close()` tears both down.
    func testEnabledInstrumentationArmsAndCloseTearsDown() {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bw = BugWatch.start(options: makeOptions(), directory: dir)
        XCTAssertTrue(bw.isLifecycleInstrumentationActiveForTesting, "lifecycle armed by default")
        XCTAssertTrue(bw.isNetworkInstrumentationActiveForTesting, "network armed by default")

        BugWatch.close()
        XCTAssertFalse(bw.isLifecycleInstrumentationActiveForTesting, "close tears down lifecycle")
        XCTAssertFalse(bw.isNetworkInstrumentationActiveForTesting, "close tears down network")
    }

    /// `enableAutoBreadcrumbs == false` → lifecycle instrumentation is not installed
    /// (network still is, independently).
    func testLifecycleOptionOffSkipsLifecycleOnly() {
        let dir = freshDir()
        defer { BugWatch.close(); try? FileManager.default.removeItem(at: dir) }

        let bw = BugWatch.start(options: makeOptions(enableAutoBreadcrumbs: false), directory: dir)
        XCTAssertFalse(bw.isLifecycleInstrumentationActiveForTesting, "lifecycle off when option off")
        XCTAssertTrue(bw.isNetworkInstrumentationActiveForTesting, "network unaffected")
    }

    /// `enableNetworkBreadcrumbs == false` → network instrumentation is not installed
    /// (lifecycle still is, independently).
    func testNetworkOptionOffSkipsNetworkOnly() {
        let dir = freshDir()
        defer { BugWatch.close(); try? FileManager.default.removeItem(at: dir) }

        let bw = BugWatch.start(options: makeOptions(enableNetworkBreadcrumbs: false), directory: dir)
        XCTAssertFalse(bw.isNetworkInstrumentationActiveForTesting, "network off when option off")
        XCTAssertTrue(bw.isLifecycleInstrumentationActiveForTesting, "lifecycle unaffected")
    }

    /// The master `enabled == false` switch keeps both instrumentations off even with
    /// their own options on.
    func testMasterDisabledKeepsBothOff() {
        let dir = freshDir()
        defer { BugWatch.close(); try? FileManager.default.removeItem(at: dir) }

        let bw = BugWatch.start(options: makeOptions(enabled: false), directory: dir)
        XCTAssertFalse(bw.isLifecycleInstrumentationActiveForTesting)
        XCTAssertFalse(bw.isNetworkInstrumentationActiveForTesting)
    }

    // MARK: - Lifecycle enriches the SDK buffer (every platform)

    /// A lifecycle breadcrumb fed through the instrumentation lands in the same buffer
    /// ordinary events attach (verified via the internal handler so it works on the
    /// macOS host too).
    func testLifecycleBreadcrumbReachesSdkBuffer() {
        let dir = freshDir()
        defer { BugWatch.close(); try? FileManager.default.removeItem(at: dir) }

        let bw = BugWatch.start(options: makeOptions(), directory: dir)
        // Drive the instrumentation's handler directly — equivalent to a UIApplication
        // notification firing, but deterministic on every platform.
        let instrumentation = LifecycleInstrumentation(sink: { bw.addBreadcrumb($0) })
        instrumentation.handle(.didEnterBackground)

        let crumbs = bw.breadcrumbsSnapshotForTesting
        XCTAssertTrue(
            crumbs.contains { $0.category == "app.lifecycle" && $0.data?["event"] == "app.background" },
            "lifecycle breadcrumb should be in the SDK buffer"
        )
    }

    // MARK: - Network end-to-end through the URLProtocol

    /// A recorded (non-excluded) request enriches the SDK breadcrumb buffer with a
    /// `network` crumb. Target is an unreachable blackhole IP so it fails fast; the
    /// failure path still records a status-less breadcrumb.
    func testNetworkRequestAddsBreadcrumbToSdkBuffer() {
        let dir = freshDir()
        defer { BugWatch.close(); try? FileManager.default.removeItem(at: dir) }

        let bw = BugWatch.start(options: makeOptions(), directory: dir)
        XCTAssertTrue(bw.isNetworkInstrumentationActiveForTesting)

        // 127.0.0.1:1 refuses the connection immediately — fails fast, deterministic.
        performRequest(urlString: "http://127.0.0.1:1/v1/widgets", timeoutMs: 2000)

        let crumb = waitForBreadcrumb(in: bw) {
            $0.category == "network" && $0.data?["host"] == "127.0.0.1"
        }
        let recorded = try! XCTUnwrap(crumb, "a network breadcrumb should be recorded for a normal request")
        XCTAssertEqual(recorded.data?["method"], "GET")
        XCTAssertEqual(recorded.data?["path"], "/v1/widgets")
        XCTAssertNotNil(recorded.data?["duration_ms"])
    }

    /// A request to BugWatch's own ingest URL records **no** breadcrumb (the protocol
    /// declines to handle it), preventing recursive telemetry.
    func testBugWatchIngestRequestRecordsNoBreadcrumb() {
        let dir = freshDir()
        defer { BugWatch.close(); try? FileManager.default.removeItem(at: dir) }

        // Point the SDK endpoint at the same refused host so the ingest request we
        // fire matches the configured endpoint host (and the ingest path marker).
        let bw = BugWatch.start(
            options: makeOptions(endpoint: "http://127.0.0.1:1"),
            directory: dir
        )

        performRequest(
            urlString: "http://127.0.0.1:1/api/v1/bugwatch/ingest/mobile",
            timeoutMs: 2000
        )

        // Give any (erroneous) breadcrumb a chance to appear, then assert none did.
        let appeared = waitForBreadcrumb(in: bw, timeout: 2.0) { $0.category == "network" }
        XCTAssertNil(appeared, "BugWatch's own ingest request must not be recorded")
    }

    /// A denied host is not recorded even though the request runs.
    func testDeniedHostRecordsNoBreadcrumb() {
        let dir = freshDir()
        defer { BugWatch.close(); try? FileManager.default.removeItem(at: dir) }

        let bw = BugWatch.start(
            options: makeOptions(denied: ["127.0.0.1"]),
            directory: dir
        )
        performRequest(urlString: "http://127.0.0.1:1/blocked", timeoutMs: 2000)

        let appeared = waitForBreadcrumb(in: bw, timeout: 2.0) { $0.category == "network" }
        XCTAssertNil(appeared, "denied host must not be recorded")
    }

    // MARK: - Helpers

    /// Fires a request through `URLSession.shared` (which the installed protocol
    /// observes) and waits for it to complete (success or failure).
    private func performRequest(urlString: String, timeoutMs: Int) {
        guard let url = URL(string: urlString) else {
            XCTFail("bad url \(urlString)"); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Double(timeoutMs) / 1000.0
        let done = expectation(description: "request finished \(urlString)")
        let task = URLSession.shared.dataTask(with: request) { _, _, _ in
            done.fulfill()
        }
        task.resume()
        wait(for: [done], timeout: Double(timeoutMs) / 1000.0 + 5)
    }

    /// Polls the SDK breadcrumb buffer until `predicate` matches or the timeout
    /// elapses, returning the first matching breadcrumb (or nil).
    private func waitForBreadcrumb(
        in bw: BugWatch,
        timeout: TimeInterval = 5.0,
        where predicate: (Breadcrumb) -> Bool
    ) -> Breadcrumb? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = bw.breadcrumbsSnapshotForTesting.first(where: predicate) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return bw.breadcrumbsSnapshotForTesting.first(where: predicate)
    }
}
