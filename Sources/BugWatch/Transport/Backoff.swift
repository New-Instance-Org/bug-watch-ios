import Foundation

/// Exponential-with-jitter backoff calculator. base = min(initial × 2^attempt,
/// max); the final delay is scaled by a [0.5, 1.0] jitter factor to spread
/// retry storms across clients.
enum Backoff {
    /// Returns the delay in **milliseconds** for the given attempt number.
    /// `attempt` starts at 0 for the first retry.
    static func delayMillis(
        policy: RetryPolicy,
        attempt: Int,
        randomFactor: Double = .random(in: 0.5...1.0)
    ) -> Int64 {
        let safeAttempt = min(max(attempt, 0), 30)
        let multiplier = Int64(1) << safeAttempt
        let base = min(Int64(policy.initialDelayMs) * multiplier, Int64(policy.maxDelayMs))
        let jittered = Double(base) * randomFactor
        return Int64(max(0, jittered))
    }
}
