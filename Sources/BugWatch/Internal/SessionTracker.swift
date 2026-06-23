import Foundation

/// Sentry-style release-health session tracking (A3), minimal.
///
/// A "session" is one SDK run: it opens at `start` (status `ok`) and is finalized
/// on the *next* launch as `exited` (clean prior shutdown) or `crashed` (the prior
/// run ended in a native crash). Both signals travel as ordinary `BugWatchEvent`s
/// carrying a `SessionInfo` through the existing enqueue → delivery pipe — there is
/// no separate session endpoint. The backend aggregates them into crash-free
/// session/user rates later.
///
/// To finalize the prior run on the next launch we persist a tiny descriptor of
/// the *current* session to disk at `start` (`current-session.json`, in the same
/// SDK directory as the queue and crash sidecar). On the following launch we read
/// it back as the "prior" session, emit its terminal event, and overwrite it with
/// the new run's descriptor.
///
/// All disk work is best-effort: a failure never throws into the host app.
struct SessionTracker {
    /// Persisted descriptor of a single run. All fields optional so a partial or
    /// older file still decodes.
    struct PersistedSession: Codable, Equatable {
        var id: String?
        /// Wall-clock millis the session started (debugging aid / future TTL).
        var startedAt: Int64?
        var release: String?
        var environment: String?
    }

    /// Session status values on the wire. Plain strings to match the cross-SDK
    /// ingest contract.
    enum Status: String {
        case ok
        case crashed
        case exited
    }

    let sessionURL: URL
    private let fm = FileManager.default

    init(directory: URL? = nil) {
        let dir = directory ?? CrashContextSidecar.defaultDirectory()
        self.sessionURL = dir.appendingPathComponent("current-session.json", isDirectory: false)
    }

    // MARK: Persistence

    /// Persists the current run's descriptor atomically, overwriting any prior
    /// one. Best-effort.
    func writeCurrent(_ session: PersistedSession) {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: sessionURL, options: .atomic)
    }

    /// Reads the persisted prior-run descriptor, or `nil` if none / unparseable.
    func readPrior() -> PersistedSession? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? JSONDecoder().decode(PersistedSession.self, from: data)
    }

    /// Removes the persisted descriptor (after the prior session is finalized, and
    /// on clean shutdown). Best-effort.
    func clear() {
        try? fm.removeItem(at: sessionURL)
    }

    // MARK: Boot orchestration

    /// Context the boot orchestration stamps onto session events — the live
    /// run's identity/device/user, supplied by the SDK facade.
    struct BootContext {
        var newSessionId: String
        var release: String?
        var environment: String
        var device: DeviceInfo?
        var installId: String?
        var user: BugWatchUser?
        var sdk: SdkInfo
    }

    /// Two-phase release-health boot, wired around the persisted descriptor +
    /// an injected `enqueue` closure (mirrors `CrashReporter.processPending`, so
    /// it's pure of any delivery/sampling concern and trivially unit-testable):
    ///
    /// 1. **Finalize the prior run** — if a persisted descriptor exists, emit one
    ///    terminal event for *its* id with `crashed` when `crashedLastRun` else
    ///    `exited` (carrying the prior run's release/environment), then delete the
    ///    descriptor so it can't be finalized twice.
    /// 2. **Open the new run** — persist the new descriptor and emit an `ok` event
    ///    for `context.newSessionId`.
    ///
    /// `enqueue` receives each fully-built session event in order (prior terminal
    /// first, then `ok`). Best-effort: callers swallow any throw.
    func runBoot(crashedLastRun: Bool, context: BootContext, enqueue: (BugWatchEvent) -> Void) {
        // Phase 1 — finalize the prior session (if any).
        if let prior = readPrior(), let priorId = prior.id {
            let status: Status = crashedLastRun ? .crashed : .exited
            let event = SessionTracker.buildSessionEvent(
                sessionId: priorId,
                status: status,
                release: prior.release,
                environment: prior.environment ?? context.environment,
                device: context.device,
                installId: context.installId,
                user: context.user,
                sdk: context.sdk
            )
            enqueue(event)
        }
        // Drop the prior descriptor regardless (parsed or not) so a stale/corrupt
        // file can't be re-finalized on a later launch.
        clear()

        // Phase 2 — open the new session.
        writeCurrent(PersistedSession(
            id: context.newSessionId,
            startedAt: Int64(Date().timeIntervalSince1970 * 1000),
            release: context.release,
            environment: context.environment
        ))
        let okEvent = SessionTracker.buildSessionEvent(
            sessionId: context.newSessionId,
            status: .ok,
            release: context.release,
            environment: context.environment,
            device: context.device,
            installId: context.installId,
            user: context.user,
            sdk: context.sdk
        )
        enqueue(okEvent)
    }

    // MARK: Event builder (pure — no I/O, trivially unit-testable)

    /// Builds a session `BugWatchEvent` carrying `session: { id, status }` at
    /// `.info` level, stamped with the usual release/environment/device/platform/
    /// ids/user context. Used for both the `ok` open event and the terminal
    /// `crashed`/`exited` event.
    static func buildSessionEvent(
        sessionId: String,
        status: Status,
        release: String?,
        environment: String,
        device: DeviceInfo?,
        installId: String?,
        user: BugWatchUser?,
        sdk: SdkInfo,
        now: Date = Date()
    ) -> BugWatchEvent {
        BugWatchEvent(
            eventId: "bw_e_" + UUID().uuidString.lowercased(),
            time: Int64(now.timeIntervalSince1970 * 1000),
            level: Severity.info.rawValue,
            message: nil,
            exception: nil,
            release: release,
            environment: environment,
            tags: nil,
            user: user,
            breadcrumbs: nil,
            sdk: sdk,
            platform: "ios",
            installId: installId,
            sessionId: sessionId,
            device: device,
            session: SessionInfo(id: sessionId, status: status.rawValue)
        )
    }

    // MARK: Internals

    private func ensureDirectory() {
        let dir = sessionURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
