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
        spanId: String? = nil
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
    }
}
