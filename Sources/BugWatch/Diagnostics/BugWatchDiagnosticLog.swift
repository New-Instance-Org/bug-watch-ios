import Foundation

/// Public hook so hosts can intercept the SDK's internal diagnostic log
/// stream (the `[BugWatch] …` lines the SDK emits when `debug` is enabled).
///
/// Thread-safety: the handler may be invoked from any queue. If your handler
/// mutates UI state, dispatch back to the main queue inside the closure.
public enum BugWatchDiagnosticLog {
    public typealias Handler = (String) -> Void

    private static let lock = NSLock()
    private static var _handler: Handler?

    /// Install (or remove) the global diagnostic log handler. Passing `nil`
    /// clears it.
    public static func setHandler(_ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        _handler = handler
    }

    /// Internal entry point used by the SDK to fan a line out to the host's
    /// handler. No-op when no handler is installed.
    static func emit(_ line: String) {
        let handler: Handler?
        lock.lock()
        handler = _handler
        lock.unlock()
        handler?(line)
    }
}
