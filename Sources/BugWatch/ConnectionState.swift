import Foundation

/// Transport-level connection state for the BugWatch delivery pipeline.
public enum ConnectionState: String, Codable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected
    case offline
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
