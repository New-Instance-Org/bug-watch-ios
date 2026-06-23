import XCTest
@testable import BugWatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A2 — native crash capture. No real crashes are raised here: the artifact
/// writer is driven through its test seam (which uses the **same** low-level
/// primitives the signal handler uses), and handler install/chaining is verified
/// against the real `sigaction` table without delivering a fatal signal.
final class CrashReporterTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-crash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Be sure no test left handlers installed.
        CrashReporter.uninstall()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - Artifact round-trip (writer primitive → parser)

    /// A synthetic signal artifact written via the real writer primitive parses
    /// back to the same signal number, time, name, and frames.
    func testSignalArtifactRoundTrip() {
        let url = CrashReporter.signalArtifactURL(directory: dir)
        let frames = [
            "0   MyApp    0x0000000100abcd00 $s5MyApp4bangyyF + 40",
            "1   MyApp    0x0000000100abce10 main + 120",
            "2   dyld     0x0000000180123456 start + 600",
        ]
        CrashReporter.writeSyntheticSignalArtifact(url: url, signal: SIGSEGV, time: 1_700_000_000, frames: frames)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "artifact written")

        let artifact = try! XCTUnwrap(CrashReporter.readArtifactFile(url))
        XCTAssertEqual(artifact.type, .signal)
        XCTAssertEqual(artifact.signal, SIGSEGV)
        XCTAssertEqual(artifact.signalName, "SIGSEGV")
        XCTAssertEqual(artifact.time, 1_700_000_000)
        XCTAssertEqual(artifact.frames, frames)
    }

    /// The signal-number → name mapping covers every trapped signal.
    func testSignalNameMapping() {
        XCTAssertEqual(CrashReporter.signalName(for: SIGSEGV), "SIGSEGV")
        XCTAssertEqual(CrashReporter.signalName(for: SIGABRT), "SIGABRT")
        XCTAssertEqual(CrashReporter.signalName(for: SIGBUS), "SIGBUS")
        XCTAssertEqual(CrashReporter.signalName(for: SIGILL), "SIGILL")
        XCTAssertEqual(CrashReporter.signalName(for: SIGFPE), "SIGFPE")
        XCTAssertEqual(CrashReporter.signalName(for: SIGTRAP), "SIGTRAP")
        XCTAssertEqual(CrashReporter.signalName(for: SIGSYS), "SIGSYS")
    }

    /// The NSException artifact (richer, normal-context writer) round-trips with
    /// its name, reason, and symbolicated frames — and embedded newlines in the
    /// reason are collapsed so each field stays one line.
    func testNSExceptionArtifactRoundTrip() {
        CrashReporter.writeExceptionArtifact(
            directory: dir,
            name: "NSRangeException",
            reason: "index 5 beyond bounds\nfor empty array",
            time: 1_700_000_123,
            frames: ["0  MyApp  0x01  -[Foo bar] + 10", "1  CoreFoundation  0x02  __exceptionPreprocess + 200"]
        )
        let url = CrashReporter.nsExceptionArtifactURL(directory: dir)
        let artifact = try! XCTUnwrap(CrashReporter.readArtifactFile(url))
        XCTAssertEqual(artifact.type, .nsexception)
        XCTAssertEqual(artifact.name, "NSRangeException")
        XCTAssertEqual(artifact.reason, "index 5 beyond bounds for empty array") // newline collapsed
        XCTAssertEqual(artifact.time, 1_700_000_123)
        XCTAssertEqual(artifact.frames.count, 2)
    }

    /// `readPendingArtifact` prefers the NSException artifact when both exist
    /// (it carries the most detail).
    func testNSExceptionPreferredOverSignalWhenBothPresent() {
        CrashReporter.writeSyntheticSignalArtifact(
            url: CrashReporter.signalArtifactURL(directory: dir),
            signal: SIGABRT, time: 1, frames: ["a"]
        )
        CrashReporter.writeExceptionArtifact(
            directory: dir, name: "NSGenericException", reason: "boom", time: 2, frames: ["b"]
        )
        let artifact = try! XCTUnwrap(CrashReporter.readPendingArtifact(directory: dir))
        XCTAssertEqual(artifact.type, .nsexception)
        XCTAssertEqual(artifact.name, "NSGenericException")
    }

    /// Corrupt / unrecognized artifact text yields nil rather than a bogus event.
    func testParseRejectsUnknownMarker() {
        XCTAssertNil(CrashReporter.parse("not-a-bugwatch-artifact\nsignal=11\n"))
        XCTAssertNil(CrashReporter.parse(""))
    }

    // MARK: - Next-launch builder

    /// Given a synthetic signal artifact + a sidecar context, the builder
    /// produces a `.fatal` event with the right exception, frames, device, ids,
    /// release, breadcrumbs, and the `crash.type=signal` tag.
    func testBuildEventFromSignalArtifactAndSidecar() {
        let artifact = CrashReporter.CrashArtifact(
            type: .signal,
            signal: SIGSEGV,
            signalName: "SIGSEGV",
            name: nil,
            reason: nil,
            time: 1_700_000_000,
            frames: ["0  MyApp  0x01  crash() + 10", "1  UIKitCore  0x02  -[UIApplication _run] + 40"]
        )
        let device = DeviceInfo(model: "iPhone15,2", family: "iPhone", osName: "iOS", osVersion: "17.4")
        let context = CrashContextSidecar.Context(
            installId: "install-xyz",
            sessionId: "bw_s_prev",
            release: "1.4.2+318",
            environment: "staging",
            device: device,
            startedAt: 1_699_999_000_000
        )
        let crumbs = [Breadcrumb(category: "nav", message: "opened checkout")]

        let event = CrashReporter.buildEvent(
            from: artifact,
            context: context,
            breadcrumbs: crumbs,
            sdk: SdkInfo(name: BugWatch.sdkName, version: BugWatch.sdkVersion),
            environmentFallback: "production"
        )

        XCTAssertEqual(event.level, Severity.fatal.rawValue)
        XCTAssertEqual(event.platform, "ios")
        XCTAssertEqual(event.exception?.type, "SIGSEGV")
        XCTAssertEqual(event.exception?.value, "Fatal signal 11 (SIGSEGV)")
        XCTAssertEqual(event.exception?.stacktrace?.count, 2)
        // raw symbol string is carried in `function`
        XCTAssertEqual(event.exception?.stacktrace?.first?.function, "0  MyApp  0x01  crash() + 10")
        // in_app best-effort: app frame true, UIKit frame false
        XCTAssertEqual(event.exception?.stacktrace?.first?.inApp, true)
        XCTAssertEqual(event.exception?.stacktrace?.last?.inApp, false)
        // context carried from sidecar
        XCTAssertEqual(event.installId, "install-xyz")
        XCTAssertEqual(event.sessionId, "bw_s_prev")
        XCTAssertEqual(event.release, "1.4.2+318")
        XCTAssertEqual(event.environment, "staging")
        XCTAssertEqual(event.device?.model, "iPhone15,2")
        XCTAssertEqual(event.breadcrumbs?.count, 1)
        // crash.type tag
        XCTAssertEqual(event.tags?["crash.type"], "signal")
        XCTAssertEqual(event.tags?["crash.signal"], "SIGSEGV")
        // crash time preserved (seconds → millis)
        XCTAssertEqual(event.time, 1_700_000_000_000)
        XCTAssertTrue(event.eventId.hasPrefix("bw_e_"))
    }

    /// NSException artifact → `.fatal` event with crash.type=nsexception and the
    /// exception name/reason mapped onto type/value.
    func testBuildEventFromNSExceptionArtifact() {
        let artifact = CrashReporter.CrashArtifact(
            type: .nsexception,
            signal: nil,
            signalName: nil,
            name: "NSRangeException",
            reason: "index out of bounds",
            time: 1_700_000_000,
            frames: ["0  MyApp  0x01  -[Foo bar] + 10"]
        )
        let event = CrashReporter.buildEvent(
            from: artifact,
            context: nil,                       // no sidecar — falls back gracefully
            breadcrumbs: [],
            sdk: SdkInfo(name: BugWatch.sdkName, version: BugWatch.sdkVersion),
            environmentFallback: "production"
        )
        XCTAssertEqual(event.level, Severity.fatal.rawValue)
        XCTAssertEqual(event.exception?.type, "NSRangeException")
        XCTAssertEqual(event.exception?.value, "index out of bounds")
        XCTAssertEqual(event.tags?["crash.type"], "nsexception")
        XCTAssertNil(event.tags?["crash.signal"])
        XCTAssertNil(event.breadcrumbs)         // empty → omitted
        XCTAssertEqual(event.environment, "production") // fallback used
        XCTAssertNil(event.installId)
    }

    /// `processPending` round trip: a written artifact is converted to a `.fatal`
    /// event handed to the enqueue closure, then the artifact is DELETED so it
    /// can never be double-reported. A second call enqueues nothing.
    func testProcessPendingEnqueuesOnceThenDeletes() {
        let sidecar = CrashContextSidecar(directory: dir)
        sidecar.writeContext(CrashContextSidecar.Context(
            installId: "i1", sessionId: "s1", release: "1.0", environment: "staging",
            device: DeviceInfo(model: "iPhone15,2"), startedAt: 1
        ))
        CrashReporter.writeSyntheticSignalArtifact(
            url: CrashReporter.signalArtifactURL(directory: dir),
            signal: SIGABRT, time: 1_700_000_000, frames: ["0  MyApp  0x01  boom + 1"]
        )

        var enqueued: [BugWatchEvent] = []
        let first = CrashReporter.processPending(
            directory: dir, sidecar: sidecar,
            sdk: SdkInfo(name: "bugwatch-ios", version: "0.1.0"),
            environmentFallback: "production",
            enqueue: { enqueued.append($0) }
        )
        XCTAssertTrue(first)
        XCTAssertEqual(enqueued.count, 1)
        XCTAssertEqual(enqueued.first?.exception?.type, "SIGABRT")
        XCTAssertEqual(enqueued.first?.installId, "i1")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: CrashReporter.signalArtifactURL(directory: dir).path),
            "artifact deleted after enqueue"
        )

        // No artifact left → second call is a no-op (never double-reports).
        let second = CrashReporter.processPending(
            directory: dir, sidecar: sidecar,
            sdk: SdkInfo(name: "bugwatch-ios", version: "0.1.0"),
            environmentFallback: "production",
            enqueue: { enqueued.append($0) }
        )
        XCTAssertFalse(second)
        XCTAssertEqual(enqueued.count, 1)
    }

    /// No artifact present → processPending returns false and enqueues nothing.
    func testProcessPendingNoArtifactIsNoOp() {
        let sidecar = CrashContextSidecar(directory: dir)
        var enqueued = 0
        let processed = CrashReporter.processPending(
            directory: dir, sidecar: sidecar,
            sdk: SdkInfo(name: "bugwatch-ios", version: "0.1.0"),
            environmentFallback: "production",
            enqueue: { _ in enqueued += 1 }
        )
        XCTAssertFalse(processed)
        XCTAssertEqual(enqueued, 0)
    }

    // MARK: - Install idempotency + previous-handler chaining

    /// Installing twice is a no-op the second time: the previous handler captured
    /// on the FIRST install is preserved (a second install must not overwrite the
    /// saved chain target with our own handler).
    func testInstallIsIdempotentAndPreservesOriginalPreviousHandler() {
        // Register a recognizable sentinel handler on a trapped signal BEFORE we
        // install, so we can later confirm it was saved as the chain target.
        var sentinel = sigaction()
        sigemptyset(&sentinel.sa_mask)
        sentinel.sa_flags = 0
        setSentinelHandler(&sentinel)
        var beforeReporter = sigaction()
        XCTAssertEqual(sigaction(SIGTRAP, &sentinel, &beforeReporter), 0)

        CrashReporter.install(directory: dir)
        // Second install: must NOT save our own just-installed handler as the
        // "previous" one (that would break chaining into a self-loop).
        CrashReporter.install(directory: dir)

        // Uninstall restores whatever was saved as previous. If idempotency held,
        // that's the sentinel we installed before the FIRST install — not the
        // reporter's own handler.
        CrashReporter.uninstall()

        var afterRestore = sigaction()
        XCTAssertEqual(sigaction(SIGTRAP, nil, &afterRestore), 0)
        XCTAssertTrue(
            handlersEqual(afterRestore, sentinel),
            "uninstall restored the sentinel captured on the first install (chaining preserved)"
        )

        // Clean up the sentinel.
        var dfl = sigaction()
        sigemptyset(&dfl.sa_mask)
        dfl.sa_flags = 0
        setDefaultHandler(&dfl)
        _ = sigaction(SIGTRAP, &dfl, nil)
    }

    /// After install, the reporter's own handler is the active one for each
    /// trapped signal (i.e. it actually took over), and uninstall puts the
    /// previous (default) handler back.
    func testInstallTakesOverThenUninstallRestores() {
        // Start from a known default for SIGSEGV.
        var dfl = sigaction()
        sigemptyset(&dfl.sa_mask)
        dfl.sa_flags = 0
        setDefaultHandler(&dfl)
        _ = sigaction(SIGSEGV, &dfl, nil)

        CrashReporter.install(directory: dir)
        var active = sigaction()
        XCTAssertEqual(sigaction(SIGSEGV, nil, &active), 0)
        XCTAssertFalse(handlersEqual(active, dfl), "reporter installed its own handler over SIG_DFL")

        CrashReporter.uninstall()
        var restored = sigaction()
        XCTAssertEqual(sigaction(SIGSEGV, nil, &restored), 0)
        XCTAssertTrue(handlersEqual(restored, dfl), "uninstall restored SIG_DFL")
    }

    /// The NSException chain target is captured: install saves the prior uncaught
    /// handler and uninstall puts it back.
    func testNSExceptionHandlerChainCaptured() {
        let sentinel: @convention(c) (NSException) -> Void = { _ in }
        NSSetUncaughtExceptionHandler(sentinel)

        CrashReporter.install(directory: dir)
        // The reporter is now the active uncaught handler (not the sentinel).
        XCTAssertNotNil(NSGetUncaughtExceptionHandler())

        CrashReporter.uninstall()
        // Restored to the sentinel we set before install (compare by bit pattern;
        // C function pointers aren't Equatable).
        let restored = NSGetUncaughtExceptionHandler()
        XCTAssertNotNil(restored)
        XCTAssertEqual(exceptionHandlerBits(restored), exceptionHandlerBits(sentinel))

        NSSetUncaughtExceptionHandler(nil)
    }
}

// MARK: - sigaction comparison/sentinel helpers (platform union shim)

/// A standalone C handler used as a recognizable sentinel in chaining tests.
private let testSentinelHandler: @convention(c) (Int32) -> Void = { _ in }

private func setSentinelHandler(_ action: inout sigaction) {
    #if canImport(Darwin)
    action.__sigaction_u.__sa_handler = testSentinelHandler
    #else
    action.__sigaction_handler.sa_handler = testSentinelHandler
    #endif
}

private func setDefaultHandler(_ action: inout sigaction) {
    #if canImport(Darwin)
    action.__sigaction_u.__sa_handler = SIG_DFL
    #else
    action.__sigaction_handler.sa_handler = SIG_DFL
    #endif
}

/// Raw bit pattern of a (possibly nil) C signal-handler pointer. C function
/// pointers aren't `Equatable`, so identity is compared via the bit pattern.
private func handlerBits(_ action: sigaction) -> UInt {
    #if canImport(Darwin)
    let h = action.__sigaction_u.__sa_handler
    #else
    let h = action.__sigaction_handler.sa_handler
    #endif
    guard let h else { return 0 }
    return UInt(bitPattern: unsafeBitCast(h, to: UnsafeRawPointer.self))
}

/// Compares the handler function pointers of two `sigaction`s by identity.
private func handlersEqual(_ a: sigaction, _ b: sigaction) -> Bool {
    handlerBits(a) == handlerBits(b)
}

/// Bit pattern of a (possibly nil) uncaught-exception handler pointer.
private func exceptionHandlerBits(_ handler: (@convention(c) (NSException) -> Void)?) -> UInt {
    guard let handler else { return 0 }
    return UInt(bitPattern: unsafeBitCast(handler, to: UnsafeRawPointer.self))
}
