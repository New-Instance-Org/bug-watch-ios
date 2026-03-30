import XCTest
@testable import NISDK

final class NISDKTests: XCTestCase {
    func testUsesDefaultBaseURLForEnvironment() {
        let configuration = NISDKConfiguration(
            apiKey: "test-key",
            environment: .sandbox
        )

        XCTAssertEqual(
            configuration.baseURL,
            URL(string: "https://sandbox.example.com")
        )
    }

    func testBuildsDefaultHeaders() {
        let sdk = NISDK(
            configuration: NISDKConfiguration(apiKey: "test-key")
        )

        XCTAssertEqual(
            sdk.defaultHeaders(),
            [
                "x-sdk-api-key": "test-key",
                "x-sdk-platform": "ios"
            ]
        )
    }
}
