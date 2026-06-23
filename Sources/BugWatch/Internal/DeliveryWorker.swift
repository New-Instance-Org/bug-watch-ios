import Foundation

/// Serial delivery pump. Drains the persistent queue in `batchSize` chunks,
/// signs a **fresh** ingest token per attempt, POSTs the NDJSON batch, and on
/// success removes the delivered records. Retryable failures back off
/// (`Backoff`/`RetryPolicy`); a batch that exhausts `maxAttempts` or is rejected
/// (`.drop`) is discarded so it can never wedge the pipe.
///
/// Being an `actor` guarantees only one drain runs at a time even when nudged
/// concurrently from capture / timer / network-online.
actor DeliveryWorker {
    private let signer: TokenSigner
    private let transport: HttpTransport
    private let queue: PersistentEventQueue
    private let pid: String
    private let env: String
    private let batchSize: Int
    private let retry: RetryPolicy
    private let log: (String) -> Void

    /// Sleep hook — injectable so tests can run without real delays.
    private let sleep: (UInt64) async -> Void

    private var draining = false

    init(
        signer: TokenSigner,
        transport: HttpTransport,
        queue: PersistentEventQueue,
        pid: String,
        env: String,
        batchSize: Int,
        retry: RetryPolicy,
        log: @escaping (String) -> Void = { _ in },
        sleep: @escaping (UInt64) async -> Void = { ns in try? await Task.sleep(nanoseconds: ns) }
    ) {
        self.signer = signer
        self.transport = transport
        self.queue = queue
        self.pid = pid
        self.env = env
        self.batchSize = max(1, batchSize)
        self.retry = retry
        self.log = log
        self.sleep = sleep
    }

    /// Drains until the queue is empty or a batch must wait/stop. Re-entrant
    /// calls while a drain is in flight are coalesced (the running drain will
    /// pick up anything newly enqueued before it exits).
    func drain() async {
        if draining { return }
        draining = true
        defer { draining = false }

        while true {
            let records = queue.loadPending(limit: batchSize)
            if records.isEmpty { break }

            let delivered = await deliverWithRetry(records)
            if delivered {
                queue.removeDelivered(eventIds: records.map { $0.eventId })
                log("delivered \(records.count) event(s)")
            } else {
                // Non-recoverable (.drop or attempts exhausted) — discard so the
                // queue can make forward progress instead of looping forever.
                queue.removeDelivered(eventIds: records.map { $0.eventId })
                log("dropped \(records.count) undeliverable event(s)")
            }
        }
    }

    /// Attempts one batch, retrying retryable failures with backoff up to
    /// `maxAttempts`. Returns `true` on success, `false` if the batch should be
    /// discarded (dropped or attempts exhausted).
    private func deliverWithRetry(_ records: [PersistentEventQueue.Record]) async -> Bool {
        let body = Data((records.map { $0.line }.joined(separator: "\n") + "\n").utf8)
        let maxAttempts = max(1, retry.maxAttempts)

        var attempt = 0
        while attempt < maxAttempts {
            let token = signer.signNow(pid: pid, env: env)   // fresh token per attempt
            let result = await transport.send(ndjsonBody: body, token: token)
            switch result {
            case .success:
                return true
            case .drop:
                return false
            case .retryable:
                attempt += 1
                if attempt >= maxAttempts { return false }
                let delayMs = Backoff.delayMillis(policy: retry, attempt: attempt - 1)
                log("retryable failure, attempt \(attempt)/\(maxAttempts), backing off \(delayMs)ms")
                await sleep(UInt64(max(0, delayMs)) * 1_000_000)
            }
        }
        return false
    }
}
