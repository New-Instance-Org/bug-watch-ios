import XCTest
@testable import BugWatch

final class DeviceContextTests: XCTestCase {
    override func tearDown() {
        // Don't leave a test-written install id behind in the shared suite.
        UserDefaults(suiteName: DeviceContext.suiteName)?.removeObject(forKey: DeviceContext.installIdKey)
        super.tearDown()
    }

    /// installId is stable across calls (persisted) and is a lowercase UUID.
    func testInstallIdIsStableAndPersisted() {
        UserDefaults(suiteName: DeviceContext.suiteName)?.removeObject(forKey: DeviceContext.installIdKey)
        let first = DeviceContext.installId()
        let second = DeviceContext.installId()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, first.lowercased())
        XCTAssertEqual(UUID(uuidString: first)?.uuidString.lowercased(), first)
    }

    /// Collection yields a usable snapshot — at minimum osName/osVersion/locale/timezone.
    func testCollectPopulatesCoreFields() {
        let info = DeviceContext.collect()
        XCTAssertNotNil(info.osName)
        XCTAssertFalse(info.osName?.isEmpty ?? true)
        XCTAssertNotNil(info.osVersion)
        XCTAssertNotNil(info.locale)
        XCTAssertNotNil(info.timezone)
        XCTAssertNotNil(info.model)
        #if canImport(UIKit)
        XCTAssertEqual(info.osName, UIDevice.current.systemName)
        #else
        XCTAssertEqual(info.osName, "macOS")
        XCTAssertEqual(info.family, "Mac")
        #endif
    }

    /// DeviceInfo round-trips through JSON with the same field names the wire uses.
    func testDeviceInfoCodableRoundTrip() throws {
        let info = DeviceInfo(model: "iPhone15,2", family: "iPhone", osName: "iOS", osVersion: "17.4",
                              locale: "en_US", timezone: "Africa/Lagos", simulator: true,
                              appVersion: "1.0", appBuild: "1", bundleId: "com.example.app")
        let data = try JSONEncoder().encode(info)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "iPhone15,2")
        XCTAssertEqual(json["osName"] as? String, "iOS")
        XCTAssertEqual(json["simulator"] as? Bool, true)
        let decoded = try JSONDecoder().decode(DeviceInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }
}
