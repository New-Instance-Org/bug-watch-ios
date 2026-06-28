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
