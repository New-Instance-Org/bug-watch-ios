import XCTest
@testable import BugWatch

/// Mock URLProtocol that returns a scripted status code (or error) and records
/// the last request it saw, so transport behavior can be asserted without a
/// network.
final class MockURLProtocol: URLProtocol {
    /// Status code to return for the next request. If `error` is set, that is
    /// thrown instead.
    nonisolated(unsafe) static var statusCode: Int = 202
    nonisolated(unsafe) static var error: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        statusCode = 202
        error = nil
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lastRequest = request
        // URLProtocol strips httpBody into a stream; capture it for assertions.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            MockURLProtocol.lastBody = data
        } else {
            MockURLProtocol.lastBody = request.httpBody
        }

        if let error = MockURLProtocol.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: MockURLProtocol.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HttpTransportTests: XCTestCase {
    private func makeTransport() -> HttpTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return HttpTransport(endpoint: "https://api.example.test", requestTimeoutMs: 5000, session: session)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    // MARK: Pure classification

    func testClassify2xxIsSuccess() {
        XCTAssertEqual(HttpTransport.classify(statusCode: 200), .success)
        XCTAssertEqual(HttpTransport.classify(statusCode: 202), .success)
        XCTAssertEqual(HttpTransport.classify(statusCode: 299), .success)
    }

    func testClassify5xxAnd429AreRetryable() {
        XCTAssertEqual(HttpTransport.classify(statusCode: 500), .retryable)
        XCTAssertEqual(HttpTransport.classify(statusCode: 503), .retryable)
        XCTAssertEqual(HttpTransport.classify(statusCode: 429), .retryable)
    }

    func testClassifyOther4xxIsDrop() {
        XCTAssertEqual(HttpTransport.classify(statusCode: 400), .drop)
        XCTAssertEqual(HttpTransport.classify(statusCode: 401), .drop)
        XCTAssertEqual(HttpTransport.classify(statusCode: 404), .drop)
    }

    // MARK: End-to-end via mock URLProtocol

    func test202MapsToSuccess() async {
        MockURLProtocol.statusCode = 202
        let result = await makeTransport().send(ndjsonBody: Data("{}\n".utf8), token: "tok")
        XCTAssertEqual(result, .success)
    }

    func test500MapsToRetryable() async {
        MockURLProtocol.statusCode = 500
        let result = await makeTransport().send(ndjsonBody: Data("{}\n".utf8), token: "tok")
        XCTAssertEqual(result, .retryable)
    }

    func test400MapsToDrop() async {
        MockURLProtocol.statusCode = 400
        let result = await makeTransport().send(ndjsonBody: Data("{}\n".utf8), token: "tok")
        XCTAssertEqual(result, .drop)
    }

    func testNetworkErrorMapsToRetryable() async {
        MockURLProtocol.error = URLError(.notConnectedToInternet)
        let result = await makeTransport().send(ndjsonBody: Data("{}\n".utf8), token: "tok")
        XCTAssertEqual(result, .retryable)
    }

    /// The request carries the contract's method, path, token header, and
    /// content type.
    func testRequestShapeMatchesContract() async {
        MockURLProtocol.statusCode = 202
        let body = Data("{\"eventId\":\"e1\"}\n".utf8)
        _ = await makeTransport().send(ndjsonBody: body, token: "my-token")

        let req = MockURLProtocol.lastRequest
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.url?.absoluteString, "https://api.example.test/api/v1/bugwatch/ingest/mobile")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "x-bugwatch-token"), "my-token")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")
        XCTAssertEqual(MockURLProtocol.lastBody, body)
    }

    /// Trailing slashes on the endpoint don't double up the path.
    func testEndpointTrailingSlashTrimmed() {
        let t = HttpTransport(endpoint: "https://api.example.test/", requestTimeoutMs: 5000)
        XCTAssertEqual(t.ingestURL?.absoluteString, "https://api.example.test/api/v1/bugwatch/ingest/mobile")
    }
}
