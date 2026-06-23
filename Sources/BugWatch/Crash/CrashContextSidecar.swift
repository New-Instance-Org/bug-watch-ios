import Foundation

/// Persisted "context sidecar" written next to the crash artifact so the **next
/// launch** can enrich a crash even though the crashing process can't.
///
/// A crash kills the process immediately, so at crash time we can only dump a
/// minimal, async-signal-safe artifact (see `CrashReporter`). Everything that
/// requires Foundation — device snapshot, release, environment, install/session
/// ids, recent breadcrumbs — is captured here *ahead of time* (at `start`, and
/// incrementally for breadcrumbs) and re-read on the following launch to build a
/// complete fatal `BugWatchEvent`.
///
/// Two files back this:
/// - **context.json** — a single JSON object (device + release + env + ids),
///   rewritten atomically at each `start`.
/// - **breadcrumbs.ndjson** — a bounded NDJSON ring of recent breadcrumbs,
///   appended cheaply on each `addBreadcrumb` and trimmed when it grows past the
///   cap. Best-effort: a failed append never disturbs the host app.
struct CrashContextSidecar {
    /// Decoded shape of `context.json`. All fields optional so a partial or
    /// older sidecar still parses.
    struct Context: Codable, Equatable {
        var installId: String?
        var sessionId: String?
        var release: String?
        var environment: String?
        var device: DeviceInfo?
        /// Wall-clock millis the sidecar was written (debugging aid).
        var startedAt: Int64?
    }

    let contextURL: URL
    let breadcrumbsURL: URL
    /// Max breadcrumbs retained in the sidecar ring.
    let maxBreadcrumbs: Int

    private let fm = FileManager.default
    /// Serializes breadcrumb appends so concurrent `addBreadcrumb` calls can't
    /// interleave a partial line.
    private let lock = NSLock()

    init(directory: URL? = nil, maxBreadcrumbs: Int = 50) {
        let dir = directory ?? CrashContextSidecar.defaultDirectory()
        self.contextURL = dir.appendingPathComponent("crash-context.json", isDirectory: false)
        self.breadcrumbsURL = dir.appendingPathComponent("crash-breadcrumbs.ndjson", isDirectory: false)
        self.maxBreadcrumbs = max(1, maxBreadcrumbs)
    }

    /// SDK directory shared with the persistent event queue (Application Support,
    /// namespaced). Falls back to a temp dir if Application Support is missing.
    static func defaultDirectory() -> URL {
        let base: URL
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = support
        } else {
            base = FileManager.default.temporaryDirectory
        }
        return base.appendingPathComponent("cloud.newinstance.bugwatch", isDirectory: true)
    }

    // MARK: Context

    /// Writes the context sidecar atomically. Best-effort — failure is swallowed
    /// so it can never affect host startup.
    func writeContext(_ context: Context) {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(context) else { return }
        try? data.write(to: contextURL, options: .atomic)
    }

    /// Reads the context sidecar, or `nil` if absent/unparseable.
    func readContext() -> Context? {
        guard let data = try? Data(contentsOf: contextURL) else { return nil }
        return try? JSONDecoder().decode(Context.self, from: data)
    }

    // MARK: Breadcrumbs

    /// Appends one breadcrumb to the bounded ring. Cheap O(1) append in the
    /// common case; only rewrites the file when it exceeds the cap. Best-effort.
    func appendBreadcrumb(_ crumb: Breadcrumb) {
        lock.lock()
        defer { lock.unlock() }
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = (try? encoder.encode(crumb)).flatMap({ String(data: $0, encoding: .utf8) }) else { return }
        line = line.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")

        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: breadcrumbsURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: breadcrumbsURL, options: .atomic)
        }
        trimIfNeededLocked()
    }

    /// Reads the retained breadcrumbs (oldest first), skipping unparseable lines.
    func readBreadcrumbs() -> [Breadcrumb] {
        guard let data = try? Data(contentsOf: breadcrumbsURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Breadcrumb] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let crumb = trimmed.data(using: .utf8).flatMap({ try? decoder.decode(Breadcrumb.self, from: $0) }) {
                out.append(crumb)
            }
        }
        return out
    }

    // MARK: Lifecycle

    /// Removes both sidecar files (called after a crash is reported, and on a
    /// clean shutdown so a stale context can't mis-enrich a future crash).
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? fm.removeItem(at: contextURL)
        try? fm.removeItem(at: breadcrumbsURL)
    }

    /// Clears only the breadcrumb ring (used when starting a fresh session so the
    /// previous run's crumbs don't bleed into the next crash).
    func resetBreadcrumbs() {
        lock.lock()
        defer { lock.unlock() }
        try? fm.removeItem(at: breadcrumbsURL)
    }

    // MARK: Internals

    private func ensureDirectory() {
        let dir = contextURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Keeps the newest `maxBreadcrumbs` lines, dropping the oldest. Only touches
    /// disk when actually over the cap. Caller must hold `lock`.
    private func trimIfNeededLocked() {
        guard let data = try? Data(contentsOf: breadcrumbsURL),
              let text = String(data: data, encoding: .utf8) else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > maxBreadcrumbs else { return }
        lines = Array(lines.suffix(maxBreadcrumbs))
        let body = lines.joined(separator: "\n") + "\n"
        try? Data(body.utf8).write(to: breadcrumbsURL, options: .atomic)
    }
}
