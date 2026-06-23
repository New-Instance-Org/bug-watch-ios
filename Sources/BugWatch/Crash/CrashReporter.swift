import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Native crash capture for BugWatch.
///
/// A process that hits a fatal signal (SIGSEGV, …) or an uncaught `NSException`
/// dies immediately, so we cannot sign a token and POST at crash time. Instead
/// this reporter:
///
/// 1. **At crash time** — from a signal handler that is strictly
///    *async-signal-safe* — dumps a tiny text artifact to a fixed path using
///    only `open`/`write`/`backtrace`/`backtrace_symbols_fd`. No Swift `String`,
///    no Foundation, no `malloc`, no `Dictionary`. It then restores the previous
///    (or default) handler and re-raises so the OS still records the crash.
///    Uncaught `NSException`s are handled in a normal context, so that path may
///    write a richer artifact (name + reason + symbolicated frames).
///
/// 2. **On the next launch** — `processPending(...)` reads any artifact, combines
///    it with the pre-written context sidecar (device / release / env / ids /
///    breadcrumbs), builds a `.fatal` `BugWatchEvent`, hands it to the supplied
///    enqueue closure (so the A1 delivery pipe uploads it), then deletes the
///    artifact so a crash is never double-reported.
///
/// All file paths are computed up front (the signal path additionally as a raw
/// C string) because nothing inside the signal handler may allocate.
enum CrashReporter {

    // MARK: Artifact model

    /// Which mechanism produced an artifact.
    enum CrashType: String {
        case signal
        case nsexception
    }

    /// A parsed pending-crash artifact (either flavor).
    struct CrashArtifact: Equatable {
        var type: CrashType
        /// Fatal signal number (signal crashes only).
        var signal: Int32?
        /// Symbolic signal name, e.g. "SIGSEGV" (signal crashes only).
        var signalName: String?
        /// NSException class name (nsexception crashes only).
        var name: String?
        /// NSException reason / human description.
        var reason: String?
        /// Unix seconds at crash time.
        var time: Int64?
        /// Raw backtrace frame lines (as `backtrace_symbols_fd` emits them).
        var frames: [String]
    }

    // MARK: Paths

    /// Signal artifact (written async-signal-safely at crash time).
    static func signalArtifactURL(directory: URL) -> URL {
        directory.appendingPathComponent("pending_crash", isDirectory: false)
    }

    /// NSException artifact (written in a normal context).
    static func nsExceptionArtifactURL(directory: URL) -> URL {
        directory.appendingPathComponent("pending_crash_nsexception", isDirectory: false)
    }

    // MARK: Artifact line tokens (shared by writer + parser)

    /// First line of every signal artifact — lets the parser recognise/version it.
    static let signalMarker = "BUGWATCH-CRASH-SIGNAL-V1"
    static let nsExceptionMarker = "BUGWATCH-CRASH-NSEXCEPTION-V1"

    // MARK: Install

    /// Process-global install state. Guarded by `installLock`. The handler reads
    /// the C path + saved previous handlers from here, so they outlive `install`.
    private static let installLock = NSLock()
    private static var installed = false

    /// Pre-computed NUL-terminated path the signal handler writes to. Stored so
    /// the handler never has to build a string.
    private static var signalPathC: [CChar] = []

    /// Backtrace scratch buffer, allocated ONCE at install and reused by the
    /// handler. Allocating inside the handler would call `malloc`, which is not
    /// async-signal-safe; pre-allocating keeps the handler allocation-free.
    private static let backtraceCapacity = 128
    private static var backtraceBuffer =
        [UnsafeMutableRawPointer?](repeating: nil, count: backtraceCapacity)

    /// Signals we trap. Index into this array is the "slot" used to look up the
    /// saved previous action in the handler (a fixed array — never a Dictionary —
    /// so the lookup is allocation- and hash-free, hence async-signal-safe).
    private static let trappedSignals: [Int32] = [
        SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGSYS,
    ]

    /// Previous `sigaction` for each trapped signal, by the SAME index as
    /// `trappedSignals`. Populated at install. The handler restores from here
    /// (for chaining / restore-and-reraise) WITHOUT locking or hashing — both of
    /// which are async-signal-unsafe. Written only at install/uninstall (startup),
    /// never concurrently with a fatal signal in practice.
    private static var previousSignalActions: [sigaction] =
        Array(repeating: sigaction(), count: trappedSignals.count)

    /// Saved previous uncaught-exception handler (chained after we write ours).
    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    /// Installs the signal + NSException handlers. Idempotent: a second call is a
    /// no-op (the first install's saved previous handlers are preserved).
    ///
    /// - Parameter directory: SDK directory the artifacts are written under.
    static func install(directory: URL = CrashContextSidecar.defaultDirectory()) {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }

        // Make sure the directory exists *now* — open() in the handler won't
        // create intermediate directories.
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Pre-bake the signal artifact path as a C string for the handler.
        signalPathC = signalArtifactURL(directory: directory).path.utf8CString.map { $0 }

        installSignalHandlersLocked()
        installExceptionHandlerLocked(directory: directory)

        installed = true
    }

    /// Restores all previous handlers and resets install state. Primarily for
    /// tests / `BugWatch.close`; the process normally just exits.
    static func uninstall() {
        installLock.lock()
        defer { installLock.unlock() }
        guard installed else { return }
        for (index, sig) in trappedSignals.enumerated() {
            var prev = previousSignalActions[index]
            _ = sigaction(sig, &prev, nil)
        }
        previousSignalActions = Array(repeating: sigaction(), count: trappedSignals.count)
        NSSetUncaughtExceptionHandler(previousExceptionHandler)
        previousExceptionHandler = nil
        installed = false
    }

    // MARK: Signal handling

    private static func installSignalHandlersLocked() {
        for (index, sig) in trappedSignals.enumerated() {
            var action = sigaction()
            sigemptyset(&action.sa_mask)
            // Restart-able syscalls off; we never return from the handler anyway.
            action.sa_flags = 0
            withUnsafeMutablePointer(to: &action) { setHandler(in: $0, to: CrashReporter.handleSignal) }

            var previous = sigaction()
            if sigaction(sig, &action, &previous) == 0 {
                previousSignalActions[index] = previous
            }
        }
    }

    /// The signal handler. **MUST stay async-signal-safe**: it may run on a
    /// corrupt stack/heap, so it touches NO Swift runtime allocation, NO
    /// Foundation, NO `String`. It uses only `open`/`write`/`backtrace`/
    /// `backtrace_symbols_fd`, then restores the previous handler and re-raises
    /// so the OS records the crash and any chained handler runs.
    private static let handleSignal: @convention(c) (Int32) -> Void = { signal in
        // ── async-signal-safe region ─────────────────────────────────────────
        // open(O_CREAT|O_WRONLY|O_TRUNC). signalPathC is pre-baked at install.
        let fd: Int32 = signalPathC.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return open(base, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        }
        if fd >= 0 {
            // marker
            writeCString(fd, CrashReporter.signalMarkerC)
            writeNewline(fd)
            // signal=<n>
            writeCString(fd, CrashReporter.signalPrefixC)
            writeInt(fd, Int(signal))
            writeNewline(fd)
            // time=<unix seconds>
            writeCString(fd, CrashReporter.timePrefixC)
            writeInt(fd, Int(time(nil)))
            writeNewline(fd)
            // frames marker, then raw backtrace
            writeCString(fd, CrashReporter.framesMarkerC)
            writeNewline(fd)

            // Reuse the pre-allocated buffer — no malloc in the handler.
            let count = backtraceBuffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                guard let base = ptr.baseAddress else { return 0 }
                return backtrace(base, Int32(ptr.count))
            }
            if count > 0 {
                backtraceBuffer.withUnsafeMutableBufferPointer { ptr in
                    if let base = ptr.baseAddress {
                        backtrace_symbols_fd(base, count, fd)
                    }
                }
            }
            close(fd)
        }
        // Restore the previous (or default) handler for this signal, then re-raise
        // so the OS still produces its crash report and any chained handler runs.
        //
        // This stays async-signal-safe: NO lock (NSLock can deadlock if the crash
        // happened mid-lock) and NO Dictionary (hashing can allocate). We linear-
        // scan the fixed `trappedSignals` array — index `i` maps to the saved
        // `previousSignalActions[i]` — using buffer pointers only.
        var restored = false
        trappedSignals.withUnsafeBufferPointer { sigs in
            previousSignalActions.withUnsafeBufferPointer { prevs in
                guard let sigBase = sigs.baseAddress, let prevBase = prevs.baseAddress else { return }
                var i = 0
                while i < sigs.count {
                    if sigBase[i] == signal {
                        // Pass the stored action straight to sigaction(); the
                        // pointee isn't mutated, so the const cast is safe.
                        let mutablePrev = UnsafeMutablePointer(mutating: prevBase + i)
                        _ = sigaction(signal, mutablePrev, nil)
                        restored = true
                        break
                    }
                    i += 1
                }
            }
        }
        if !restored {
            var dfl = sigaction()
            sigemptyset(&dfl.sa_mask)
            dfl.sa_flags = 0
            withUnsafeMutablePointer(to: &dfl) { setHandlerDefault(in: $0) }
            _ = sigaction(signal, &dfl, nil)
        }
        // ── end async-signal-safe region ─────────────────────────────────────
        raise(signal)
    }

    // Pre-encoded C-string fragments (static lets → allocated once at load,
    // never inside the handler).
    private static let signalMarkerC: [CChar] = signalMarker.utf8CString.map { $0 }
    private static let signalPrefixC: [CChar] = "signal=".utf8CString.map { $0 }
    private static let timePrefixC: [CChar] = "time=".utf8CString.map { $0 }
    private static let framesMarkerC: [CChar] = "frames:".utf8CString.map { $0 }

    // MARK: NSException handling

    private static func installExceptionHandlerLocked(directory: URL) {
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(CrashReporter.handleException)
    }

    /// Uncaught-exception handler. Runs in a *normal* context (the runtime is
    /// still intact while it unwinds), so it may use Foundation to write a richer
    /// artifact, then chains the previously-installed handler.
    private static let handleException: @convention(c) (NSException) -> Void = { exception in
        let name = exception.name.rawValue
        let reason = exception.reason ?? ""
        let frames = exception.callStackSymbols

        // Path: recompute from the install directory baked into the C path's
        // parent. We can use Foundation freely here.
        let dir: URL
        if let s = String(validatingUTF8: CrashReporter.signalPathC) {
            dir = URL(fileURLWithPath: s).deletingLastPathComponent()
        } else {
            dir = CrashContextSidecar.defaultDirectory()
        }
        writeExceptionArtifact(
            directory: dir,
            name: name,
            reason: reason,
            time: Int64(Date().timeIntervalSince1970),
            frames: frames
        )

        // Chain whatever was installed before us so other reporters still run.
        CrashReporter.previousExceptionHandler?(exception)
    }

    /// Writes the NSException artifact (normal-context, Foundation OK).
    static func writeExceptionArtifact(
        directory: URL,
        name: String,
        reason: String,
        time: Int64,
        frames: [String]
    ) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var lines: [String] = []
        lines.append(nsExceptionMarker)
        lines.append("name=" + sanitize(name))
        lines.append("reason=" + sanitize(reason))
        lines.append("time=\(time)")
        lines.append("frames:")
        for f in frames { lines.append(sanitize(f)) }
        let body = lines.joined(separator: "\n") + "\n"
        try? Data(body.utf8).write(to: nsExceptionArtifactURL(directory: directory), options: .atomic)
    }

    /// Collapses embedded newlines so each artifact field stays on one line.
    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Parsing

    /// Reads + parses whichever artifact is present (NSException preferred when
    /// both exist, as it carries more detail). Returns `nil` if none.
    static func readPendingArtifact(directory: URL) -> CrashArtifact? {
        if let ns = readArtifactFile(nsExceptionArtifactURL(directory: directory)) {
            return ns
        }
        return readArtifactFile(signalArtifactURL(directory: directory))
    }

    /// Deletes both artifact files (after reporting).
    static func deletePendingArtifacts(directory: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: signalArtifactURL(directory: directory))
        try? fm.removeItem(at: nsExceptionArtifactURL(directory: directory))
    }

    /// Parses one artifact file. Exposed (internal) so tests can parse a record
    /// written by the same writer primitives.
    static func readArtifactFile(_ url: URL) -> CrashArtifact? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parse(text)
    }

    /// Pure parser over artifact text. Tolerant of trailing/blank lines.
    static func parse(_ text: String) -> CrashArtifact? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Drop a trailing empty line from the terminating newline.
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        guard let marker = lines.first else { return nil }

        let type: CrashType
        if marker == signalMarker { type = .signal }
        else if marker == nsExceptionMarker { type = .nsexception }
        else { return nil }

        var signal: Int32?
        var name: String?
        var reason: String?
        var time: Int64?
        var frames: [String] = []
        var inFrames = false

        for line in lines.dropFirst() {
            if inFrames {
                if !line.isEmpty { frames.append(line) }
                continue
            }
            if line == "frames:" { inFrames = true; continue }
            if let v = value(of: "signal", in: line) { signal = Int32(v) }
            else if let v = value(of: "time", in: line) { time = Int64(v) }
            else if let v = value(of: "name", in: line) { name = v }
            else if let v = value(of: "reason", in: line) { reason = v }
        }

        return CrashArtifact(
            type: type,
            signal: signal,
            signalName: signal.map { signalName(for: $0) },
            name: name,
            reason: reason,
            time: time,
            frames: frames
        )
    }

    /// Extracts the value of a `key=value` line, else `nil`.
    private static func value(of key: String, in line: String) -> String? {
        let prefix = key + "="
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    /// Maps a signal number to its conventional name.
    static func signalName(for sig: Int32) -> String {
        switch sig {
        case SIGSEGV: return "SIGSEGV"
        case SIGABRT: return "SIGABRT"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGFPE:  return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        case SIGSYS:  return "SIGSYS"
        default:      return "SIG\(sig)"
        }
    }

    // MARK: Next-launch event builder

    /// Builds a `.fatal` `BugWatchEvent` from a parsed artifact + the context
    /// sidecar. Pure (no I/O) so it's trivially unit-testable.
    ///
    /// - Parameters:
    ///   - artifact: the parsed pending crash.
    ///   - context: sidecar context (device / release / env / ids).
    ///   - breadcrumbs: sidecar breadcrumbs (may be empty).
    ///   - sdk: SDK identity stamped on the event.
    ///   - environmentFallback: env to use when the sidecar didn't record one.
    static func buildEvent(
        from artifact: CrashArtifact,
        context: CrashContextSidecar.Context?,
        breadcrumbs: [Breadcrumb],
        sdk: SdkInfo,
        environmentFallback: String,
        now: Date = Date()
    ) -> BugWatchEvent {
        // Exception type / value.
        let type: String
        let value: String
        switch artifact.type {
        case .signal:
            type = artifact.signalName ?? artifact.signal.map { "SIG\($0)" } ?? "SIGNAL"
            value = "Fatal signal \(artifact.signal.map(String.init) ?? "?")"
                + (artifact.signalName.map { " (\($0))" } ?? "")
        case .nsexception:
            type = artifact.name ?? "NSException"
            value = artifact.reason?.isEmpty == false ? artifact.reason! : (artifact.name ?? "Uncaught exception")
        }

        // Frames → StackFrame. The raw symbol string goes in `function`; in_app
        // is a best-effort guess from the symbol (the host app's own frames are
        // not from a system framework path).
        let stack: [StackFrame]? = artifact.frames.isEmpty ? nil : artifact.frames.map { raw in
            StackFrame(function: raw, inApp: guessInApp(raw))
        }

        let exception = NormalizedException(type: type, value: value, stacktrace: stack)

        // Prefer the crash time from the artifact; fall back to now.
        let millis: Int64 = artifact.time.map { $0 * 1000 } ?? Int64(now.timeIntervalSince1970 * 1000)

        var tags: [String: String] = ["crash.type": artifact.type.rawValue]
        if let signalName = artifact.signalName { tags["crash.signal"] = signalName }

        return BugWatchEvent(
            eventId: "bw_e_" + UUID().uuidString.lowercased(),
            time: millis,
            level: Severity.fatal.rawValue,
            message: nil,
            exception: exception,
            release: context?.release,
            environment: context?.environment ?? environmentFallback,
            tags: tags,
            user: nil,
            breadcrumbs: breadcrumbs.isEmpty ? nil : breadcrumbs,
            sdk: sdk,
            platform: "ios",
            installId: context?.installId,
            sessionId: context?.sessionId,
            device: context?.device
        )
    }

    /// Heuristic `in_app`: a frame is "in app" when its symbol is *not* obviously
    /// from a system framework / dyld / libsystem. Best-effort only.
    private static func guessInApp(_ frame: String) -> Bool {
        let lower = frame.lowercased()
        let systemHints = [
            "/system/library/", "/usr/lib/", "libsystem", "libdyld", "libc++",
            "libobjc", "libswiftcore", "corefoundation", "foundation",
            "uikitcore", "uikit", "swift_", "dyld",
        ]
        for hint in systemHints where lower.contains(hint) { return false }
        return true
    }

    /// Convenience that wires file I/O around `buildEvent`: read artifact + sidecar,
    /// build the event, hand it to `enqueue`, then delete the artifact and clear
    /// the sidecar breadcrumbs. Returns `true` if a crash was processed.
    ///
    /// SDK failures here must never crash the host — everything is best-effort.
    @discardableResult
    static func processPending(
        directory: URL,
        sidecar: CrashContextSidecar,
        sdk: SdkInfo,
        environmentFallback: String,
        enqueue: (BugWatchEvent) -> Void
    ) -> Bool {
        guard let artifact = readPendingArtifact(directory: directory) else { return false }
        let context = sidecar.readContext()
        let breadcrumbs = sidecar.readBreadcrumbs()
        let event = buildEvent(
            from: artifact,
            context: context,
            breadcrumbs: breadcrumbs,
            sdk: sdk,
            environmentFallback: environmentFallback
        )
        enqueue(event)
        // Never double-report: drop the artifact (and stale crumbs) once enqueued.
        deletePendingArtifacts(directory: directory)
        sidecar.resetBreadcrumbs()
        return true
    }

    // MARK: Test seam (writer used by tests AND mirrors the handler's format)

    /// Writes a synthetic signal artifact using the **same low-level primitives**
    /// (`open`/`writeCString`/`writeInt`/`backtrace_symbols_fd`) the real handler
    /// uses, so the round-trip test exercises the genuine writer + parser. Frames
    /// are supplied as plain strings (a real crash uses `backtrace_symbols_fd`).
    static func writeSyntheticSignalArtifact(
        url: URL,
        signal: Int32,
        time: Int64,
        frames: [String]
    ) {
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let pathC = url.path.utf8CString.map { $0 }
        let fd = pathC.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return open(base, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        }
        guard fd >= 0 else { return }
        writeCString(fd, signalMarkerC); writeNewline(fd)
        writeCString(fd, signalPrefixC); writeInt(fd, Int(signal)); writeNewline(fd)
        writeCString(fd, timePrefixC); writeInt(fd, Int(time)); writeNewline(fd)
        writeCString(fd, framesMarkerC); writeNewline(fd)
        for f in frames {
            let c = f.utf8CString.map { $0 }
            writeCString(fd, c)
            writeNewline(fd)
        }
        close(fd)
    }
}

// MARK: - Async-signal-safe primitives (free functions, no allocation)

/// Writes a NUL-terminated C buffer (minus its NUL) to `fd`. Async-signal-safe:
/// only `write` + pointer arithmetic.
@inline(__always)
private func writeCString(_ fd: Int32, _ cstr: [CChar]) {
    cstr.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress else { return }
        // length excluding the trailing NUL
        var len = buf.count
        if len > 0 && base[len - 1] == 0 { len -= 1 }
        if len > 0 {
            base.withMemoryRebound(to: UInt8.self, capacity: len) { p in
                _ = write(fd, p, len)
            }
        }
    }
}

/// Writes a single '\n'. Async-signal-safe.
@inline(__always)
private func writeNewline(_ fd: Int32) {
    var nl: UInt8 = 0x0A
    _ = write(fd, &nl, 1)
}

/// Writes a base-10 integer using a fixed-size STACK buffer (a homogeneous tuple,
/// never a heap `[UInt8]`) — NO `String`, NO malloc. Async-signal-safe.
@inline(__always)
private func writeInt(_ fd: Int32, _ value: Int) {
    // 24 bytes covers any 64-bit value plus a sign. A tuple lives on the stack,
    // so digit formatting never allocates.
    var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
    let capacity = 24
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.bindMemory(to: UInt8.self)
        var n = value
        var negative = false
        if n < 0 { negative = true; n = -n }
        var i = capacity
        if n == 0 {
            i -= 1
            p[i] = 0x30 // '0'
        } else {
            while n > 0 {
                i -= 1
                p[i] = UInt8(0x30 + (n % 10))
                n /= 10
            }
        }
        if negative {
            i -= 1
            p[i] = 0x2D // '-'
        }
        if let base = p.baseAddress {
            _ = write(fd, base + i, capacity - i)
        }
    }
}

// MARK: - sigaction handler-field shims (union access differs per platform)

/// Sets the handler function pointer in a `sigaction`, abstracting the
/// Darwin (`__sigaction_u.__sa_handler`) vs Glibc (`__sigaction_handler`) union.
@inline(__always)
private func setHandler(in action: UnsafeMutablePointer<sigaction>, to handler: @escaping @convention(c) (Int32) -> Void) {
    #if canImport(Darwin)
    action.pointee.__sigaction_u.__sa_handler = handler
    #else
    action.pointee.__sigaction_handler.sa_handler = handler
    #endif
}

/// Sets the handler field to `SIG_DFL`.
@inline(__always)
private func setHandlerDefault(in action: UnsafeMutablePointer<sigaction>) {
    #if canImport(Darwin)
    action.pointee.__sigaction_u.__sa_handler = SIG_DFL
    #else
    action.pointee.__sigaction_handler.sa_handler = SIG_DFL
    #endif
}
