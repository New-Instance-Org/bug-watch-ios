import Foundation

/// Configuration for the BugWatch SDK. Mirrors the canonical options used by
/// the JavaScript (`@newinstance/bugwatch`) and PHP SDKs.
public struct BugWatchOptions: Sendable {
    /// BugWatch project public id — sent as the token `pid` claim.
    public var projectId: String
    /// Per-project secret (base64url string) used as the HMAC key when signing
    /// the ingest token. **Never transmitted** — only the signed token is sent.
    public var appSecret: String
    /// Ingest API base URL. Override only for self-hosted / dev backends.
    public var endpoint: String
    /// Environment tag (e.g. "production", "staging") — sent as the token `env`
    /// claim and stamped on every event.
    public var environment: String
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
    /// Emit release-health session signals (Sentry-style): an `ok` event when a
    /// run starts and a `crashed`/`exited` event for the prior run on the next
    /// launch. Session events bypass sampling so crash-free rates stay accurate.
    public var autoSessionTracking: Bool
    /// Watch the main thread for stalls and emit a non-fatal `AppHang` event when
    /// it is unresponsive for ≥ `appHangThresholdMs`. Hangs do not terminate the
    /// app (distinct from crash capture). Runs entirely off the main thread.
    public var enableAppHangTracking: Bool
    /// How long (ms) the main thread must be continuously unresponsive before a
    /// hang is reported. Only used when `enableAppHangTracking` is true.
    public var appHangThresholdMs: Int
    /// Automatically record **app-lifecycle** breadcrumbs (foreground/background
    /// transitions, memory warnings) into the breadcrumb buffer that crash/error
    /// events attach. No-op on platforms without UIKit.
    public var enableAutoBreadcrumbs: Bool
    /// Automatically record a **network** breadcrumb per outbound HTTP(S) request
    /// (method, host, path, status, duration). Installs a global `URLProtocol`, so
    /// it only covers `URLSession.shared` + sessions built from the default
    /// configuration. BugWatch's own ingest requests are always excluded.
    public var enableNetworkBreadcrumbs: Bool
    /// Optional allow-list of hosts for network breadcrumbs. Empty = record every
    /// host (except BugWatch's own ingest, which is always excluded). When
    /// non-empty, only these hosts are recorded.
    public var networkBreadcrumbAllowedHosts: [String]
    /// Optional deny-list of hosts that are never recorded as network breadcrumbs.
    /// Takes precedence over the allow-list.
    public var networkBreadcrumbDeniedHosts: [String]

    public init(
        projectId: String,
        appSecret: String,
        endpoint: String = "https://api.newinstance.cloud",
        environment: String = "production",
        release: String? = nil,
        enabled: Bool = true,
        debug: Bool = false,
        sampleRate: Double = 1.0,
        sensitiveFields: [String] = BugWatchOptions.defaultSensitiveFields,
        maxQueueSize: Int = 1000,
        batchSize: Int = 50,
        flushIntervalMs: Int = 5000,
        requestTimeoutMs: Int = 15000,
        retry: RetryPolicy = RetryPolicy(),
        autoSessionTracking: Bool = true,
        enableAppHangTracking: Bool = true,
        appHangThresholdMs: Int = 2000,
        enableAutoBreadcrumbs: Bool = true,
        enableNetworkBreadcrumbs: Bool = true,
        networkBreadcrumbAllowedHosts: [String] = [],
        networkBreadcrumbDeniedHosts: [String] = []
    ) {
        self.projectId = projectId
        self.appSecret = appSecret
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
        self.autoSessionTracking = autoSessionTracking
        self.enableAppHangTracking = enableAppHangTracking
        self.appHangThresholdMs = appHangThresholdMs
        self.enableAutoBreadcrumbs = enableAutoBreadcrumbs
        self.enableNetworkBreadcrumbs = enableNetworkBreadcrumbs
        self.networkBreadcrumbAllowedHosts = networkBreadcrumbAllowedHosts
        self.networkBreadcrumbDeniedHosts = networkBreadcrumbDeniedHosts
    }

    /// Default keys redacted from event payloads (case-insensitive).
    public static let defaultSensitiveFields: [String] = [
        "password", "passwd", "pwd", "token", "accesstoken", "refreshtoken",
        "idtoken", "authorization", "auth", "cookie", "setcookie", "secret",
        "clientsecret", "apikey", "privatekey", "sessionid", "ssn",
        "creditcard", "cardnumber", "cvv", "pin", "nin", "bvn",
    ]
}
