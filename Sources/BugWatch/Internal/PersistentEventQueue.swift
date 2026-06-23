import Foundation

/// Disk-backed, NDJSON, FIFO queue of pending events.
///
/// Each pending event is one JSON line (the serialized `BugWatchEvent`) in a
/// single append-only file under Application Support. Surviving the file across
/// launches lets events captured just before a crash/terminate be delivered on
/// the next run.
///
/// Properties:
/// - **append-only enqueue** — O(1) writes; the file is only rewritten on
///   eviction or `removeDelivered`.
/// - **bounded** — at most `maxQueueSize` lines and no line older than
///   `maxAgeSeconds`; the oldest are dropped first.
/// - **corruption-tolerant** — unparseable lines are skipped on read and pruned
///   on the next rewrite, so a partial trailing write (e.g. killed mid-append)
///   can never wedge the queue.
/// - **thread-safe** — every operation is serialized on an internal lock.
final class PersistentEventQueue {
    /// One queued record: the raw JSON line plus the fields needed for
    /// eviction (`time`) and dedup-on-delete (`eventId`).
    struct Record: Equatable {
        let eventId: String
        let time: Int64           // unix milliseconds
        let line: String          // the serialized event JSON (no trailing newline)
    }

    private let fileURL: URL
    private let maxQueueSize: Int
    private let maxAgeMillis: Int64
    private let lock = NSLock()
    private let fm = FileManager.default

    /// - Parameters:
    ///   - fileURL: backing NDJSON file. Defaults to
    ///     `Application Support/cloud.newinstance.bugwatch/pending-events.ndjson`.
    ///   - maxQueueSize: max retained lines (oldest dropped past this).
    ///   - maxAgeSeconds: max retained age in seconds (older dropped). Default 7 days.
    init(fileURL: URL? = nil, maxQueueSize: Int, maxAgeSeconds: Int = 7 * 24 * 60 * 60) {
        self.fileURL = fileURL ?? PersistentEventQueue.defaultFileURL()
        self.maxQueueSize = max(1, maxQueueSize)
        self.maxAgeMillis = Int64(max(0, maxAgeSeconds)) * 1000
        ensureDirectory()
    }

    /// Default backing file under Application Support, namespaced to the SDK.
    static func defaultFileURL() -> URL {
        let base: URL
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = support
        } else {
            base = FileManager.default.temporaryDirectory
        }
        return base
            .appendingPathComponent("cloud.newinstance.bugwatch", isDirectory: true)
            .appendingPathComponent("pending-events.ndjson", isDirectory: false)
    }

    // MARK: Public API

    /// Appends an event. After appending, enforces age + size caps (dropping the
    /// oldest). Returns `false` if anything had to be evicted to stay within bounds.
    @discardableResult
    func enqueue(_ event: BugWatchEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let line = Self.serialize(event) else { return true }
        appendLineLocked(line)
        return enforceBoundsLocked()
    }

    /// Returns up to `limit` of the oldest pending records (FIFO). Skips
    /// unparseable lines.
    func loadPending(limit: Int) -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        let records = readAllLocked()
        let n = min(max(limit, 0), records.count)
        return Array(records.prefix(n))
    }

    /// Removes the records with the given event ids from the file. Also prunes
    /// any corrupt lines encountered during the rewrite.
    func removeDelivered(eventIds: [String]) {
        guard !eventIds.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let drop = Set(eventIds)
        let kept = readAllLocked().filter { !drop.contains($0.eventId) }
        rewriteLocked(kept)
    }

    /// Total pending records currently on disk (parseable lines only).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return readAllLocked().count
    }

    /// Deletes the backing file (used on close/reset).
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? fm.removeItem(at: fileURL)
    }

    // MARK: Serialization

    /// Serializes one event to a single-line JSON string (no embedded newlines).
    static func serialize(_ event: BugWatchEvent) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(event) else { return nil }
        guard var s = String(data: data, encoding: .utf8) else { return nil }
        // Defensive: a JSON object never legitimately contains a raw newline,
        // but strip any just in case so one record stays one line.
        s = s.replacingOccurrences(of: "\n", with: "")
        s = s.replacingOccurrences(of: "\r", with: "")
        return s
    }

    // MARK: Internals (must hold `lock`)

    private func ensureDirectory() {
        let dir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func appendLineLocked(_ line: String) {
        ensureDirectory()
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // File doesn't exist yet — create it with this first line.
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Parses the file into records, skipping unparseable lines. FIFO order is
    /// file order (oldest first).
    private func readAllLocked() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var out: [Record] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let (eventId, time) = Self.parseHeader(trimmed) else { continue } // corrupt → skip
            out.append(Record(eventId: eventId, time: time, line: trimmed))
        }
        return out
    }

    /// Extracts `eventId` and `time` from a serialized event line without fully
    /// decoding it into a model (keeps read cheap + tolerant of extra fields).
    static func parseHeader(_ line: String) -> (eventId: String, time: Int64)? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventId = obj["eventId"] as? String else {
            return nil
        }
        let time: Int64
        if let t = obj["time"] as? Int64 { time = t }
        else if let t = obj["time"] as? Int { time = Int64(t) }
        else if let t = obj["time"] as? Double { time = Int64(t) }
        else if let t = obj["time"] as? NSNumber { time = t.int64Value }
        else { time = 0 }
        return (eventId, time)
    }

    /// Enforces age then size caps. Returns `false` if any record was evicted.
    @discardableResult
    private func enforceBoundsLocked() -> Bool {
        var records = readAllLocked()
        let before = records.count

        // Age cap.
        if maxAgeMillis > 0 {
            let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - maxAgeMillis
            records = records.filter { $0.time == 0 || $0.time >= cutoff }
        }

        // Size cap — keep the newest `maxQueueSize` (drop oldest from the front).
        if records.count > maxQueueSize {
            records = Array(records.suffix(maxQueueSize))
        }

        let evicted = before != records.count
        if evicted {
            rewriteLocked(records)
        }
        return !evicted
    }

    private func rewriteLocked(_ records: [Record]) {
        if records.isEmpty {
            try? fm.removeItem(at: fileURL)
            return
        }
        let body = records.map { $0.line }.joined(separator: "\n") + "\n"
        try? Data(body.utf8).write(to: fileURL, options: .atomic)
    }
}
