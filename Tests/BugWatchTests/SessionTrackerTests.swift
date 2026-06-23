import XCTest
@testable import BugWatch

/// A3 — release-health session tracking. Unit tests for the session-event
/// builder + the two-phase boot orchestration (`SessionTracker.runBoot`), plus a
/// few facade-level checks driven through `BugWatch.start` against an isolated SDK
/// directory (the internal test seam) so the real boot ordering is exercised.
final class SessionTrackerTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        BugWatch.close()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private let sdk = SdkInfo(name: BugWatch.sdkName, version: BugWatch.sdkVersion)

    private func context(newSessionId: String = "bw_s_new",
                         release: String? = "1.2.3+4",
                         environment: String = "production",
                         user: BugWatchUser? = nil) -> SessionTracker.BootContext {
        SessionTracker.BootContext(
            newSessionId: newSessionId,
            release: release,
            environment: environment,
            device: DeviceInfo(model: "iPhone15,2", family: "iPhone", osName: "iOS", osVersion: "17.4"),
            installId: "install-1",
            user: user,
            sdk: sdk
        )
    }

    // MARK: - Builder

    /// The session-event builder produces an `.info` event carrying
    /// `session: { id, status }` with the requested status and the supplied
    /// release/env/device/ids/user context — and no exception/message.
    func testBuildSessionEventCarriesSessionWithStatus() {
        for status in [SessionTracker.Status.ok, .crashed, .exited] {
            let event = SessionTracker.buildSessionEvent(
                sessionId: "bw_s_42",
                status: status,
                release: "9.9.9",
                environment: "staging",
                device: DeviceInfo(model: "iPhone15,2"),
                installId: "i-1",
                user: BugWatchUser(id: "u-1"),
                sdk: sdk
            )
            XCTAssertEqual(event.session?.id, "bw_s_42")
            XCTAssertEqual(event.session?.status, status.rawValue)
            XCTAssertEqual(event.level, Severity.info.rawValue)
            XCTAssertEqual(event.platform, "ios")
            XCTAssertEqual(event.sessionId, "bw_s_42")
            XCTAssertEqual(event.release, "9.9.9")
            XCTAssertEqual(event.environment, "staging")
            XCTAssertEqual(event.installId, "i-1")
            XCTAssertEqual(event.user?.id, "u-1")
            XCTAssertEqual(event.device?.model, "iPhone15,2")
            XCTAssertNil(event.exception)
            XCTAssertNil(event.message)
            XCTAssertTrue(event.eventId.hasPrefix("bw_e_"))
        }
    }

    /// The status enum serializes to the exact wire strings.
    func testStatusRawValues() {
        XCTAssertEqual(SessionTracker.Status.ok.rawValue, "ok")
        XCTAssertEqual(SessionTracker.Status.crashed.rawValue, "crashed")
        XCTAssertEqual(SessionTracker.Status.exited.rawValue, "exited")
    }

    /// `session` round-trips through the NDJSON serialization used by the queue.
    func testSessionFieldSerializesIntoJSONLine() throws {
        let event = SessionTracker.buildSessionEvent(
            sessionId: "bw_s_json", status: .ok, release: nil,
            environment: "production", device: nil, installId: nil, user: nil, sdk: sdk
        )
        let line = try XCTUnwrap(PersistentEventQueue.serialize(event))
        XCTAssertTrue(line.contains("\"session\""))
        let decoded = try JSONDecoder().decode(BugWatchEvent.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.session?.id, "bw_s_json")
        XCTAssertEqual(decoded.session?.status, "ok")
    }

    // MARK: - Prior-session finalize (runBoot)

    /// A persisted prior session + `crashedLastRun == true` finalizes that prior
    /// session id as `crashed`, carrying the prior run's release/environment.
    func testRunBootFinalizesPriorAsCrashedWhenCrashedLastRun() {
        let tracker = SessionTracker(directory: dir)
        tracker.writeCurrent(SessionTracker.PersistedSession(
            id: "bw_s_prior", startedAt: 1_700_000_000_000, release: "1.0.0+prior", environment: "staging"
        ))

        var enqueued: [BugWatchEvent] = []
        tracker.runBoot(crashedLastRun: true, context: context()) { enqueued.append($0) }

        // Two events: prior terminal (crashed) then the new ok.
        XCTAssertEqual(enqueued.count, 2)
        let terminal = enqueued[0]
        XCTAssertEqual(terminal.session?.id, "bw_s_prior")
        XCTAssertEqual(terminal.session?.status, "crashed")
        XCTAssertEqual(terminal.release, "1.0.0+prior", "prior run's release, not this run's")
        XCTAssertEqual(terminal.environment, "staging", "prior run's environment")
        XCTAssertEqual(terminal.level, Severity.info.rawValue)
    }

    /// A persisted prior session + `crashedLastRun == false` finalizes that prior
    /// session id as `exited`.
    func testRunBootFinalizesPriorAsExitedWhenNoCrash() {
        let tracker = SessionTracker(directory: dir)
        tracker.writeCurrent(SessionTracker.PersistedSession(
            id: "bw_s_prior", startedAt: 1, release: "1.0", environment: "production"
        ))

        var enqueued: [BugWatchEvent] = []
        tracker.runBoot(crashedLastRun: false, context: context()) { enqueued.append($0) }

        XCTAssertEqual(enqueued.count, 2)
        XCTAssertEqual(enqueued[0].session?.id, "bw_s_prior")
        XCTAssertEqual(enqueued[0].session?.status, "exited")
    }

    /// After finalizing the prior session, its descriptor is overwritten with the
    /// NEW run's descriptor (so the prior can never be finalized twice, and the
    /// next launch finalizes *this* run).
    func testRunBootReplacesPriorDescriptorWithNewSession() {
        let tracker = SessionTracker(directory: dir)
        tracker.writeCurrent(SessionTracker.PersistedSession(id: "bw_s_prior"))

        tracker.runBoot(crashedLastRun: true, context: context(newSessionId: "bw_s_current")) { _ in }

        let persisted = tracker.readPrior()
        XCTAssertEqual(persisted?.id, "bw_s_current", "descriptor now points at the new run")
    }

    // MARK: - New-session start (runBoot, no prior)

    /// With no persisted prior session, `runBoot` enqueues exactly one `ok`
    /// session event for the new id and writes the persisted-session file.
    func testRunBootWithNoPriorEnqueuesOkAndPersists() {
        let tracker = SessionTracker(directory: dir)
        XCTAssertNil(tracker.readPrior(), "no prior session on a clean slate")

        var enqueued: [BugWatchEvent] = []
        tracker.runBoot(crashedLastRun: false, context: context(newSessionId: "bw_s_fresh")) { enqueued.append($0) }

        XCTAssertEqual(enqueued.count, 1, "only the ok event — no prior to finalize")
        XCTAssertEqual(enqueued[0].session?.id, "bw_s_fresh")
        XCTAssertEqual(enqueued[0].session?.status, "ok")

        // Persisted-session file written for the new run.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracker.sessionURL.path), "descriptor written")
        let persisted = tracker.readPrior()
        XCTAssertEqual(persisted?.id, "bw_s_fresh")
        XCTAssertEqual(persisted?.release, "1.2.3+4")
        XCTAssertEqual(persisted?.environment, "production")
    }

    // MARK: - Facade: autoSessionTracking toggle + persistence

    /// Driven through the real `start` boot flow (isolated dir): a fresh launch
    /// with auto session tracking on writes the session descriptor and enqueues
    /// the `ok` session event.
    func testStartEnqueuesOkSessionEventAndPersists() {
        BugWatch.start(options: makeOptions(autoSessionTracking: true), directory: dir)

        // Descriptor persisted synchronously during boot (never touched by drain).
        let tracker = SessionTracker(directory: dir)
        let persisted = tracker.readPrior()
        XCTAssertNotNil(persisted?.id, "current session descriptor persisted")

        // The ok session event is in the queue (delivery is blackholed below, so
        // it can't be drained away within the test).
        let sessionEvents = readQueueSessionEvents()
        XCTAssertEqual(sessionEvents.count, 1)
        XCTAssertEqual(sessionEvents.first?.session?.status, "ok")
        XCTAssertEqual(sessionEvents.first?.session?.id, persisted?.id)
    }

    /// `autoSessionTracking == false` produces no session events and writes no
    /// session descriptor.
    func testAutoSessionTrackingDisabledEmitsNothing() {
        BugWatch.start(options: makeOptions(autoSessionTracking: false), directory: dir)

        XCTAssertNil(SessionTracker(directory: dir).readPrior(), "no descriptor when tracking off")
        XCTAssertTrue(readQueueSessionEvents().isEmpty, "no session events when tracking off")
        // And nothing else got enqueued either.
        XCTAssertEqual(readQueueAll().count, 0)
    }

    /// Session events bypass sampling: with `sampleRate == 0` an ordinary capture
    /// is dropped at enqueue, but the `ok` session event is still enqueued.
    func testSessionEventsBypassSampling() {
        let bw = BugWatch.start(
            options: makeOptions(autoSessionTracking: true, sampleRate: 0.0),
            directory: dir
        )
        // Ordinary capture under sampleRate=0 → dropped, never written.
        _ = bw.captureMessage("dropped by sampling", level: .error)

        let all = readQueueAll()
        let sessionEvents = all.filter { $0.session != nil }
        let nonSession = all.filter { $0.session == nil }
        XCTAssertEqual(sessionEvents.count, 1, "session event survived sampleRate=0")
        XCTAssertEqual(sessionEvents.first?.session?.status, "ok")
        XCTAssertTrue(nonSession.isEmpty, "the sampled-out error was not enqueued")
    }

    // MARK: - Helpers

    /// Options pinned to a blackhole endpoint so an in-flight delivery never
    /// completes during the test (events stay in the queue for inspection), with
    /// the flush timer disabled.
    private func makeOptions(autoSessionTracking: Bool, sampleRate: Double = 1.0) -> BugWatchOptions {
        BugWatchOptions(
            projectId: "proj_test",
            appSecret: "qHJ80UA2fcTfpi-yiobmScytk-YlkWkAYGPO6DGsvQk",
            // Non-routable address: connect blackholes until timeout, so the
            // background drain triggered at boot cannot finish (and thus cannot
            // remove the just-enqueued events) within the synchronous test body.
            endpoint: "http://10.255.255.1:9",
            release: "1.0.0+test",
            sampleRate: sampleRate,
            flushIntervalMs: 0,
            requestTimeoutMs: 60_000,
            autoSessionTracking: autoSessionTracking
        )
    }

    /// Reads every event currently in the SDK's queue file (in this isolated dir).
    private func readQueueAll() -> [BugWatchEvent] {
        let url = dir.appendingPathComponent("pending-events.ndjson", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var out: [BugWatchEvent] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let e = try? decoder.decode(BugWatchEvent.self, from: Data(raw.utf8)) {
                out.append(e)
            }
        }
        return out
    }

    private func readQueueSessionEvents() -> [BugWatchEvent] {
        readQueueAll().filter { $0.session != nil }
    }
}
