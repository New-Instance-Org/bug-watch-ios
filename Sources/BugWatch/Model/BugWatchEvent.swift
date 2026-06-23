import Foundation

/// One normalized stack frame. `in_app` distinguishes the merchant's own code
/// from framework/system frames.
public struct StackFrame: Codable, Sendable, Equatable {
    public var filename: String?
    public var function: String?
    public var lineno: Int?
    public var colno: Int?
    public var inApp: Bool?

    enum CodingKeys: String, CodingKey {
        case filename, function, lineno, colno
        case inApp = "in_app"
    }

    public init(filename: String? = nil, function: String? = nil, lineno: Int? = nil, colno: Int? = nil, inApp: Bool? = nil) {
        self.filename = filename
        self.function = function
        self.lineno = lineno
        self.colno = colno
        self.inApp = inApp
    }
}

/// A normalized exception.
public struct NormalizedException: Codable, Sendable, Equatable {
    public var type: String
    public var value: String
    public var stacktrace: [StackFrame]?

    public init(type: String, value: String, stacktrace: [StackFrame]? = nil) {
        self.type = type
        self.value = value
        self.stacktrace = stacktrace
    }
}

/// SDK identity carried on every event.
public struct SdkInfo: Codable, Sendable, Equatable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Release-health session signal carried on a session event. One "session" is a
/// single SDK run (`start` → terminate/crash). The backend aggregates these into
/// crash-free session/user rates, so an event with a populated `session` is a
/// session signal rather than an error report.
public struct SessionInfo: Codable, Sendable, Equatable {
    /// The session id this signal refers to (equals the run's `sessionId`).
    public var id: String
    /// Session outcome: `ok` (session opened/healthy), `crashed` (the prior run
    /// ended in a native crash), or `exited` (the prior run ended cleanly).
    public var status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

/// The on-the-wire BugWatch event. Field names match the NDJSON ingest
/// contract shared by all BugWatch SDKs.
public struct BugWatchEvent: Codable, Sendable, Equatable {
    public var eventId: String
    public var time: Int64            // unix milliseconds
    public var level: Int             // Severity.rawValue
    public var message: String?
    public var exception: NormalizedException?
    public var fingerprint: [String]?
    public var release: String?
    public var environment: String?
    public var tags: [String: String]?
    public var user: BugWatchUser?
    public var breadcrumbs: [Breadcrumb]?
    public var sdk: SdkInfo
    public var traceId: String?
    public var spanId: String?
    /// Originating platform — always "ios" for this SDK.
    public var platform: String?
    /// Stable per-install identifier (UUID persisted in UserDefaults).
    public var installId: String?
    /// Identifier for the current SDK session (one per `start`).
    public var sessionId: String?
    /// Device / runtime context.
    public var device: DeviceInfo?
    /// Release-health session signal. Non-nil only on session events emitted by
    /// auto session tracking; nil on ordinary error/message/crash events.
    public var session: SessionInfo?

    public init(
        eventId: String,
        time: Int64,
        level: Int,
        message: String? = nil,
        exception: NormalizedException? = nil,
        fingerprint: [String]? = nil,
        release: String? = nil,
        environment: String? = nil,
        tags: [String: String]? = nil,
        user: BugWatchUser? = nil,
        breadcrumbs: [Breadcrumb]? = nil,
        sdk: SdkInfo,
        traceId: String? = nil,
        spanId: String? = nil,
        platform: String? = nil,
        installId: String? = nil,
        sessionId: String? = nil,
        device: DeviceInfo? = nil,
        session: SessionInfo? = nil
    ) {
        self.eventId = eventId
        self.time = time
        self.level = level
        self.message = message
        self.exception = exception
        self.fingerprint = fingerprint
        self.release = release
        self.environment = environment
        self.tags = tags
        self.user = user
        self.breadcrumbs = breadcrumbs
        self.sdk = sdk
        self.traceId = traceId
        self.spanId = spanId
        self.platform = platform
        self.installId = installId
        self.sessionId = sessionId
        self.device = device
        self.session = session
    }
}
