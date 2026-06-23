import BugWatch
import Foundation

// A1/A2 end-to-end probe. Drives the REAL BugWatch SDK against a running
// BugWatch backend.
//
//   swift run BugWatchE2EProbe            # normal: process pending crash + send a message, flush
//   BW_CRASH=1 swift run BugWatchE2EProbe # crash phase: start, then raise SIGSEGV (handler writes artifact)
//
// Crash E2E: run once with BW_CRASH=1 (process dies writing a crash artifact),
// then run again with no env (start() processes the pending crash and uploads a
// fatal event through the A1 delivery pipe).

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
    release: "a2-e2e-ios-0.0.1",
    debug: true,
    flushIntervalMs: 0
))

if ProcessInfo.processInfo.environment["BW_CRASH"] == "1" {
    bw.setUser(BugWatchUser(id: "e2e-crash-user"))
    bw.setTag(key: "scenario", value: "crash-probe")
    bw.addBreadcrumb(Breadcrumb(category: "e2e", message: "about to crash"))
    print("E2E_ABOUT_TO_CRASH")
    fflush(stdout)
    // Deliberate native crash → the SDK's signal handler writes a crash artifact.
    raise(SIGSEGV)
    print("E2E_SHOULD_NOT_REACH")
} else {
    // start() already processed any pending crash and enqueued it; flush delivers.
    let done = DispatchSemaphore(value: 0)
    Task {
        await bw.flush()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        print("E2E_PROBE_DONE")
        done.signal()
    }
    done.wait()
}
