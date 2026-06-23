import XCTest
@testable import BugWatch

/// A5 — network breadcrumb policy. Drives the pure `NetworkBreadcrumbRecorder` (the
/// part that decides *whether* to record and *what* breadcrumb to build) with no
/// networking, so the BugWatch self-exclusion, allow/deny filtering, and query-string
/// stripping are exercised deterministically.
final class NetworkBreadcrumbRecorderTests: XCTestCase {

    private let endpoint = "https://api.newinstance.cloud"

    private func makeRecorder(
        allowed: [String] = [],
        denied: [String] = []
    ) -> NetworkBreadcrumbRecorder {
        NetworkBreadcrumbRecorder(endpoint: endpoint, allowedHosts: allowed, deniedHosts: denied)
    }

    // MARK: - Records a normal request

    /// A normal third-party request produces a `network` breadcrumb carrying method,
    /// host, path, status_code, and duration_ms.
    func testRecordsBreadcrumbForNormalRequest() {
        let rec = makeRecorder()
        let url = URL(string: "https://api.example.com/v2/users/42")!
        XCTAssertTrue(rec.shouldRecord(url: url))

        let crumb = rec.breadcrumb(method: "get", url: url, statusCode: 200, durationMs: 137)
        XCTAssertEqual(crumb.category, "network")
        XCTAssertEqual(crumb.type, "http")
        XCTAssertEqual(crumb.level, .info)
        XCTAssertEqual(crumb.data?["method"], "GET", "method is upper-cased")
        XCTAssertEqual(crumb.data?["host"], "api.example.com")
        XCTAssertEqual(crumb.data?["path"], "/v2/users/42")
        XCTAssertEqual(crumb.data?["status_code"], "200")
        XCTAssertEqual(crumb.data?["duration_ms"], "137")
    }

    /// Status drives the breadcrumb level: 5xx → error, 4xx → warn, 2xx → info, and a
    /// missing status → info.
    func testLevelReflectsStatusCode() {
        XCTAssertEqual(NetworkBreadcrumbRecorder.level(for: 200), .info)
        XCTAssertEqual(NetworkBreadcrumbRecorder.level(for: 404), .warn)
        XCTAssertEqual(NetworkBreadcrumbRecorder.level(for: 503), .error)
        XCTAssertEqual(NetworkBreadcrumbRecorder.level(for: nil), .info)
    }

    /// A failed request (no status) still records, with no `status_code` key.
    func testBreadcrumbWithoutStatusOmitsStatusCode() {
        let rec = makeRecorder()
        let url = URL(string: "https://api.example.com/ping")!
        let crumb = rec.breadcrumb(method: "POST", url: url, statusCode: nil, durationMs: 12)
        XCTAssertNil(crumb.data?["status_code"])
        XCTAssertEqual(crumb.data?["method"], "POST")
        XCTAssertEqual(crumb.data?["duration_ms"], "12")
    }

    // MARK: - Excludes BugWatch's own ingest

    /// The configured endpoint host is never recorded — that's BugWatch's own traffic.
    func testDoesNotRecordConfiguredEndpointHost() {
        let rec = makeRecorder()
        let url = URL(string: "https://api.newinstance.cloud/api/v1/bugwatch/ingest/mobile")!
        XCTAssertFalse(rec.shouldRecord(url: url), "ingest endpoint must be excluded")
    }

    /// Any URL carrying the `/api/v1/bugwatch/` path marker is excluded regardless of
    /// host (covers self-hosted ingest on a different domain, browser ingest, etc.).
    func testDoesNotRecordBugWatchIngestPathOnAnyHost() {
        let rec = makeRecorder()
        let selfHosted = URL(string: "https://telemetry.acme.io/api/v1/bugwatch/ingest/mobile")!
        XCTAssertFalse(rec.shouldRecord(url: selfHosted))
        let browser = URL(string: "https://api.newinstance.cloud/api/v1/bugwatch/ingest/browser")!
        XCTAssertFalse(rec.shouldRecord(url: browser))
    }

    /// A bare host endpoint (no scheme) is still parsed and excluded.
    func testEndpointWithoutSchemeStillExcluded() {
        let rec = NetworkBreadcrumbRecorder(
            endpoint: "ingest.bugwatch.internal:8080",
            allowedHosts: [],
            deniedHosts: []
        )
        let url = URL(string: "https://ingest.bugwatch.internal/some/path")!
        XCTAssertFalse(rec.shouldRecord(url: url), "bare-host endpoint should still be excluded")
    }

    // MARK: - Allow / deny filtering

    /// A non-empty allow-list records only listed hosts.
    func testAllowListRecordsOnlyListedHosts() {
        let rec = makeRecorder(allowed: ["api.example.com"])
        XCTAssertTrue(rec.shouldRecord(url: URL(string: "https://api.example.com/x")!))
        XCTAssertFalse(
            rec.shouldRecord(url: URL(string: "https://other.example.org/x")!),
            "host outside the allow-list is skipped"
        )
    }

    /// The deny-list excludes a host even if it would otherwise be recorded, and even
    /// if it's also in the allow-list (deny wins).
    func testDenyListExcludesHost() {
        let rec = makeRecorder(denied: ["secret.internal"])
        XCTAssertFalse(rec.shouldRecord(url: URL(string: "https://secret.internal/x")!))

        let both = makeRecorder(allowed: ["secret.internal"], denied: ["secret.internal"])
        XCTAssertFalse(
            both.shouldRecord(url: URL(string: "https://secret.internal/x")!),
            "deny-list takes precedence over allow-list"
        )
    }

    /// Host matching is case-insensitive.
    func testHostMatchingIsCaseInsensitive() {
        let rec = makeRecorder(allowed: ["API.Example.COM"])
        XCTAssertTrue(rec.shouldRecord(url: URL(string: "https://api.example.com/x")!))
    }

    /// Non-HTTP(S) schemes are never recorded.
    func testNonHttpSchemesNotRecorded() {
        let rec = makeRecorder()
        XCTAssertFalse(rec.shouldRecord(url: URL(string: "file:///tmp/x")!))
        XCTAssertFalse(rec.shouldRecord(url: URL(string: "ws://api.example.com/socket")!))
        XCTAssertFalse(rec.shouldRecord(url: nil))
    }

    // MARK: - Query string stripping

    /// The query string (and any fragment) is stripped from the recorded path so
    /// tokens/PII in the query never land in a breadcrumb.
    func testQueryStringIsStrippedFromPath() {
        let rec = makeRecorder()
        let url = URL(string: "https://api.example.com/search?q=secret&token=abc123#section")!
        let crumb = rec.breadcrumb(method: "GET", url: url, statusCode: 200, durationMs: 5)
        XCTAssertEqual(crumb.data?["path"], "/search", "query + fragment stripped")
        XCTAssertFalse(crumb.data?["path"]?.contains("token") ?? true)
        XCTAssertFalse(crumb.message?.contains("secret") ?? true, "message also carries the sanitized path")
    }

    /// An empty path normalizes to "/".
    func testEmptyPathBecomesRoot() {
        let rec = makeRecorder()
        let url = URL(string: "https://api.example.com")!
        let crumb = rec.breadcrumb(method: "GET", url: url, statusCode: 204, durationMs: 1)
        XCTAssertEqual(crumb.data?["path"], "/")
    }
}
