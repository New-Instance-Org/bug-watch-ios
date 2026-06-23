# BugWatch — iOS SDK

Native Swift SDK for the [BugWatch](https://newinstance.cloud) observability
platform. Capture crashes, handled errors, and logs from your iOS app.

> **Status:** early skeleton. The public API is stable; event **delivery**,
> crash/ANR capture, device context, and session tracking are being
> implemented. Today, captured events are normalized and queued in memory.

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
    projectKey: "<keyId>:<secret>",
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

// Flush before shutdown
BugWatch.flush()
```

## Configuration

`BugWatchOptions` fields: `projectKey` (required), `endpoint`
(default `https://api.newinstance.cloud`), `environment`, `release`,
`enabled`, `debug`, `sampleRate`, `sensitiveFields`, `maxQueueSize`,
`batchSize`, `flushIntervalMs`, `requestTimeoutMs`, `retry`.

## Diagnostics

Enable `debug: true` and install a handler to see the SDK's internal log:

```swift
BugWatchDiagnosticLog.setHandler { line in print(line) }
```

## License

MIT — see [LICENSE](./LICENSE).
