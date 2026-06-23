import Foundation

/// Retry/backoff policy for delivery of events to the BugWatch ingest API.
/// `Backoff` uses it to compute exponential-with-jitter delays between failed
/// upload attempts.
public struct RetryPolicy: Sendable, Equatable {
    /// Delay before the first retry, in milliseconds.
    public var initialDelayMs: Int
    /// Upper bound on any single delay, in milliseconds.
    public var maxDelayMs: Int
    /// Maximum number of attempts before an event batch is dropped.
    public var maxAttempts: Int

    public init(initialDelayMs: Int = 200, maxDelayMs: Int = 5_000, maxAttempts: Int = 3) {
        self.initialDelayMs = initialDelayMs
        self.maxDelayMs = maxDelayMs
        self.maxAttempts = maxAttempts
    }
}
