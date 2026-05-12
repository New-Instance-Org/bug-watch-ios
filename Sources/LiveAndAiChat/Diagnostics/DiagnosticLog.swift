import Foundation

/// Public hook so hosts can intercept the SDK's diagnostic log
/// stream (the `[LAC/SSE] …` lines emitted by the SSE transport).
/// The Example app uses this to surface the SSE lifecycle in its
/// Event log so a user can copy/share the transcript when filing a
/// bug.
///
/// Thread-safety: the handler may be invoked from any queue. If your
/// handler mutates UI state, dispatch back to `MainActor` /
/// `DispatchQueue.main` inside the closure.
public enum LACDiagnosticLog {
    public typealias Handler = (String) -> Void

    private static let lock = NSLock()
    private static var _handler: Handler?

    /// Install (or remove) the global diagnostic log handler. Passing
    /// `nil` clears it.
    public static func setHandler(_ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        _handler = handler
    }

    /// Internal entry point used by `SseLog` to fan the line out to the
    /// host's handler. No-op when no handler is installed.
    static func emit(_ line: String) {
        let handler: Handler?
        lock.lock()
        handler = _handler
        lock.unlock()
        handler?(line)
    }
}
