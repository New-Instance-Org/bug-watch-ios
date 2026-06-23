import BugWatch
import Foundation

// A1 end-to-end probe. Drives the REAL BugWatch SDK (token signing + URLSession
// NDJSON transport + persistent queue + delivery worker) against a running
// BugWatch backend. Configure via env or edit the constants below.
//
//   swift run BugWatchE2EProbe
//
// Proves: capture -> sign -> POST /api/v1/bugwatch/ingest/mobile -> 202.

let projectId = ProcessInfo.processInfo.environment["BW_PROJECT_ID"] ?? "bwp_Gq4bFujpYe0"
let appSecret = ProcessInfo.processInfo.environment["BW_APP_SECRET"] ?? "cP5TyERo8YHdvQNeG5Nw5YziT4w9bOavY1F0HFomEPg"
let endpoint = ProcessInfo.processInfo.environment["BW_ENDPOINT"] ?? "http://localhost:5050"
let environment = ProcessInfo.processInfo.environment["BW_ENV"] ?? "production"

BugWatchDiagnosticLog.setHandler { print($0) }

let bw = BugWatch.start(options: BugWatchOptions(
    projectId: projectId,
    appSecret: appSecret,
    endpoint: endpoint,
    environment: environment,
    release: "a1-e2e-ios-0.0.1",
    debug: true,
    flushIntervalMs: 0
))

bw.setUser(BugWatchUser(id: "e2e-ios-user", email: "e2e@example.com"))
bw.setTag(key: "probe", value: "ios-macos")
bw.addBreadcrumb(Breadcrumb(category: "e2e", message: "probe start"))

let messageId = bw.captureMessage("A1 E2E iOS probe message", level: .info)
let errorId = bw.capture(error: NSError(
    domain: "E2EiOSError", code: 7,
    userInfo: [NSLocalizedDescriptionKey: "hello from iOS E2E"]
))
print("E2E captured: message=\(messageId) error=\(errorId)")

let done = DispatchSemaphore(value: 0)
Task {
    await bw.flush()
    // Brief grace for any in-flight delivery to settle.
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    print("E2E_PROBE_DONE")
    done.signal()
}
done.wait()
