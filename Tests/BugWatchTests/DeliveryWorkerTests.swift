import XCTest
@testable import BugWatch

/// URLProtocol whose response sequence can be scripted per-call, so we can model
/// "fail twice then succeed" without real backoff delays.
final class SequencedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statuses: [Int] = []
    nonisolated(unsafe) static var index = 0
    nonisolated(unsafe) static var requestCount = 0

    static func reset(_ statuses: [Int]) {
        self.statuses = statuses
        index = 0
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        SequencedURLProtocol.requestCount += 1
        let code: Int
        if SequencedURLProtocol.index < SequencedURLProtocol.statuses.count {
            code = SequencedURLProtocol.statuses[SequencedURLProtocol.index]
        } else {
            code = SequencedURLProtocol.statuses.last ?? 202
        }
        SequencedURLProtocol.index += 1

        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DeliveryWorkerTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-worker-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("pending.ndjson")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeEvent(id: String) -> BugWatchEvent {
        BugWatchEvent(eventId: id, time: Int64(Date().timeIntervalSince1970 * 1000), level: 50, message: "m",
                      sdk: SdkInfo(name: "bugwatch-ios", version: "0.1.0"))
    }

    private func makeWorker(queue: PersistentEventQueue, batchSize: Int = 50, maxAttempts: Int = 3) -> DeliveryWorker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequencedURLProtocol.self]
        let session = URLSession(configuration: config)
        let transport = HttpTransport(endpoint: "https://api.example.test", requestTimeoutMs: 5000, session: session)
        return DeliveryWorker(
            signer: TokenSigner(appSecret: "secret"),
            transport: transport,
            queue: queue,
            pid: "proj_abc123",
            env: "production",
            batchSize: batchSize,
            retry: RetryPolicy(initialDelayMs: 1, maxDelayMs: 1, maxAttempts: maxAttempts),
            sleep: { _ in }    // no real delays in tests
        )
    }

    /// Success removes the delivered events from the queue.
    func testDrainRemovesDeliveredOnSuccess() async {
        SequencedURLProtocol.reset([202])
        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 100)
        q.enqueue(makeEvent(id: "e1"))
        q.enqueue(makeEvent(id: "e2"))

        let worker = makeWorker(queue: q)
        await worker.drain()
        XCTAssertEqual(q.count, 0)
    }

    /// Retryable then success: the batch is retried and eventually delivered.
    func testRetryThenSucceed() async {
        SequencedURLProtocol.reset([500, 500, 202])  // fail twice, then ok
        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 100)
        q.enqueue(makeEvent(id: "e1"))

        let worker = makeWorker(queue: q, maxAttempts: 3)
        await worker.drain()
        XCTAssertEqual(q.count, 0, "batch delivered after retries")
        XCTAssertGreaterThanOrEqual(SequencedURLProtocol.requestCount, 3)
    }

    /// A permanent 4xx drops the batch (so it can't wedge the queue).
    func testDropDiscardsBatch() async {
        SequencedURLProtocol.reset([400])
        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 100)
        q.enqueue(makeEvent(id: "e1"))

        let worker = makeWorker(queue: q)
        await worker.drain()
        XCTAssertEqual(q.count, 0, "non-recoverable batch is discarded")
        XCTAssertEqual(SequencedURLProtocol.requestCount, 1, "no retries for .drop")
    }

    /// Exhausting maxAttempts on persistent retryable failures discards the batch
    /// rather than looping forever.
    func testExhaustedRetriesDiscards() async {
        SequencedURLProtocol.reset([503])  // always fails
        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 100)
        q.enqueue(makeEvent(id: "e1"))

        let worker = makeWorker(queue: q, maxAttempts: 3)
        await worker.drain()
        XCTAssertEqual(q.count, 0)
        XCTAssertEqual(SequencedURLProtocol.requestCount, 3, "exactly maxAttempts tries")
    }

    /// Draining processes multiple batches until the queue is empty.
    func testDrainsMultipleBatches() async {
        SequencedURLProtocol.reset([202])
        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 100)
        for i in 1...5 { q.enqueue(makeEvent(id: "e\(i)")) }

        let worker = makeWorker(queue: q, batchSize: 2)  // 5 events → 3 batches
        await worker.drain()
        XCTAssertEqual(q.count, 0)
        XCTAssertGreaterThanOrEqual(SequencedURLProtocol.requestCount, 3)
    }
}
