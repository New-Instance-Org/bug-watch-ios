# BugWatch — iOS SDK

Native Swift SDK for the [BugWatch](https://newinstance.cloud) observability platform.

Capture native crashes, app hangs, handled errors, and release-health sessions from your iOS or macOS app — fully symbolicated in the BugWatch dashboard via dSYM upload.

---

## Supported platforms

| Platform | Minimum version | Package managers |
|----------|----------------|-----------------|
| iOS      | 14.0+          | SPM, CocoaPods  |
| macOS    | 11.0+          | SPM only        |

> **CocoaPods installs iOS only.** The `BugWatch.podspec` declares the iOS platform; macOS (11.0+) is supported exclusively via Swift Package Manager.

## Requirements

- Swift 5.9 / Xcode 15 or later
- Swift Package Manager **or** CocoaPods (iOS only)

---

## Install

### Swift Package Manager

Add the dependency in `Package.swift`:

```swift
.package(url: "https://github.com/New-Instance-Org/bug-watch-ios.git", from: "0.1.0")
```

Or in Xcode: **File → Add Package Dependencies** and paste the URL above.

This method supports both **iOS 14.0+** and **macOS 11.0+**.

### CocoaPods (iOS only)

```ruby
pod 'BugWatch', '~> 0.1'
```

Then run `pod install`.

---

## Get your credentials

1. Open the merchant dashboard at [https://newinstance.cloud](https://newinstance.cloud).
2. Go to **BugWatch → Your project → Settings → Mobile credentials**.
3. Copy your **Project ID** (`projectId`) and **App Secret** (`appSecret`).

The `appSecret` is used on-device to sign a short-lived ingest token (HMAC-SHA256). It is **never transmitted** — only the signed token is sent with each batch.

---

## Initialize the SDK

Call `BugWatch.start(options:)` as early as possible so crash handlers are installed before any crash can occur.

### SwiftUI (`@main` App)

```swift
import SwiftUI
import BugWatch

@main
struct MyApp: App {
    init() {
        BugWatch.start(options: BugWatchOptions(
            projectId: "your-project-id",
            appSecret: "your-app-secret",
            environment: "production",
            release: "1.4.2+318"
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

### UIKit (`AppDelegate`)

```swift
import UIKit
import BugWatch

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        BugWatch.start(options: BugWatchOptions(
            projectId: "your-project-id",
            appSecret: "your-app-secret",
            environment: "production",
            release: "1.4.2+318"
        ))
        return true
    }
}
```

---

## All configuration options

`BugWatchOptions` accepts the following parameters (all have defaults except `projectId` and `appSecret`):

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `projectId` | `String` | **required** | Your BugWatch project ID |
| `appSecret` | `String` | **required** | Per-project signing secret — never transmitted |
| `endpoint` | `String` | `"https://api.newinstance.cloud"` | Override only for self-hosted or dev backends |
| `environment` | `String` | `"production"` | Stamped on every event and ingest token |
| `release` | `String?` | `nil` | Build identifier, e.g. `"1.4.2+318"` |
| `enabled` | `Bool` | `true` | Master switch — when `false`, no events are collected or sent |
| `debug` | `Bool` | `false` | Emit internal SDK log lines via `BugWatchDiagnosticLog` |
| `sampleRate` | `Double` | `1.0` | Fraction of events to keep (0.0–1.0). Crash, hang, and session events always bypass sampling |
| `sensitiveFields` | `[String]` | see below | Case-insensitive field names redacted before events touch disk |
| `maxQueueSize` | `Int` | `1000` | Max events held in the disk-backed queue; oldest are dropped when full |
| `batchSize` | `Int` | `50` | Events delivered per ingest request |
| `flushIntervalMs` | `Int` | `5000` | Auto-flush timer cadence in milliseconds (`0` disables) |
| `requestTimeoutMs` | `Int` | `15000` | Per-request network timeout in milliseconds |
| `retry` | `RetryPolicy` | backoff defaults | Retry policy for failed ingest requests |
| `autoSessionTracking` | `Bool` | `true` | Emit release-health session signals (open/closed/crashed) |
| `enableAppHangTracking` | `Bool` | `true` | Detect main-thread stalls and emit a non-fatal `AppHang` event |
| `appHangThresholdMs` | `Int` | `2000` | Milliseconds the main thread must stall before a hang is reported |
| `enableAutoBreadcrumbs` | `Bool` | `true` | Auto-record app-lifecycle breadcrumbs (foreground/background/memory-warning) |
| `enableNetworkBreadcrumbs` | `Bool` | `true` | Auto-record one breadcrumb per outbound HTTP(S) request |
| `networkBreadcrumbAllowedHosts` | `[String]` | `[]` | If non-empty, only these hosts are recorded as network breadcrumbs |
| `networkBreadcrumbDeniedHosts` | `[String]` | `[]` | Hosts never recorded as network breadcrumbs (takes precedence over allow-list) |

**Default sensitive fields** (case-insensitive): `password`, `passwd`, `pwd`, `token`, `accesstoken`, `refreshtoken`, `idtoken`, `authorization`, `auth`, `cookie`, `setcookie`, `secret`, `clientsecret`, `apikey`, `privatekey`, `sessionid`, `ssn`, `creditcard`, `cardnumber`, `cvv`, `pin`, `nin`, `bvn`.

---

## Capturing handled errors and messages

```swift
// Capture a Swift Error (e.g. from a catch block)
do {
    try riskyOperation()
} catch {
    BugWatch.capture(error: error)
}

// Capture a plain message at a given severity level
BugWatch.captureMessage("Payment completed", level: .info)
BugWatch.captureMessage("Quota almost exceeded", level: .warn)
```

Both methods return a `String` event ID (`@discardableResult`) you can log or cross-reference.

**Severity levels** (numeric values match the BugWatch wire contract): `.trace` (10), `.debug` (20), `.info` (30), `.warn` (40), `.error` (50), `.fatal` (60).

---

## Native crash capture

The SDK installs crash handlers automatically when `start(options:)` is called and `enabled` is `true`. No extra code is required.

**What is captured:**

- **Fatal signals** — `SIGSEGV`, `SIGABRT`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGTRAP`, `SIGSYS`. The signal handler is strictly async-signal-safe (uses only `open`/`write`/`backtrace`/`backtrace_symbols_fd`, no Swift runtime, no `malloc`). It writes a compact artifact to disk and then re-raises the signal so the OS still records its own crash report.
- **Uncaught NSExceptions** — handled in a normal context, so the artifact includes the exception name, reason, and symbolicated call stack.
- **Swift runtime traps**: `fatalError`, force-unwrapping `nil`, array index out of range, and failed `precondition`/`assert` all trap through `SIGTRAP`, so they arrive as ordinary signal crashes.
- **Stack overflows**, see below.

**Stack overflows.** A stack overflow is the one crash class a plain signal handler cannot report: the crashing thread has no stack left for the kernel to deliver the signal on, so the process dies before the handler's first instruction. The SDK registers a dedicated alternate signal stack (`sigaltstack`) and sets `SA_ONSTACK` on every trapped signal, giving the kernel somewhere else to build the signal frame. `sigaltstack` is per-thread and the SDK registers it on the thread that calls `start(options:)`, which is the main thread in normal use, so a stack overflow on a background thread is still missed.

**Chaining.** Both the signal handler and the `NSException` handler save whatever was installed before them and call it afterwards, so BugWatch runs alongside Crashlytics, Bugsnag, or any other reporter without either one losing crashes. The OS still writes its own crash report either way.

**What is not captured.** These are platform limits, not SDK limits, and no iOS crash reporter captures them:

| Not captured | Why |
|---|---|
| Out-of-memory kills and watchdog terminations | The system sends `SIGKILL`, which no handler can intercept. The prior session is finalized `exited`, so crash-free rate reads slightly optimistic |
| The user force-quitting the app | Indistinguishable from a clean exit |
| Anything before `start(options:)` runs | Handlers are armed by `start`. Call it as the first thing in your app's launch path |
| A crash inside the crash handler itself | The signal is already being handled and the process dies |
| A stack overflow on a thread other than the SDK's start thread | `sigaltstack` is per-thread |

**On the next launch**, the SDK reads the artifact, merges it with a pre-written context sidecar (device info, release, environment, session ID, and recent breadcrumbs), builds a `.fatal` event, and delivers it through the normal ingest pipeline. The artifact is then deleted so the crash is never double-reported.

```swift
// Check whether the previous run ended in a crash (available before start()).
if BugWatch.didCrashOnPreviousExecution {
    print("App crashed on previous run — consider showing a recovery UI")
}

// Also available on the shared instance after start():
BugWatch.shared?.crashedLastRun
```

The crash event includes binary images and raw instruction addresses (`binaryImages` + `nativeStacktrace` payload v2), which the BugWatch backend passes to the Sentry Symbolicator for frame resolution — provided you have uploaded a matching dSYM (see [dSYM symbol upload](#dsym-symbol-upload) below).

---

## ANR / app-hang detection

When `enableAppHangTracking` is `true` (the default), a background watchdog pings the main thread every 200 ms. If the main thread is unresponsive for `appHangThresholdMs` or longer (default: 2 000 ms), the SDK emits a non-fatal `AppHang` event through the same delivery pipeline.

Hang events bypass sampling (hangs are rare and high-value signals). They do not terminate the app.

```swift
BugWatch.start(options: BugWatchOptions(
    projectId: "…",
    appSecret: "…",
    enableAppHangTracking: true,
    appHangThresholdMs: 3000   // report hangs after 3 s (default: 2 s)
))
```

---

## Release-health sessions

When `autoSessionTracking` is `true` (the default), the SDK emits Sentry-style release-health session signals. These drive **crash-free session** and **crash-free user** rates in the BugWatch dashboard.

- On each launch: an `ok` session event is emitted for the current run.
- On the next launch: the prior run's session is finalized as `crashed` (if `didCrashOnPreviousExecution`) or `exited` (clean shutdown).

Session events bypass sampling so crash-free rates are never under-counted.

To disable sessions (e.g. in a background extension where sessions are not meaningful):

```swift
BugWatchOptions(projectId: "…", appSecret: "…", autoSessionTracking: false)
```

---

## Breadcrumbs

Breadcrumbs are a trail of events attached to crash and error reports to give context about what happened just before the event.

### Automatic breadcrumbs

When `enableAutoBreadcrumbs` is `true` (default), the SDK records:
- **Lifecycle transitions** — foreground, background, memory warnings (via `UIApplication` notifications on iOS; no-op on macOS without UIKit)
- **Network requests** — one breadcrumb per outbound `URLSession.shared` HTTP(S) request (method, host, path, status code, duration), when `enableNetworkBreadcrumbs` is `true`

BugWatch's own ingest requests are always excluded from network breadcrumbs.

Exact shapes, so you can filter on them in the dashboard:

| Category | Type | Message | `data` keys |
|---|---|---|---|
| `app.lifecycle` | `system` | `App became active`, `App will resign active`, `App entered background`, `App will enter foreground`, `Received memory warning` | `event` (`app.foreground.active`, `app.resign.active`, `app.background`, `app.foreground`, `device.memory.low`) |
| `network` | `http` | `GET api.example.com/v1/orders` | `method`, `host`, `path`, `status_code`, `duration_ms` |

Network crumbs are recorded at `.error` for a 5xx response, `.warn` for a 4xx,
and `.info` otherwise (including a transport failure with no status).

Network breadcrumbs are collected via a `URLProtocol` that is also added to `URLSessionConfiguration.default`, so they cover `URLSession.shared` and any session built from the default configuration after `start(options:)` ran. A session built from a custom configuration before the SDK started, or one that sets its own `protocolClasses`, is not covered; this is inherent to `URLProtocol` and applies to every interceptor built this way. Query strings are stripped from the recorded path, and every crumb passes through the same `sensitiveFields` redaction as the rest of the payload.

### Manual breadcrumbs

```swift
BugWatch.addBreadcrumb(Breadcrumb(
    category: "ui",
    type: "user",
    level: .info,
    message: "Tapped checkout button",
    data: ["item_count": "3"]
))
```

`Breadcrumb` fields: `category` (required), `type` (default `"default"`), `level` (default `.info`), `message`, `data` (`[String: String]`), `timestamp` (default `Date()`).

The SDK keeps the last 100 breadcrumbs in a ring buffer. The most recent breadcrumbs are mirrored into the crash sidecar so a crash report carries the trail of what happened just before it.

---

## Device context

Every event carries a device snapshot collected automatically. There is nothing to configure and no way to opt out of individual fields.

| Field | Example |
|---|---|
| `model` | `iPhone15,3` |
| `family` | `iPhone` |
| `osName` / `osVersion` | `iOS` / `17.5.1` |
| `locale` | `en_GB` |
| `timezone` | `Europe/London` |
| `simulator` | `true` on the Simulator |
| `appVersion` / `appBuild` | `1.4.2` / `318` |
| `bundleId` | `com.example.app` |

Alongside the device snapshot, every event carries an `installId` (stable for the lifetime of the install), a `sessionId`, the `release`, the `environment`, your `tags`, `contexts`, `user`, and the breadcrumb ring.

---

## User identification

```swift
// Identify the current user
BugWatch.setUser(BugWatchUser(
    id: "user-123",
    email: "alice@example.com",
    username: "alice"
))

// Clear on logout
BugWatch.setUser(nil)
```

`BugWatchUser` fields (all optional): `id`, `email`, `username`, `ip`.

---

## Tags and context

```swift
// Attach a tag to all subsequent events
BugWatch.setTag(key: "payment_provider", value: "paystack")
BugWatch.setTag(key: "subscription_tier", value: "pro")

// Attach freeform context
BugWatch.setContext("feature_flags", value: "dark_mode=true,new_checkout=false")
```

---

## Release and environment

Set at init time via `BugWatchOptions`, or update later:

```swift
BugWatch.setRelease("2.0.0+419")
```

When you call `setRelease`, the new value is also written into the crash sidecar so a subsequent crash is attributed to the correct release.

---

## Sensitive-field redaction

The SDK redacts values of sensitive fields before events ever touch disk. The default list covers common credential/PII field names. Extend or replace it:

```swift
var opts = BugWatchOptions(projectId: "…", appSecret: "…")
opts.sensitiveFields = BugWatchOptions.defaultSensitiveFields + ["national_id", "bank_account"]
BugWatch.start(options: opts)
```

---

## Sampling

Drop a fraction of events to reduce volume (for example, in a very high-traffic app):

```swift
BugWatch.start(options: BugWatchOptions(
    projectId: "…",
    appSecret: "…",
    sampleRate: 0.25   // keep 25% of events
))
```

Crash events, app-hang events, and session events **always bypass sampling** regardless of `sampleRate`.

---

## dSYM symbol upload

BugWatch needs your app's dSYM files to translate raw memory addresses into readable file names, function names, and line numbers in the Issues and Logs views.

### Install the CLI

```sh
npm install -g @newinstance/bugwatch-cli
# or use npx (no install needed):
npx @newinstance/bugwatch-cli --help
```

### Upload a dSYM (manually or from CI)

```sh
npx @newinstance/bugwatch-cli symbols upload /path/to/MyApp.dSYM \
  --platform ios \
  --release "1.4.2+318" \
  --bundle-id com.example.myapp \
  --distribution app-store
```

Set your API key via the `BUGWATCH_AUTH_TOKEN` environment variable (`keyId:secret` format, `symbols:upload` scope), or pass `--token <keyId:secret>`.

### Add a build phase in Xcode (recommended)

Add a **Run Script** build phase after "Embed Frameworks":

```sh
BUGWATCH_AUTH_TOKEN="$BUGWATCH_API_KEY" \
  npx @newinstance/bugwatch-cli symbols upload \
    "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}" \
    --platform ios \
    --release "${MARKETING_VERSION}+${CURRENT_PROJECT_VERSION}" \
    --bundle-id "${PRODUCT_BUNDLE_IDENTIFIER}" \
    --distribution app-store
```

Store `BUGWATCH_API_KEY` in your Xcode scheme's environment (never in source control).

### Xcode Cloud

Add a `ci_post_xcodebuild.sh` script at your repo root. Xcode Cloud exposes the archive at `$CI_ARCHIVE_PATH`:

```sh
#!/bin/sh
set -e
[ -z "$BUGWATCH_AUTH_TOKEN" ] && exit 0

npx @newinstance/bugwatch-cli symbols upload "$CI_ARCHIVE_PATH" \
  --platform ios \
  --release "$CI_PRODUCT_VERSION" \
  --build-number "$CI_BUILD_NUMBER" \
  --upload-source xcode-cloud
```

Set `BUGWATCH_AUTH_TOKEN` as a **Secret** environment variable under **Xcode Cloud → Workflows → Environment**.

### Publishing from local Xcode (manual archive)

To upload dSYMs from a build you archived on your own Mac (Xcode **Product → Archive**):

1. Open **Window → Organizer → Archives**, right-click the archive → **Show in Finder**.
2. Drag the `.xcarchive` into Terminal to paste its path (the CLI walks its `dSYMs/` folder for you).

```sh
export BUGWATCH_AUTH_TOKEN="<keyId>:<secret>"
npx @newinstance/bugwatch-cli symbols upload \
  "~/Library/Developer/Xcode/Archives/2026-06-28/MyApp 2026-06-28 10.30.xcarchive" \
  --platform ios \
  --release "1.4.2+318" \
  --bundle-id com.example.myapp \
  --upload-source local-xcode
```

The SDK already sends `binaryImages` (load addresses + UUIDs) and `nativeStacktrace` (raw instruction addresses) with every crash event so the backend Symbolicator can match frames to your uploaded dSYM automatically.

---

## Debug mode

Enable internal SDK logging during development:

```swift
BugWatch.start(options: BugWatchOptions(
    projectId: "…",
    appSecret: "…",
    debug: true
))

// Route log lines wherever you want (e.g. console, file, OSLog)
BugWatchDiagnosticLog.setHandler { line in
    print(line)
}
```

The handler may be called from any queue. Dispatch to the main queue inside the closure if you update UI.

---

## Flush before shutdown

```swift
// Awaitable (use in async contexts, e.g. scene lifecycle)
await BugWatch.flush()

// Fire-and-forget with optional completion
BugWatch.flush { print("flushed") }
```

To fully shut down and tear down all handlers (e.g. in tests):

```swift
BugWatch.close()
```

---

## How events reach the server

Nothing is sent from inside a crash handler. The process is dying and networking is not async-signal-safe there. Instead:

1. **At crash time** the handler writes a small, self-contained artifact to disk synchronously, then restores and re-raises so the OS and any chained reporter still run.
2. **On the next launch** the SDK reads the artifact, merges it with the context sidecar, builds a `.fatal` event, enqueues it, and deletes the artifact so a crash is never reported twice.

Handled events skip step 1 and go straight to the queue. The queue is an append-only NDJSON file written synchronously on the calling thread, so an event captured moments before the process dies still survives.

Delivery is:

```
POST {endpoint}/api/v1/bugwatch/ingest/mobile
x-bugwatch-token: <token signed on-device>
Content-Type: application/x-ndjson
```

The token is an HMAC-SHA256 signature over `{ pid, env, iat, exp, nonce }`, signed on-device with your `appSecret` and valid for 5 minutes. A fresh token is signed per attempt. Your `appSecret` never leaves the device.

Batches carry `batchSize` events. Retryable failures back off exponentially (200 ms initial, 5 s cap, 3 attempts by default); a batch that exhausts its attempts or is rejected outright is dropped so it can never wedge the pipe. Delivery resumes automatically when connectivity returns, and a timer flushes every `flushIntervalMs`.

Delivery is in-process, so anything still queued when the app dies is sent on the next launch. There is no background upload after the process is gone; iOS provides no mechanism for it.

---

## What the SDK writes to disk

Everything lives under `Application Support/cloud.newinstance.bugwatch/`. Deleting the app removes all of it. Nothing here is included in an iCloud backup you need to worry about, and none of it contains your `appSecret`.

| File | Purpose |
|---|---|
| `pending-events.ndjson` | The delivery queue, one JSON event per line |
| `pending_crash` | Signal-crash artifact, written from the async-signal-safe handler |
| `pending_crash_nsexception` | `NSException` crash artifact, written in a normal context |
| `crash-context.json` | Device, release, environment, and session snapshot so the next launch can enrich a crash |
| `crash-breadcrumbs.ndjson` | Mirrored breadcrumb ring for crash enrichment |
| `current-session.json` | In-flight session descriptor for release health |

---

## API reference

Every public member of the `BugWatch` module. Static forms operate on the shared instance and are no-ops before `start(options:)`; instance forms are available on `BugWatch.shared`.

| Member | Signature | Notes |
|---|---|---|
| `BugWatch.start` | `(options: BugWatchOptions) -> BugWatch` | Starts the SDK and arms crash capture. Idempotent |
| `BugWatch.close` | `()` | Stops delivery and uninstalls handlers |
| `BugWatch.shared` | `BugWatch?` | The running instance, `nil` before `start` |
| `BugWatch.capture(error:)` | `(Error) -> String?` | Captures a handled Swift `Error` at `.error` |
| `BugWatch.captureMessage` | `(String, level: Severity = .info) -> String?` | Log-style capture |
| `BugWatch.captureWrapperException` | `(type:value:frames:level:platform:rawStacktrace:) -> String?` | Used by the React Native and Flutter wrappers to submit a foreign-language stack |
| `BugWatch.setUser` | `(BugWatchUser?)` | `nil` clears the identity |
| `BugWatch.setTag` | `(key: String, value: String)` | Indexed and filterable |
| `BugWatch.setContext` | `(String, value: String)` | Free-form, not indexed |
| `BugWatch.setRelease` | `(String)` | Overrides the release for subsequent events |
| `BugWatch.addBreadcrumb` | `(Breadcrumb)` | Bounded ring of the 100 most recent |
| `BugWatch.flush` | `() async` and `(completion: (() -> Void)?)` | Drains the queue |
| `BugWatch.didCrashOnPreviousExecution` | `Bool` | Readable **before** `start`, backed by `UserDefaults` |
| `BugWatch.shared?.crashedLastRun` | `Bool` | Same signal, after `start` |
| `BugWatch.sdkName` / `BugWatch.sdkVersion` | `String` | Stamped on every event |

Public types: `BugWatchOptions`, `BugWatchUser`, `Breadcrumb`, `Severity`, `RetryPolicy`, `StackFrame`, `NormalizedException`, `BinaryImage`, `NativeFrame`, `DeviceInfo`, `ConnectionState`, `BugWatchLifecycle`, `BugWatchError` (`.notStarted`, `.invalidProjectKey`, `.invalidOption(String)`).

---

## End-to-end walkthrough

This exercises every capture path the SDK has. Do it once on a real device when you integrate. It takes about ten minutes and it is the only way to confirm symbolication is wired up, not just capture.

### 1. Start as early as possible

Handlers are armed by `start`, so anything that crashes before it is invisible.

```swift
@main
struct MyApp: App {
    init() {
        BugWatch.start(options: BugWatchOptions(
            projectId: "bwp_…",
            appSecret: "…",
            environment: "development",
            release: "1.0.0+1",
            debug: true
        ))
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

### 2. Confirm the pipe works

```swift
BugWatch.captureMessage("e2e: hello", level: .info)
```

Dashboard, **Logs** tab. It should land within a few seconds. If it does not, fix credentials or connectivity before continuing; nothing below will work either.

### 3. Give events something to say

```swift
BugWatch.setUser(BugWatchUser(id: "u_123", email: "tester@example.com"))
BugWatch.setTag(key: "screen", value: "checkout")
BugWatch.setContext("cart_id", value: "c_987")
BugWatch.addBreadcrumb(Breadcrumb(category: "ui", message: "Pay tapped"))
```

Every event from here carries all four. Confirm on the next event you send.

### 4. Trigger each crash class

One at a time, relaunching between each, since crash reports are delivered on the launch *after* the crash. Keep these behind a debug-only screen.

```swift
// a. Handled error, appears immediately, no relaunch needed
struct DemoError: Error {}
BugWatch.capture(error: DemoError())

// b. Swift runtime trap, arrives as SIGTRAP
fatalError("e2e: swift trap")

// c. Force-unwrap of nil, also SIGTRAP
let missing: Int? = nil
_ = missing!

// d. Uncaught NSException
NSException(name: .genericException, reason: "e2e: nsexception", userInfo: nil).raise()

// e. Null dereference, SIGSEGV
UnsafeMutablePointer<Int>(bitPattern: 0x10)!.pointee = 1

// f. Stack overflow, SIGSEGV on the alternate signal stack
func recurse(_ n: Int) -> Int { n < 0 ? n : recurse(n &+ 1) &+ n }
_ = recurse(0)
```

After each, relaunch and confirm the crash appears under **Issues** with `level: fatal`, and that the previous session shows `crashed` in release health.

### 5. Prove symbolication, not just capture

A crash you cannot read is not much use. This is the step people skip.

```bash
npx @newinstance/bugwatch-cli symbols upload path/to/YourApp.xcarchive \
  --release "1.0.0+1" --build-number 1 --bundle-id com.example.app
```

The `--release` value must match the `release` you passed to `start` exactly. That string is the only join key between an event and its symbols, and a mismatch is the most common reason frames stay as bare addresses.

Re-trigger the `SIGSEGV` case, relaunch, and confirm the frames now show Swift function names and source lines instead of `0x0000000102a4c1f0`.

### 6. Turn debug off, then ship

```swift
debug: false
```

---

## Verifying the integration

1. Set `debug: true` and install a `BugWatchDiagnosticLog` handler (see above).
2. Call `BugWatch.captureMessage("BugWatch integration test", level: .info)` on app launch.
3. Run the app. You should see log lines like `[BugWatch] captured info event bw_e_…` and `[BugWatch] delivered 1 event(s)`.
4. Open the BugWatch dashboard → **Logs** for your project. The test event should appear within a few seconds.
5. Remove the test call before shipping.

---

## Production checklist

Before submitting to the App Store:

- [ ] Set `environment: "production"` (not `"staging"` or `"debug"`).
- [ ] Set `release` to your marketing version + build number, e.g. `"2.1.0+512"`.
- [ ] Set `debug: false` (the default).
- [ ] Upload your dSYM to BugWatch as part of your build/CI pipeline (see above).
- [ ] If you use App Store Connect distribution: enable **dSYM download** in Xcode organizer for bitcode-compiled archives, or disable bitcode and upload dSYMs directly.
- [ ] Confirm `appSecret` is not hardcoded in source-controlled config files; use Xcode's secrets mechanism or a secrets manager and inject at build time.

---

## Two complete examples

### Minimal SwiftUI app

```swift
import SwiftUI
import BugWatch

@main
struct MinimalApp: App {
    init() {
        BugWatch.start(options: BugWatchOptions(
            projectId: "proj_abc123",
            appSecret: "bWFnaWNfc2VjcmV0X2hlcmU",
            environment: "production",
            release: "1.0.0+1"
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    var body: some View {
        Button("Trigger test event") {
            BugWatch.captureMessage("Button tapped", level: .info)
        }
    }
}
```

### Realistic app with user identification, tags, and crash verification

```swift
import SwiftUI
import BugWatch

@main
struct RealApp: App {
    init() {
        // Check for a prior crash before start() so you can gate UI on it
        if BugWatch.didCrashOnPreviousExecution {
            // e.g. clear app state, show a recovery banner
        }

        BugWatch.start(options: BugWatchOptions(
            projectId: "proj_abc123",
            appSecret: "bWFnaWNfc2VjcmV0X2hlcmU",
            environment: ProcessInfo.processInfo.environment["ENV"] ?? "production",
            release: "\(Bundle.main.shortVersion)+\(Bundle.main.buildNumber)",
            sampleRate: 0.5,        // keep 50% of non-critical events
            appHangThresholdMs: 3000
        ))

        // Route internal logs to the console in DEBUG builds
        #if DEBUG
        BugWatchDiagnosticLog.setHandler { print($0) }
        #endif
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

// After sign-in:
func onSignIn(user: AppUser) {
    BugWatch.setUser(BugWatchUser(id: user.id, email: user.email))
    BugWatch.setTag(key: "plan", value: user.planName)
    BugWatch.setTag(key: "region", value: user.region)
}

// On logout:
func onSignOut() {
    BugWatch.setUser(nil)
}

// Handled error example:
func loadOrders() async {
    do {
        let orders = try await api.fetchOrders()
        _ = orders
    } catch {
        BugWatch.capture(error: error)
        BugWatch.addBreadcrumb(Breadcrumb(
            category: "api",
            level: .error,
            message: "fetchOrders failed",
            data: ["error": error.localizedDescription]
        ))
    }
}

// Crash test (REMOVE before shipping):
// BugWatch.captureMessage("Crash test", level: .fatal)
// let p: UnsafeMutablePointer<Int>? = nil; p!.pointee = 0

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "0" }
}
```

---

## Known limitations

Stated plainly so you can plan around them rather than discover them during an incident.

- **Delivery needs a relaunch.** Crash reports upload the next time the app starts. iOS gives no way to run code after the process is gone, so a user who crashes and never returns is never counted. Queued events are delayed, not lost.
- **Out-of-memory and watchdog kills are invisible.** `SIGKILL` cannot be caught. Those runs finalize as `exited`, so crash-free rate reads slightly better than reality. There is no `abnormal` session status.
- **Stack overflow is covered only on the SDK's start thread.** `sigaltstack` is per-thread and is registered on the thread that calls `start(options:)`.
- **Nothing before `start(options:)` is captured.** Arm the SDK first in your launch path.
- **Signal handlers, not Mach exception ports.** This covers every crash the OS surfaces as a POSIX signal, which is effectively all of them, but it means a crash occurring inside the handler itself is not recoverable.
- **Network breadcrumbs need the default `URLSession` configuration.** A session built with a custom `protocolClasses` list that omits the BugWatch protocol is not observed.
- **No automatic screenshot, view hierarchy, or profiling capture.** The SDK collects crashes, errors, logs, breadcrumbs, device context, and release-health sessions only.

---

## Upgrading

### 0.1.x → future versions

Check [CHANGELOG.md](./CHANGELOG.md) for breaking changes before upgrading. The SDK is `@discardableResult` on capture methods, so new return-type changes will not produce warnings in callers that discard the value.

---

## Troubleshooting

**Events are not appearing in the dashboard**

1. Enable `debug: true` and check for log lines from `[BugWatch]`. A missing "delivered" line means delivery is failing.
2. Confirm `projectId` and `appSecret` are correct — copy them fresh from the dashboard.
3. Check that your device/simulator has network connectivity and the endpoint is reachable.
4. The disk-backed queue survives restarts; if delivery fails repeatedly the worker retries with exponential backoff. Look for `[BugWatch] retrying …` lines.

**Crashes are not symbolicated**

1. Confirm you uploaded a dSYM for the exact `release`+`buildNumber` combination that crashed.
2. Check the dSYM upload status in the dashboard under **Debug Symbols**.
3. Verify the dSYM UUID matches the binary by running `dwarfdump --uuid MyApp.dSYM` and comparing it to the `binaryImages` section in the raw event payload.

**`didCrashOnPreviousExecution` is always `false`**

The flag is set during `start()` when the SDK processes a pending crash artifact. If the app is force-quit (swipe-to-close) rather than crashing, no artifact is written and the flag stays `false` — this is correct behavior.

**App hangs are not being reported**

Confirm `enableAppHangTracking: true` (the default). If `appHangThresholdMs` is very low (< 500 ms), normal UI work on the main thread may trigger false positives; increase the threshold.

**CocoaPods build fails with missing `Crypto`**

The CocoaPods build uses `CryptoKit` (system framework, iOS 13+) instead of `swift-crypto`. If your target is below iOS 13, upgrade your minimum deployment target to iOS 14 (required by BugWatch regardless).

---

## Links

- [BugWatch dashboard](https://newinstance.cloud)
- [REST API reference / Swagger](https://api.newinstance.cloud/swagger.json)
- [BugWatch CLI](https://github.com/New-Instance-Org/bugwatch-cli)
- [Android SDK](https://github.com/New-Instance-Org/bug-watch-android)
- [React Native SDK](https://www.npmjs.com/package/@newinstance/bugwatch-react-native)
- [JS/TS SDK](https://www.npmjs.com/package/@newinstance/bugwatch)
- [PHP SDK](https://github.com/New-Instance-Org/bugwatch-php)

---

## License

MIT — see [LICENSE](./LICENSE).
