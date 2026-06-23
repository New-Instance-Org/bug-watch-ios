import XCTest
@testable import BugWatch

/// Wrapper-exception entry point (used by the React Native / Flutter wrappers).
/// `captureWrapperException` lets a wrapper submit a PRE-BUILT exception — with
/// its own stacktrace and its own `platform` tag — through the normal native
/// delivery pipe. These tests assert the enqueued event carries the supplied
/// exception (type / value / frames) and that the `platform` override wins over
/// this SDK's default `"ios"`.
final class WrapperExceptionTests: XCTestCase {

    override func tearDown() {
        BugWatch.close()
        super.tearDown()
    }

    private func freshDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-wrapper-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeOptions(endpoint: String = "http://127.0.0.1:1") -> BugWatchOptions {
        BugWatchOptions(
            projectId: "p",
            appSecret: "qHJ80UA2fcTfpi-yiobmScytk-YlkWkAYGPO6DGsvQk",
            // Unreachable port → delivery fails fast (retryable) and never blocks
            // the test; we only assert the capture/enqueue path.
            endpoint: endpoint,
            flushIntervalMs: 0,
            autoSessionTracking: false,
            enableAppHangTracking: false,
            enableAutoBreadcrumbs: false,
            enableNetworkBreadcrumbs: false
        )
    }

    /// Reads the oldest enqueued event back off the on-disk queue file in the
    /// pinned directory and decodes it as a `BugWatchEvent`.
    private func firstQueuedEvent(in dir: URL) throws -> BugWatchEvent {
        let url = dir.appendingPathComponent("pending-events.ndjson", isDirectory: false)
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(
            text.split(separator: "\n").first.map(String.init),
            "queue file had no event line"
        )
        return try JSONDecoder().decode(BugWatchEvent.self, from: Data(line.utf8))
    }

    func testCaptureWrapperExceptionEnqueuesGivenExceptionAndPlatform() throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bw = BugWatch.start(options: makeOptions(), directory: dir)

        let frames: [[String: Any]] = [
            [
                "filename": "app:///src/screens/Checkout.tsx",
                "function": "onPressPay",
                "lineno": 128,
                "colno": 42,
                "in_app": true,
            ],
            [
                "filename": "node_modules/react-native/Libraries/Renderer.js",
                "function": "commitRoot",
                "lineno": 9,
                "colno": 1,
                "in_app": false,
            ],
        ]

        let id = bw.captureWrapperException(
            type: "TypeError",
            value: "undefined is not a function",
            frames: frames,
            level: .error,
            platform: "react-native"
        )
        XCTAssertTrue(id.hasPrefix("bw_e_"))

        let event = try firstQueuedEvent(in: dir)

        // platform override wins over the SDK default "ios".
        XCTAssertEqual(event.platform, "react-native")
        XCTAssertEqual(event.level, Severity.error.rawValue)

        let exception = try XCTUnwrap(event.exception)
        XCTAssertEqual(exception.type, "TypeError")
        XCTAssertEqual(exception.value, "undefined is not a function")

        let stack = try XCTUnwrap(exception.stacktrace)
        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(stack[0].filename, "app:///src/screens/Checkout.tsx")
        XCTAssertEqual(stack[0].function, "onPressPay")
        XCTAssertEqual(stack[0].lineno, 128)
        XCTAssertEqual(stack[0].colno, 42)
        XCTAssertEqual(stack[0].inApp, true)
        XCTAssertEqual(stack[1].filename, "node_modules/react-native/Libraries/Renderer.js")
        XCTAssertEqual(stack[1].inApp, false)
    }

    /// A static forwarder is a safe no-op before `start`.
    func testStaticForwarderIsNoOpBeforeStart() {
        XCTAssertNil(
            BugWatch.captureWrapperException(
                type: "X", value: "y", frames: [], platform: "react-native"
            )
        )
    }
}
