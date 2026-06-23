import XCTest
@testable import BugWatch

final class BackoffTests: XCTestCase {
    func testGrowsExponentiallyAndIsCapped() {
        let policy = RetryPolicy(initialDelayMs: 1000, maxDelayMs: 30_000, maxAttempts: .max)
        // Deterministic jitter factor of 0.75.
        XCTAssertEqual(Backoff.delayMillis(policy: policy, attempt: 0, randomFactor: 0.75), 750)
        XCTAssertEqual(Backoff.delayMillis(policy: policy, attempt: 1, randomFactor: 0.75), 1500)
        XCTAssertEqual(Backoff.delayMillis(policy: policy, attempt: 2, randomFactor: 0.75), 3000)
        // attempt 10 hits the cap (1000 << 10 = 1,024,000 > 30,000) → 30000 × 0.75 = 22500
        XCTAssertEqual(Backoff.delayMillis(policy: policy, attempt: 10, randomFactor: 0.75), 22_500)
    }

    func testJitterRespectsBounds() {
        let policy = RetryPolicy(initialDelayMs: 1000, maxDelayMs: 30_000)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let factor = Double.random(in: 0.5...1.0, using: &rng)
            let delay = Backoff.delayMillis(policy: policy, attempt: 1, randomFactor: factor)
            XCTAssertGreaterThanOrEqual(delay, 1000)
            XCTAssertLessThanOrEqual(delay, 2000)
        }
    }
}
