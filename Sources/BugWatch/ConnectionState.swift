import Foundation

/// Transport-level connection state for the BugWatch delivery pipeline.
public enum ConnectionState: String, Codable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected
    case offline
    case rejected
}

/// Coarse SDK lifecycle exposed to the host so it can reason about whether
/// BugWatch has started and is ready to accept events.
public enum BugWatchLifecycle: String, Codable, Sendable {
    case notStarted = "not_started"
    case initializing
    case ready
    case unavailable
    case failed
}

/// Result of one connectivity check against BugWatch, either an explicit
/// `testConnection()` or the automatic handshake performed on start.
public struct ConnectionCheck: Sendable, Equatable {
    public let state: ConnectionState
    public let httpStatus: Int?
    public let reason: String?
    public let hint: String?
    public let serverTimeMs: Int64?
    public let clockSkewMs: Int64?
    public let checkedAt: Date

    public init(state: ConnectionState, httpStatus: Int? = nil, reason: String? = nil, hint: String? = nil,
                serverTimeMs: Int64? = nil, clockSkewMs: Int64? = nil, checkedAt: Date = Date()) {
        self.state = state
        self.httpStatus = httpStatus
        self.reason = reason
        self.hint = hint
        self.serverTimeMs = serverTimeMs
        self.clockSkewMs = clockSkewMs
        self.checkedAt = checkedAt
    }
}

struct TransportOutcome: Sendable {
    let result: TransportResult
    let httpStatus: Int?
    let reason: String?
    let hint: String?
    let error: String?
}

final class TransportOutcomeSink: @unchecked Sendable {
    var handler: (@Sendable (TransportOutcome) -> Void)?
    init() {}
}
