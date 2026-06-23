import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import BugWatch

/// A5 — automatic app-lifecycle breadcrumbs. On UIKit platforms the test posts the
/// real `UIApplication` notifications through an isolated `NotificationCenter` and
/// asserts the resulting breadcrumb. On the macOS host (no `UIApplication`), it
/// drives the internal `handle(_:)` directly — the event→breadcrumb mapping is the
/// same code path either way.
final class LifecycleInstrumentationTests: XCTestCase {

    /// Collects breadcrumbs the instrumentation produces.
    private final class Collector {
        private(set) var crumbs: [Breadcrumb] = []
        let lock = NSLock()
        func sink(_ crumb: Breadcrumb) {
            lock.lock(); crumbs.append(crumb); lock.unlock()
        }
    }

    // MARK: - Pure mapping (every platform)

    /// Each logical lifecycle event maps to an `app.lifecycle` info breadcrumb whose
    /// `data["event"]` is the event's stable wire name.
    func testEventMappingProducesLifecycleBreadcrumb() {
        for event in LifecycleInstrumentation.Event.allCases {
            let crumb = LifecycleInstrumentation.breadcrumb(for: event)
            XCTAssertEqual(crumb.category, "app.lifecycle")
            XCTAssertEqual(crumb.level, .info)
            XCTAssertEqual(crumb.type, "system")
            XCTAssertEqual(crumb.data?["event"], event.rawValue)
            XCTAssertEqual(crumb.message, event.message)
        }
    }

    /// Calling the internal handler routes a breadcrumb to the sink (the path tests
    /// use on the macOS host where the UIKit notifications don't fire).
    func testHandleRoutesBreadcrumbToSink() {
        let collector = Collector()
        let instrumentation = LifecycleInstrumentation(sink: collector.sink)
        instrumentation.handle(.didEnterBackground)

        XCTAssertEqual(collector.crumbs.count, 1)
        let crumb = try! XCTUnwrap(collector.crumbs.first)
        XCTAssertEqual(crumb.category, "app.lifecycle")
        XCTAssertEqual(crumb.data?["event"], "app.background")
    }

    // MARK: - UIKit notification path (iOS / tvOS)

    #if canImport(UIKit)
    /// Posting the real lifecycle notifications through an isolated center adds one
    /// breadcrumb per notification, in order. Uses a private `NotificationCenter` so
    /// the test never depends on global app state.
    func testPostingNotificationsAddsBreadcrumbs() {
        let center = NotificationCenter()
        let collector = Collector()
        let instrumentation = LifecycleInstrumentation(sink: collector.sink, center: center)
        instrumentation.install()
        defer { instrumentation.uninstall() }

        let expected: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "app.foreground.active"),
            (UIApplication.willResignActiveNotification, "app.resign.active"),
            (UIApplication.didEnterBackgroundNotification, "app.background"),
            (UIApplication.willEnterForegroundNotification, "app.foreground"),
            (UIApplication.didReceiveMemoryWarningNotification, "device.memory.low"),
        ]

        // Observers were registered on the main queue, so post + drain on main.
        let done = expectation(description: "breadcrumbs recorded")
        DispatchQueue.main.async {
            for (name, _) in expected {
                center.post(name: name, object: nil)
            }
            // Hop once more so the main-queue observer blocks have all run.
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 5)

        collector.lock.lock()
        let recorded = collector.crumbs
        collector.lock.unlock()
        XCTAssertEqual(recorded.count, expected.count)
        for (crumb, (_, wire)) in zip(recorded, expected) {
            XCTAssertEqual(crumb.category, "app.lifecycle")
            XCTAssertEqual(crumb.data?["event"], wire)
        }
    }

    /// After `uninstall()`, posting a notification records nothing.
    func testUninstallStopsObserving() {
        let center = NotificationCenter()
        let collector = Collector()
        let instrumentation = LifecycleInstrumentation(sink: collector.sink, center: center)
        instrumentation.install()
        instrumentation.uninstall()

        let done = expectation(description: "drained")
        DispatchQueue.main.async {
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 5)

        collector.lock.lock()
        let count = collector.crumbs.count
        collector.lock.unlock()
        XCTAssertEqual(count, 0, "no breadcrumbs after uninstall")
    }
    #endif
}
