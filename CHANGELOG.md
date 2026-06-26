# Changelog

All notable changes to the BugWatch iOS SDK are documented here.

---

## [0.1.0] — 2026-06-24

Initial release.

### Added

- `BugWatch.start(options:)` — SDK initializer; idempotent, installs all handlers
- `BugWatchOptions` — full configuration struct with all fields:
  - `projectId`, `appSecret`, `endpoint`, `environment`, `release`
  - `enabled`, `debug`, `sampleRate`, `sensitiveFields`
  - `autoSessionTracking`, `enableAppHangTracking`, `appHangThresholdMs`
  - `enableAutoBreadcrumbs`, `enableNetworkBreadcrumbs`
  - `networkBreadcrumbAllowedHosts`, `networkBreadcrumbDeniedHosts`
  - `maxQueueSize`, `batchSize`, `flushIntervalMs`, `requestTimeoutMs`, `retry`
- **Native crash capture** — async-signal-safe signal handler (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP/SIGSYS) + NSException handler; crash artifact processed on next launch into a `.fatal` event with binary-images + instruction-address payload v2 for Symbolicator-based resolution
- **App-hang / ANR detection** — background watchdog detects main-thread stalls ≥ `appHangThresholdMs` and emits a non-fatal `AppHang` event; bypasses sampling
- **Release-health sessions** — Sentry-style `ok`/`exited`/`crashed` session events; bypass sampling; persisted across launches so the prior run's terminal status is always correct
- `BugWatch.capture(error:)` — capture a handled `Error`
- `BugWatch.captureMessage(_:level:)` — capture a plain message at any `Severity` level
- `BugWatch.setUser(_:)` — identify the current user (`BugWatchUser`: id/email/username/ip); pass `nil` on logout
- `BugWatch.setTag(key:value:)` — attach a string tag to all subsequent events
- `BugWatch.setContext(_:value:)` — attach freeform context
- `BugWatch.setRelease(_:)` — update the release identifier post-init (also updates the crash sidecar)
- `BugWatch.addBreadcrumb(_:)` — append a manual breadcrumb; `Breadcrumb`: category/type/level/message/data
- **Auto-breadcrumbs** — app lifecycle transitions (foreground/background/memory warning) via UIApplication notifications; opt-out with `enableAutoBreadcrumbs: false`
- **Network breadcrumbs** — one breadcrumb per outbound `URLSession.shared` HTTP(S) request via global `URLProtocol`; allow/deny-list filtering; BugWatch own ingest always excluded; opt-out with `enableNetworkBreadcrumbs: false`
- `BugWatch.flush()` — async drain; `BugWatch.flush(completion:)` — fire-and-forget variant
- `BugWatch.close()` — full SDK teardown: restores prior crash handlers, uninstalls auto-instrumentation, clears sidecar and session descriptor
- `BugWatch.didCrashOnPreviousExecution` — static Bool readable before `start()`; reflects whether the immediately prior run ended in a native crash
- `BugWatchDiagnosticLog.setHandler(_:)` — install a custom handler for internal `[BugWatch] …` log lines (requires `debug: true`)
- Disk-backed NDJSON event queue with configurable capacity; survives app restarts
- Delivery worker: `batchSize`-chunked NDJSON POSTs to `/api/v1/bugwatch/ingest/mobile` with `x-bugwatch-token` (HMAC-SHA256, 5-min expiry, signed on-device); exponential-backoff retry on 5xx/429/network failures; connectivity-aware (resumes when the network returns)
- Sensitive-field redaction applied before events are written to disk; default list covers common credential/PII field names
- `Severity` enum: `.trace` (10) `.debug` (20) `.info` (30) `.warn` (40) `.error` (50) `.fatal` (60); values match the BugWatch platform wire contract
- `captureWrapperException(type:value:frames:level:platform:rawStacktrace:)` — internal method for React Native and Flutter bridges
- CocoaPods support: `pod 'BugWatch', '~> 0.1'`; uses system `CryptoKit` (no extra deps)
- Swift Package Manager support: `swift-crypto` dependency for HMAC-SHA256
- iOS 14+ and macOS 11+ platform support
