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
    /// Raw, unparsed platform stacktrace text. Carries a Flutter OBFUSCATED
    /// (address-form) Dart trace — header + frames — verbatim so the backend can
    /// resolve it with `flutter symbolize`. Nil for everything else (omitted from
    /// JSON when nil).
    public var rawStacktrace: String?

    public init(type: String, value: String, stacktrace: [StackFrame]? = nil, rawStacktrace: String? = nil) {
        self.type = type
        self.value = value
        self.stacktrace = stacktrace
        self.rawStacktrace = rawStacktrace
    }
}

/// One loaded Mach-O binary image at crash time — the structured input Sentry
/// Symbolicator needs to resolve a native frame's `instruction_addr` against an
/// uploaded dSYM. Wire keys follow the native debug-meta contract (snake_case).
public struct BinaryImage: Codable, Sendable, Equatable {
    public var name: String
    /// Normalized lowercase hyphenated UUID (the image's `LC_UUID` → debug id).
    public var debugId: String
    public var arch: String
    /// Image load (mapped header) address, lowercase `0x…` hex.
    public var imageAddr: String
    /// `__TEXT` virtual size in bytes (preserved as a 64-bit integer).
    public var imageSize: UInt64?
    /// True for the main executable image.
    public var isMainImage: Bool?

    enum CodingKeys: String, CodingKey {
        case name, arch
        case debugId = "debug_id"
        case imageAddr = "image_addr"
        case imageSize = "image_size"
        case isMainImage = "is_main_image"
    }

    public init(name: String, debugId: String, arch: String, imageAddr: String, imageSize: UInt64? = nil, isMainImage: Bool? = nil) {
        self.name = name
        self.debugId = debugId
        self.arch = arch
        self.imageAddr = imageAddr
        self.imageSize = imageSize
        self.isMainImage = isMainImage
    }
}

/// One structured native stack frame. `instruction_addr` is the raw program
/// counter (lowercase `0x…` hex, full 64-bit precision); the backend matches it
/// to a `BinaryImage` by address range and resolves it via Symbolicator. The
/// original `backtrace_symbols` line is preserved in `raw_symbol`.
public struct NativeFrame: Codable, Sendable, Equatable {
    public var frameIndex: Int
    public var instructionAddr: String
    public var imageAddr: String?
    public var imageName: String?
    public var rawSymbol: String?
    public var inApp: Bool?

    enum CodingKeys: String, CodingKey {
        case frameIndex = "frame_index"
        case instructionAddr = "instruction_addr"
        case imageAddr = "image_addr"
        case imageName = "image_name"
        case rawSymbol = "raw_symbol"
        case inApp = "in_app"
    }

    public init(frameIndex: Int, instructionAddr: String, imageAddr: String? = nil, imageName: String? = nil, rawSymbol: String? = nil, inApp: Bool? = nil) {
        self.frameIndex = frameIndex
        self.instructionAddr = instructionAddr
        self.imageAddr = imageAddr
        self.imageName = imageName
        self.rawSymbol = rawSymbol
        self.inApp = inApp
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
    /// Loaded Mach-O images at crash time (native iOS/macOS crashes, payload v2).
    public var binaryImages: [BinaryImage]?
    /// Structured native frames with raw instruction addresses (payload v2).
    public var nativeStacktrace: [NativeFrame]?
    /// The crashing thread id, when known.
    public var crashedThreadId: Int?
    /// Crash payload version. 2 ⇒ carries structured `binaryImages` +
    /// `nativeStacktrace` for offline symbolication; nil/1 ⇒ legacy.
    public var payloadVersion: Int?

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
        session: SessionInfo? = nil,
        binaryImages: [BinaryImage]? = nil,
        nativeStacktrace: [NativeFrame]? = nil,
        crashedThreadId: Int? = nil,
        payloadVersion: Int? = nil
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
        self.binaryImages = binaryImages
        self.nativeStacktrace = nativeStacktrace
        self.crashedThreadId = crashedThreadId
        self.payloadVersion = payloadVersion
    }
}
