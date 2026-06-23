import Foundation

/// Pure, platform-independent core of network breadcrumb instrumentation — the
/// part with all the *policy* and none of the `URLProtocol` lifecycle.
///
/// It answers two questions for a given request:
///   1. **Should we record it at all?** (`shouldRecord(url:)`) — excludes BugWatch's
///      own ingest traffic so telemetry never observes itself (which would loop), and
///      applies the optional host allow/deny lists.
///   2. **What breadcrumb represents it?** (`breadcrumb(method:url:statusCode:durationMs:)`)
///      — category `"network"`, with `method` / `host` / `path` / `status_code` /
///      `duration_ms` data. The path has its query string stripped by default so
///      tokens/PII riding in the query never land in a breadcrumb.
///
/// Keeping this logic free of `URLProtocol` makes the exclusion + filtering + path
/// redaction fully unit-testable without any networking.
struct NetworkBreadcrumbRecorder {
    /// The breadcrumb category stamped on every network crumb.
    static let category = "network"

    /// host+path of the configured ingest endpoint, derived once at construction.
    /// Any request matching this host (and, when present, sharing the ingest path
    /// prefix) is treated as BugWatch's own traffic and skipped.
    private let ingestHost: String?

    /// Lowercased allow-list. Empty means "all hosts" (subject to the BugWatch
    /// self-exclusion and the deny-list, which always win).
    private let allowedHosts: Set<String>
    /// Lowercased deny-list. A denied host is never recorded.
    private let deniedHosts: Set<String>

    /// Substring that marks any BugWatch ingest path (covers ingest/mobile,
    /// ingest/browser, and future v1 ingest routes) regardless of host.
    static let ingestPathMarker = "/api/v1/bugwatch/"

    /// - Parameters:
    ///   - endpoint: the SDK's configured ingest base URL (its host is excluded).
    ///   - allowedHosts: optional allow-list; empty = all hosts allowed.
    ///   - deniedHosts: optional deny-list; always excluded.
    init(endpoint: String, allowedHosts: [String], deniedHosts: [String]) {
        self.ingestHost = NetworkBreadcrumbRecorder.host(of: endpoint)
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.deniedHosts = Set(deniedHosts.map { $0.lowercased() })
    }

    /// Whether a request to `url` should be recorded as a breadcrumb.
    ///
    /// Order of precedence (first match wins):
    ///   1. BugWatch's own ingest traffic → never (prevents recursive telemetry).
    ///      A request is "ours" if its path contains the BugWatch ingest marker, or
    ///      if its host equals the configured endpoint host.
    ///   2. Denied host → never.
    ///   3. Non-empty allow-list that doesn't include the host → never.
    ///   4. Otherwise → record.
    func shouldRecord(url: URL?) -> Bool {
        guard let url else { return false }
        // Only http(s) — skip file://, data://, ws://, custom schemes, etc.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased() else { return false }

        // 1. Never record BugWatch's own ingest requests.
        if isBugWatchIngest(url: url, host: host) { return false }

        // 2. Deny-list always wins.
        if deniedHosts.contains(host) { return false }

        // 3. Allow-list (when present) gates everything else.
        if !allowedHosts.isEmpty && !allowedHosts.contains(host) { return false }

        return true
    }

    /// True when the URL targets BugWatch's ingest: either the path carries the
    /// `/api/v1/bugwatch/` marker, or the host matches the configured endpoint host.
    private func isBugWatchIngest(url: URL, host: String) -> Bool {
        if url.path.contains(NetworkBreadcrumbRecorder.ingestPathMarker) { return true }
        if let ingestHost, ingestHost == host { return true }
        return false
    }

    /// Builds the network breadcrumb. The level reflects the HTTP status: a 5xx is
    /// `error`, a 4xx is `warn`, everything else `info`. The query string is stripped
    /// from the recorded `path` by default so sensitive query params don't leak.
    func breadcrumb(
        method: String,
        url: URL,
        statusCode: Int?,
        durationMs: Int,
        timestamp: Date = Date()
    ) -> Breadcrumb {
        var data: [String: String] = [
            "method": method.uppercased(),
            "host": url.host ?? "",
            "path": NetworkBreadcrumbRecorder.sanitizedPath(url),
            "duration_ms": String(max(0, durationMs)),
        ]
        if let statusCode {
            data["status_code"] = String(statusCode)
        }
        return Breadcrumb(
            category: NetworkBreadcrumbRecorder.category,
            type: "http",
            level: NetworkBreadcrumbRecorder.level(for: statusCode),
            message: "\(method.uppercased()) \(url.host ?? "")\(NetworkBreadcrumbRecorder.sanitizedPath(url))",
            data: data,
            timestamp: timestamp
        )
    }

    /// Severity for an HTTP status: 5xx → error, 4xx → warn, else info (covers a
    /// missing status, e.g. a transport failure recorded as info).
    static func level(for statusCode: Int?) -> Severity {
        guard let statusCode else { return .info }
        switch statusCode {
        case 500...599: return .error
        case 400...499: return .warn
        default: return .info
        }
    }

    /// The request path with any query string and fragment removed. An empty path
    /// (e.g. `https://host`) becomes `"/"`.
    static func sanitizedPath(_ url: URL) -> String {
        // `url.path` already excludes the query and fragment.
        let path = url.path
        return path.isEmpty ? "/" : path
    }

    /// Extracts the lowercased host from a base URL string. Tolerates a bare host
    /// without a scheme (e.g. `api.example.com`) by retrying with an `https://`
    /// prefix, since `URLComponents` won't populate `host` without one.
    static func host(of endpoint: String) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let host = URLComponents(string: trimmed)?.host, !host.isEmpty {
            return host.lowercased()
        }
        if let host = URLComponents(string: "https://" + trimmed)?.host, !host.isEmpty {
            return host.lowercased()
        }
        return nil
    }
}
