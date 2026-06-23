import XCTest
@testable import BugWatch

final class CrashContextSidecarTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-sidecar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// The context sidecar round-trips device + release + env + ids through disk.
    func testContextWriteRead() {
        let sidecar = CrashContextSidecar(directory: dir)
        let context = CrashContextSidecar.Context(
            installId: "install-1",
            sessionId: "bw_s_1",
            release: "2.0.0+9",
            environment: "production",
            device: DeviceInfo(model: "iPhone15,2", family: "iPhone", osName: "iOS", osVersion: "17.4"),
            startedAt: 1_700_000_000_000
        )
        sidecar.writeContext(context)

        // Fresh instance over the same directory — simulates the next launch.
        let next = CrashContextSidecar(directory: dir)
        let read = try! XCTUnwrap(next.readContext())
        XCTAssertEqual(read, context)
        XCTAssertEqual(read.device?.model, "iPhone15,2")
    }

    /// Missing sidecar reads back as nil (not a crash).
    func testReadContextMissingReturnsNil() {
        let sidecar = CrashContextSidecar(directory: dir)
        XCTAssertNil(sidecar.readContext())
    }

    /// Breadcrumbs append in order and survive across instances.
    func testBreadcrumbAppendAndRead() {
        let sidecar = CrashContextSidecar(directory: dir)
        sidecar.appendBreadcrumb(Breadcrumb(category: "nav", message: "a"))
        sidecar.appendBreadcrumb(Breadcrumb(category: "nav", message: "b"))
        sidecar.appendBreadcrumb(Breadcrumb(category: "http", type: "http", level: .info, message: "c"))

        let next = CrashContextSidecar(directory: dir)
        let crumbs = next.readBreadcrumbs()
        XCTAssertEqual(crumbs.map { $0.message }, ["a", "b", "c"])
        XCTAssertEqual(crumbs.last?.category, "http")
    }

    /// The ring is bounded: only the newest `maxBreadcrumbs` survive.
    func testBreadcrumbRingIsBounded() {
        let sidecar = CrashContextSidecar(directory: dir, maxBreadcrumbs: 3)
        for i in 1...10 { sidecar.appendBreadcrumb(Breadcrumb(category: "c", message: "m\(i)")) }
        let crumbs = sidecar.readBreadcrumbs()
        XCTAssertEqual(crumbs.count, 3)
        XCTAssertEqual(crumbs.map { $0.message }, ["m8", "m9", "m10"], "newest retained, oldest dropped")
    }

    /// clear() removes both files; resetBreadcrumbs() drops only crumbs.
    func testClearAndResetBreadcrumbs() {
        let sidecar = CrashContextSidecar(directory: dir)
        sidecar.writeContext(CrashContextSidecar.Context(installId: "i"))
        sidecar.appendBreadcrumb(Breadcrumb(category: "c", message: "m"))

        sidecar.resetBreadcrumbs()
        XCTAssertTrue(sidecar.readBreadcrumbs().isEmpty)
        XCTAssertNotNil(sidecar.readContext(), "resetBreadcrumbs keeps context")

        sidecar.clear()
        XCTAssertNil(sidecar.readContext())
        XCTAssertTrue(sidecar.readBreadcrumbs().isEmpty)
    }

    /// Concurrent breadcrumb appends never corrupt a line (each stays parseable).
    func testConcurrentBreadcrumbAppends() {
        let sidecar = CrashContextSidecar(directory: dir, maxBreadcrumbs: 10_000)
        let group = DispatchGroup()
        for i in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                sidecar.appendBreadcrumb(Breadcrumb(category: "c", message: "m\(i)"))
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(sidecar.readBreadcrumbs().count, 200, "no lost or corrupted appends")
    }
}
