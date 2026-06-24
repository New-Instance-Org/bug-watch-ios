import XCTest
@testable import BugWatch

/// SP1 round-trip: the crash handler's structured `addrs:` + `images:` sections
/// survive write → parse → buildEvent with full fidelity, and a legacy (v1)
/// artifact still parses + builds exactly as before.
final class CrashArtifactRoundTripTests: XCTestCase {

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-artifact-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func parseFile(_ url: URL) throws -> CrashReporter.CrashArtifact {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(CrashReporter.parse(text))
    }

    func testV2ArtifactRoundTrips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = CrashReporter.signalArtifactURL(directory: dir)
        let img = BinaryImage(
            name: "/private/var/containers/MyApp.app/MyApp",
            debugId: "79a20e2c-15b6-35f8-af3c-44b135ea12d9",
            arch: "arm64", imageAddr: "0x104a14000", imageSize: 16384, isMainImage: true
        )
        CrashReporter.writeSyntheticSignalArtifact(
            url: url, signal: SIGSEGV, time: 1_000,
            frames: ["0   MyApp  0x0000000104a1c2d4 0x104a14000 + 33492"],
            frameAddrs: [0x1_04a1_c2d4],
            images: [img]
        )
        let a = try parseFile(url)
        XCTAssertEqual(a.frameAddrs, [0x1_04a1_c2d4])
        XCTAssertEqual(a.images.count, 1)
        let parsed = try XCTUnwrap(a.images.first)
        XCTAssertEqual(parsed.uuid, "79a20e2c-15b6-35f8-af3c-44b135ea12d9")
        XCTAssertEqual(parsed.loadAddr, 0x1_04a1_4000)
        XCTAssertEqual(parsed.size, 16384)
        XCTAssertEqual(parsed.arch, "arm64")
        XCTAssertEqual(parsed.isMain, true)
        XCTAssertEqual(parsed.name, "/private/var/containers/MyApp.app/MyApp")
    }

    func testV1ArtifactBackCompat() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = CrashReporter.signalArtifactURL(directory: dir)
        // No frameAddrs/images → a legacy artifact with no structured sections.
        CrashReporter.writeSyntheticSignalArtifact(url: url, signal: SIGABRT, time: 2_000, frames: ["frameA", "frameB"])
        let a = try parseFile(url)
        XCTAssertEqual(a.frameAddrs, [])
        XCTAssertEqual(a.images, [])
        XCTAssertEqual(a.frames, ["frameA", "frameB"])
    }

    func testBuildEventMapsStructuredFields() throws {
        let artifact = CrashReporter.CrashArtifact(
            type: .signal, signal: SIGSEGV, signalName: "SIGSEGV",
            name: nil, reason: nil, time: 1_000,
            frames: ["0   MyApp  0x0000000104a1c2d4 0x104a14000 + 33492"],
            frameAddrs: [0x1_04a1_c2d4],
            images: [CrashReporter.ImageRecord(
                loadAddr: 0x1_04a1_4000, size: 16384,
                uuid: "79a20e2c-15b6-35f8-af3c-44b135ea12d9", arch: "arm64",
                isMain: true, name: "MyApp")]
        )
        let event = CrashReporter.buildEvent(
            from: artifact, context: nil, breadcrumbs: [],
            sdk: SdkInfo(name: "bugwatch-ios", version: "0.1.0"),
            environmentFallback: "production"
        )
        XCTAssertEqual(event.payloadVersion, 2)
        XCTAssertEqual(event.binaryImages?.count, 1)
        XCTAssertEqual(event.binaryImages?.first?.debugId, "79a20e2c-15b6-35f8-af3c-44b135ea12d9")
        XCTAssertEqual(event.binaryImages?.first?.imageAddr, "0x104a14000")
        XCTAssertEqual(event.binaryImages?.first?.isMainImage, true)
        let frame = try XCTUnwrap(event.nativeStacktrace?.first)
        XCTAssertEqual(frame.frameIndex, 0)
        XCTAssertEqual(frame.instructionAddr, "0x104a1c2d4")
        XCTAssertEqual(frame.rawSymbol, "0   MyApp  0x0000000104a1c2d4 0x104a14000 + 33492")
        // The legacy exception.stacktrace (raw strings) is preserved too.
        XCTAssertEqual(event.exception?.stacktrace?.count, 1)
    }

    func testBuildEventLegacyHasNoStructuredFields() {
        let artifact = CrashReporter.CrashArtifact(
            type: .signal, signal: SIGABRT, signalName: "SIGABRT",
            name: nil, reason: nil, time: 1, frames: ["x"]
        )
        let event = CrashReporter.buildEvent(
            from: artifact, context: nil, breadcrumbs: [],
            sdk: SdkInfo(name: "bugwatch-ios", version: "0.1.0"),
            environmentFallback: "production"
        )
        XCTAssertNil(event.payloadVersion)
        XCTAssertNil(event.binaryImages)
        XCTAssertNil(event.nativeStacktrace)
    }
}
