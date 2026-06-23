import XCTest
@testable import BugWatch

final class PersistentEventQueueTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("pending.ndjson")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeEvent(id: String, time: Int64 = Int64(Date().timeIntervalSince1970 * 1000), message: String? = "m") -> BugWatchEvent {
        BugWatchEvent(
            eventId: id,
            time: time,
            level: Severity.error.rawValue,
            message: message,
            sdk: SdkInfo(name: "bugwatch-ios", version: "0.1.0"),
            platform: "ios",
            installId: "install-1",
            sessionId: "session-1"
        )
    }

    /// persist → reload → drain semantics: events written by one instance are
    /// visible to a freshly constructed instance over the same file, and
    /// removeDelivered empties it.
    func testPersistReloadDrain() {
        let q1 = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 100)
        q1.enqueue(makeEvent(id: "e1"))
        q1.enqueue(makeEvent(id: "e2"))
        q1.enqueue(makeEvent(id: "e3"))
        XCTAssertEqual(q1.count, 3)

        // New instance over the SAME file — simulates a fresh app launch.
        let q2 = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 100)
        let pending = q2.loadPending(limit: 10)
        XCTAssertEqual(pending.map { $0.eventId }, ["e1", "e2", "e3"]) // FIFO order

        q2.removeDelivered(eventIds: ["e1", "e2"])
        XCTAssertEqual(q2.count, 1)
        XCTAssertEqual(q2.loadPending(limit: 10).map { $0.eventId }, ["e3"])

        q2.removeDelivered(eventIds: ["e3"])
        XCTAssertEqual(q2.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "empty queue removes the file")
    }

    /// loadPending honors the batch limit and returns the oldest first.
    func testLoadPendingRespectsLimit() {
        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 100)
        for i in 1...5 { q.enqueue(makeEvent(id: "e\(i)")) }
        let batch = q.loadPending(limit: 2)
        XCTAssertEqual(batch.map { $0.eventId }, ["e1", "e2"])
    }

    /// Size cap drops the OLDEST events.
    func testEvictionBySizeDropsOldest() {
        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 3)
        for i in 1...6 { q.enqueue(makeEvent(id: "e\(i)")) }
        XCTAssertEqual(q.count, 3)
        // Newest three survive.
        XCTAssertEqual(q.loadPending(limit: 10).map { $0.eventId }, ["e4", "e5", "e6"])
    }

    /// enqueue returns false when an eviction had to happen.
    func testEnqueueReturnsFalseOnEviction() {
        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 2)
        XCTAssertTrue(q.enqueue(makeEvent(id: "e1")))
        XCTAssertTrue(q.enqueue(makeEvent(id: "e2")))
        XCTAssertFalse(q.enqueue(makeEvent(id: "e3")), "third enqueue evicts the oldest")
        XCTAssertEqual(q.loadPending(limit: 10).map { $0.eventId }, ["e2", "e3"])
    }

    /// Age cap drops events older than maxAgeSeconds.
    func testEvictionByAge() {
        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 100, maxAgeSeconds: 60)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // One ancient event (2 hours old), one fresh.
        q.enqueue(makeEvent(id: "old", time: nowMs - 2 * 60 * 60 * 1000))
        q.enqueue(makeEvent(id: "new", time: nowMs))
        XCTAssertEqual(q.loadPending(limit: 10).map { $0.eventId }, ["new"], "stale event evicted")
    }

    /// Unparseable lines are skipped on read and pruned on rewrite.
    func testCorruptLineTolerance() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good1 = PersistentEventQueue.serialize(makeEvent(id: "e1"))!
        let good2 = PersistentEventQueue.serialize(makeEvent(id: "e2"))!
        // Interleave garbage + a truncated JSON object.
        let contents = good1 + "\n" + "this is not json\n" + "{\"eventId\":\"truncat\n" + good2 + "\n"
        try Data(contents.utf8).write(to: fileURL)

        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 100)
        let pending = q.loadPending(limit: 10)
        XCTAssertEqual(pending.map { $0.eventId }, ["e1", "e2"], "only the two valid lines survive")
        XCTAssertEqual(q.count, 2)

        // After a rewrite the corrupt lines are gone from disk.
        q.removeDelivered(eventIds: ["e1"])
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("this is not json"))
        XCTAssertFalse(raw.contains("truncat"))
        XCTAssertTrue(raw.contains("e2"))
    }

    /// A serialized event survives a full encode → header-parse round trip with
    /// its id and time intact (and no embedded newline).
    func testSerializeRoundTripHeader() {
        let line = PersistentEventQueue.serialize(makeEvent(id: "e1", time: 123456))!
        XCTAssertFalse(line.contains("\n"))
        let header = PersistentEventQueue.parseHeader(line)
        XCTAssertEqual(header?.eventId, "e1")
        XCTAssertEqual(header?.time, 123456)
    }

    /// Concurrent enqueues from many threads don't corrupt the file or lose count.
    func testThreadSafetyUnderConcurrentEnqueue() {
        let q = PersistentEventQueue(fileURL: fileURL, maxQueueSize: 10_000)
        let group = DispatchGroup()
        for i in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                q.enqueue(self.makeEvent(id: "e\(i)"))
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(q.count, 200)
    }
}
