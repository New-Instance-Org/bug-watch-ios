import Foundation

/// Configuration for the BugWatch SDK. Mirrors the canonical options used by
/// the JavaScript (`@newinstance/bugwatch`) and PHP SDKs.
public struct BugWatchOptions: Sendable {
    /// Central ingest key `<keyId>:<secret>` (sk_test_… / sk_live_…).
    public var projectKey: String
    /// Ingest API base URL. Override only for self-hosted / dev backends.
    public var endpoint: String
    /// Informational environment tag (e.g. "production", "staging").
    public var environment: String?
    /// Release / build identifier (e.g. "1.4.2+318").
    public var release: String?
    /// Master switch; when false the SDK collects and sends nothing.
    public var enabled: Bool
    /// Emit internal diagnostic lines via `BugWatchDiagnosticLog`.
    public var debug: Bool
    /// Fraction of events to keep, 0.0–1.0.
    public var sampleRate: Double
    /// Case-insensitive keys whose values are redacted before sending.
    public var sensitiveFields: [String]
    /// Maximum number of pending events held before the oldest are dropped.
    public var maxQueueSize: Int
    /// Number of events delivered per ingest request.
    public var batchSize: Int
    /// Auto-flush cadence in milliseconds (0 disables the timer).
    public var flushIntervalMs: Int
    /// Per-request network timeout in milliseconds.
    public var requestTimeoutMs: Int
    /// Retry policy for failed ingest requests.
    public var retry: RetryPolicy

    public init(
        projectKey: String,
        endpoint: String = "https://api.newinstance.cloud",
        environment: String? = nil,
        release: String? = nil,
        enabled: Bool = true,
        debug: Bool = false,
        sampleRate: Double = 1.0,
        sensitiveFields: [String] = BugWatchOptions.defaultSensitiveFields,
        maxQueueSize: Int = 1000,
        batchSize: Int = 50,
        flushIntervalMs: Int = 5000,
        requestTimeoutMs: Int = 15000,
        retry: RetryPolicy = RetryPolicy()
    ) {
        self.projectKey = projectKey
        self.endpoint = endpoint
        self.environment = environment
        self.release = release
        self.enabled = enabled
        self.debug = debug
        self.sampleRate = sampleRate
        self.sensitiveFields = sensitiveFields
        self.maxQueueSize = maxQueueSize
        self.batchSize = batchSize
        self.flushIntervalMs = flushIntervalMs
        self.requestTimeoutMs = requestTimeoutMs
        self.retry = retry
    }

    /// Default keys redacted from event payloads (case-insensitive).
    public static let defaultSensitiveFields: [String] = [
        "password", "passwd", "pwd", "token", "accesstoken", "refreshtoken",
        "idtoken", "authorization", "auth", "cookie", "setcookie", "secret",
        "clientsecret", "apikey", "privatekey", "sessionid", "ssn",
        "creditcard", "cardnumber", "cvv", "pin", "nin", "bvn",
    ]
}
