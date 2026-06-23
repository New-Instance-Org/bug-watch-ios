import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Automatic **app-lifecycle breadcrumbs** — A5.
///
/// Observes the standard `UIApplication` lifecycle notifications and drops one
/// breadcrumb (category `"app.lifecycle"`, level `info`) for each, enriching the
/// same bounded breadcrumb buffer the crash/error/hang events attach. This gives a
/// crash report the trail of foreground/background transitions and memory warnings
/// that preceded it.
///
/// ## Cross-platform
/// `UIApplication` only exists on UIKit platforms. The whole observing layer is
/// gated behind `#if canImport(UIKit)` so the macOS host build (used by `swift
/// test` on a Mac) still compiles — on macOS this type installs nothing. The pure
/// event→breadcrumb mapping (`breadcrumb(for:)`) and the internal handler
/// (`handle(_:)`) are available on every platform so the mapping can be unit-tested
/// off-device by calling the handler directly.
///
/// ## Threading / safety
/// Observers are registered on the main queue (lifecycle notifications are posted
/// there). `install()` / `uninstall()` are idempotent. Nothing here can throw into
/// the host; the sink closure is the SDK's redacting `addBreadcrumb`.
final class LifecycleInstrumentation {
    /// The breadcrumb category stamped on every lifecycle crumb.
    static let category = "app.lifecycle"

    /// Logical lifecycle events we record, independent of UIKit so they can be
    /// referenced and tested on any platform.
    enum Event: String, CaseIterable {
        case didBecomeActive = "app.foreground.active"
        case willResignActive = "app.resign.active"
        case didEnterBackground = "app.background"
        case willEnterForeground = "app.foreground"
        case didReceiveMemoryWarning = "device.memory.low"

        /// Human-readable breadcrumb message for the event.
        var message: String {
            switch self {
            case .didBecomeActive: return "App became active"
            case .willResignActive: return "App will resign active"
            case .didEnterBackground: return "App entered background"
            case .willEnterForeground: return "App will enter foreground"
            case .didReceiveMemoryWarning: return "Received memory warning"
            }
        }
    }

    /// Where recorded breadcrumbs go — the SDK passes its redacting `addBreadcrumb`.
    private let sink: (Breadcrumb) -> Void
    /// NotificationCenter to observe (injectable for tests).
    private let center: NotificationCenter
    /// Registered observer tokens, removed on `uninstall()`.
    private var tokens: [NSObjectProtocol] = []
    private var installed = false
    private let lock = NSLock()

    init(sink: @escaping (Breadcrumb) -> Void, center: NotificationCenter = .default) {
        self.sink = sink
        self.center = center
    }

    /// Builds the breadcrumb for a lifecycle event. Pure — no I/O, no UIKit — so
    /// it's directly unit-testable on any platform.
    static func breadcrumb(for event: Event, timestamp: Date = Date()) -> Breadcrumb {
        Breadcrumb(
            category: category,
            type: "system",
            level: .info,
            message: event.message,
            data: ["event": event.rawValue],
            timestamp: timestamp
        )
    }

    /// Records the breadcrumb for a lifecycle event. Exposed (internal) so tests on
    /// the macOS host — where the UIKit notifications don't exist — can drive the
    /// mapping directly without a `UIApplication`.
    func handle(_ event: Event) {
        sink(LifecycleInstrumentation.breadcrumb(for: event))
    }

    /// Begins observing `UIApplication` lifecycle notifications. Idempotent.
    /// No-op on platforms without UIKit (the build still compiles there).
    func install() {
        lock.lock()
        guard !installed else { lock.unlock(); return }
        installed = true
        lock.unlock()

        #if canImport(UIKit)
        let pairs: [(Notification.Name, Event)] = [
            (UIApplication.didBecomeActiveNotification, .didBecomeActive),
            (UIApplication.willResignActiveNotification, .willResignActive),
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.willEnterForegroundNotification, .willEnterForeground),
            (UIApplication.didReceiveMemoryWarningNotification, .didReceiveMemoryWarning),
        ]
        var registered: [NSObjectProtocol] = []
        for (name, event) in pairs {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handle(event)
            }
            registered.append(token)
        }
        lock.lock()
        tokens = registered
        lock.unlock()
        #endif
    }

    /// Stops observing and drops all observer tokens. Idempotent.
    func uninstall() {
        lock.lock()
        let toRemove = tokens
        tokens = []
        installed = false
        lock.unlock()
        for token in toRemove {
            center.removeObserver(token)
        }
    }
}
