import XCTest
@testable import BugWatch

/// Wire-contract tests for the structured native crash payload (SP1): a v2 event
/// carries `binaryImages` + `nativeStacktrace`, the inner fields use the
/// native/Symbolicator snake_case contract (`debug_id`, `image_addr`,
/// `instruction_addr`), and a legacy (v1) event omits all of it.
final class BugWatchEventCodableTests: XCTestCase {

    private func encodeJSON(_ event: BugWatchEvent) throws -> String {
        let data = try JSONEncoder().encode(event)
        return String(decoding: data, as: UTF8.self)
    }

    func testStructuredEventEncodesNativeDebugMetaKeys() throws {
        let image = BinaryImage(
            name: "MyApp",
            debugId: "79a20e2c-15b6-35f8-af3c-44b135ea12d9",
            arch: "arm64",
            imageAddr: "0x104a14000",
            imageSize: 33492,
            isMainImage: true
        )
        let frame = NativeFrame(
            frameIndex: 0,
            instructionAddr: "0x104a1c2d4",
            imageAddr: "0x104a14000",
            imageName: "MyApp",
            rawSymbol: "0   MyApp  0x0000000104a1c2d4 0x104a14000 + 33492",
            inApp: true
        )
        let event = BugWatchEvent(
            eventId: "bw_e_1", time: 1_000, level: Severity.fatal.rawValue,
            sdk: SdkInfo(name: "bugwatch-ios", version: "0.1.0"),
            platform: "ios",
            binaryImages: [image], nativeStacktrace: [frame],
            crashedThreadId: 0, payloadVersion: 2
        )

        let json = try encodeJSON(event)
        // Top-level new fields (camelCase envelope, like installId/sessionId).
        XCTAssertTrue(json.contains("\"binaryImages\""), json)
        XCTAssertTrue(json.contains("\"nativeStacktrace\""), json)
        XCTAssertTrue(json.contains("\"payloadVersion\":2"), json)
        XCTAssertTrue(json.contains("\"crashedThreadId\":0"), json)
        // Inner native debug-meta fields (snake_case contract).
        XCTAssertTrue(json.contains("\"debug_id\""), json)
        XCTAssertTrue(json.contains("\"image_addr\""), json)
        XCTAssertTrue(json.contains("\"instruction_addr\""), json)
        XCTAssertTrue(json.contains("\"is_main_image\":true"), json)
        XCTAssertTrue(json.contains("\"frame_index\":0"), json)

        // Round-trips losslessly, including the 64-bit-safe hex addresses.
        let decoded = try JSONDecoder().decode(BugWatchEvent.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.payloadVersion, 2)
        XCTAssertEqual(decoded.binaryImages?.first?.debugId, "79a20e2c-15b6-35f8-af3c-44b135ea12d9")
        XCTAssertEqual(decoded.binaryImages?.first?.imageAddr, "0x104a14000")
        XCTAssertEqual(decoded.binaryImages?.first?.imageSize, 33492)
        XCTAssertEqual(decoded.nativeStacktrace?.first?.instructionAddr, "0x104a1c2d4")
        XCTAssertEqual(decoded.nativeStacktrace?.first?.inApp, true)
    }

    func testLegacyEventOmitsStructuredFields() throws {
        let event = BugWatchEvent(
            eventId: "bw_e_2", time: 2_000, level: Severity.error.rawValue,
            sdk: SdkInfo(name: "bugwatch-ios", version: "0.1.0"), platform: "ios"
        )
        let json = try encodeJSON(event)
        // Nil optionals are omitted → byte-compatible with the pre-SP1 contract.
        XCTAssertFalse(json.contains("binaryImages"), json)
        XCTAssertFalse(json.contains("nativeStacktrace"), json)
        XCTAssertFalse(json.contains("payloadVersion"), json)
    }
}
