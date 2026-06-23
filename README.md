# BugWatch — iOS SDK

Native Swift SDK for the [BugWatch](https://newinstance.cloud) observability
platform. Capture crashes, handled errors, and logs from your iOS app.

> **Status:** captured events are now **delivered** — they are normalized,
> redacted, persisted to a disk-backed queue, and POSTed to the BugWatch mobile
> ingest endpoint with a locally-signed, short-lived token (your `appSecret`
> never leaves the device). Device + install/session context are attached
> automatically. Crash/ANR capture is the next milestone.

## Requirements

- iOS 14.0+
- Swift 5.9 (Xcode 15+)

## Install

### Swift Package Manager

```swift
.package(url: "https://github.com/talktothelaw/bug-watch-ios.git", from: "0.1.0")
```

### CocoaPods

```ruby
pod 'BugWatch', '~> 0.1'
```

## Quick start

```swift
import BugWatch

BugWatch.start(options: BugWatchOptions(
    projectId: "<your-project-id>",
    appSecret: "<your-project-app-secret>",
    environment: "production",
    release: "1.0.0+1"
))

// Handled error
BugWatch.capture(error: error)

// Message
BugWatch.captureMessage("Payment completed", level: .info)

// Identify the user (clear with nil on logout)
BugWatch.setUser(BugWatchUser(id: "customer-id", email: "customer@example.com"))

// Context
BugWatch.setTag(key: "payment_provider", value: "paystack")
BugWatch.addBreadcrumb(Breadcrumb(category: "ui", message: "Tapped checkout"))

// Flush before shutdown (awaitable)
await BugWatch.flush()
// …or fire-and-forget with an optional completion:
BugWatch.flush { /* done */ }
```

> `appSecret` is your project's signing secret. The SDK uses it only to sign a
> short-lived `x-bugwatch-token` locally (HMAC-SHA256) — **the secret is never
> transmitted**.

## Configuration

`BugWatchOptions` fields: `projectId` (required), `appSecret` (required),
`endpoint` (default `https://api.newinstance.cloud`), `environment`
(default `"production"`), `release`, `enabled`, `debug`, `sampleRate`,
`sensitiveFields`, `maxQueueSize`, `batchSize`, `flushIntervalMs`,
`requestTimeoutMs`, `retry`.

## How delivery works

1. Each `capture*` builds an event with device, install id, session id, release,
   environment, tags, user, and breadcrumbs — then redacts any
   `sensitiveFields` values and appends it to a disk-backed NDJSON queue
   (survives app restarts, bounded by `maxQueueSize` + max age).
2. A serial worker drains the queue in `batchSize` chunks, signs a fresh token,
   and POSTs `application/x-ndjson` to
   `{endpoint}/api/v1/bugwatch/ingest/mobile`.
3. Delivery is retried with exponential backoff on `5xx`/`429`/network errors
   (`retry` policy), runs on the `flushIntervalMs` timer, and resumes
   automatically when connectivity returns.

## Diagnostics

Enable `debug: true` and install a handler to see the SDK's internal log:

```swift
BugWatchDiagnosticLog.setHandler { line in print(line) }
```

## License

MIT — see [LICENSE](./LICENSE).
