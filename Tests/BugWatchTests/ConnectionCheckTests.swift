import XCTest
@testable import BugWatch

final class ConnectionCheckTests: XCTestCase {
    private func makeTransport(sink: TransportOutcomeSink = TransportOutcomeSink()) -> HttpTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return HttpTransport(endpoint: "https://api.example.test/", requestTimeoutMs: 5000, session: session, outcomeSink: sink)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testHelloConnectedCarriesServerTimeAndPostsIdentity() async {
        let serverTime = Int64(Date().timeIntervalSince1970 * 1000) + 1500
        MockURLProtocol.statusCode = 200
        MockURLProtocol.responseBody = Data("{\"ok\":true,\"projectId\":\"bwp_x\",\"env\":\"production\",\"serverTimeMs\":\(serverTime)}".utf8)
        let check = await makeTransport().hello(token: "tok", body: Data("{\"platform\":\"ios\"}".utf8))
        XCTAssertEqual(check.state, .connected)
        XCTAssertEqual(check.httpStatus, 200)
        XCTAssertEqual(check.serverTimeMs, serverTime)
        XCTAssertNotNil(check.clockSkewMs)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/bugwatch/ingest/mobile/hello")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-bugwatch-token"), "tok")
        XCTAssertEqual(MockURLProtocol.lastBody, Data("{\"platform\":\"ios\"}".utf8))
    }

    func testHelloRejectedCarriesReasonAndHint() async {
        MockURLProtocol.statusCode = 401
        MockURLProtocol.responseBody = Data("{\"error\":\"invalid or expired token\",\"reason\":\"signature_invalid\",\"hint\":\"Copy the current secret.\"}".utf8)
        let check = await makeTransport().hello(token: "tok", body: Data())
        XCTAssertEqual(check.state, .rejected)
        XCTAssertEqual(check.httpStatus, 401)
        XCTAssertEqual(check.reason, "signature_invalid")
        XCTAssertEqual(check.hint, "Copy the current secret.")
    }

    func testHelloServerErrorAndRateLimitAreDisconnectedNotRejected() async {
        MockURLProtocol.statusCode = 503
        let a = await makeTransport().hello(token: "tok", body: Data())
        XCTAssertEqual(a.state, .disconnected)
        MockURLProtocol.statusCode = 429
        let b = await makeTransport().hello(token: "tok", body: Data())
        XCTAssertEqual(b.state, .disconnected)
        XCTAssertEqual(b.reason, "rate_limited")
    }

    func testHelloNetworkFailureIsOffline() async {
        MockURLProtocol.error = URLError(.notConnectedToInternet)
        let check = await makeTransport().hello(token: "tok", body: Data())
        XCTAssertEqual(check.state, .offline)
        XCTAssertEqual(check.reason, "unreachable")
    }

    func testSendSurfacesRejectionReasonThroughSink() async {
        MockURLProtocol.statusCode = 401
        MockURLProtocol.responseBody = Data("{\"reason\":\"token_expired\",\"hint\":\"Device clock is behind.\"}".utf8)
        let sink = TransportOutcomeSink()
        let box = OutcomeBox()
        sink.handler = { outcome in box.set(outcome) }
        let result = await makeTransport(sink: sink).send(ndjsonBody: Data("{}\n".utf8), token: "tok")
        XCTAssertEqual(result, .drop)
        XCTAssertEqual(box.get()?.reason, "token_expired")
        XCTAssertEqual(box.get()?.hint, "Device clock is behind.")
        XCTAssertEqual(box.get()?.httpStatus, 401)
    }

    func testSendReportsSuccessAndOffline() async {
        let sink = TransportOutcomeSink()
        let box = OutcomeBox()
        sink.handler = { outcome in box.set(outcome) }
        MockURLProtocol.statusCode = 202
        _ = await makeTransport(sink: sink).send(ndjsonBody: Data("{}\n".utf8), token: "tok")
        XCTAssertEqual(box.get()?.result, .success)
        XCTAssertNil(box.get()?.reason)
        MockURLProtocol.error = URLError(.cannotConnectToHost)
        _ = await makeTransport(sink: sink).send(ndjsonBody: Data("{}\n".utf8), token: "tok")
        XCTAssertEqual(box.get()?.result, .retryable)
        XCTAssertNil(box.get()?.httpStatus)
        XCTAssertNotNil(box.get()?.error)
    }
}

final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TransportOutcome?
    func set(_ v: TransportOutcome) { lock.lock(); value = v; lock.unlock() }
    func get() -> TransportOutcome? { lock.lock(); defer { lock.unlock() }; return value }
}
