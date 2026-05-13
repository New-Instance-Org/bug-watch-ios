import XCTest
@testable import LiveAndAiChat

final class LiveAndAiChatConfigTests: XCTestCase {
    func testEndpointsDeriveCorrectly() throws {
        // Debug builds (this is the test target) accept the override —
        // mirrors the Android `endpoints derive correctly` test.
        let cfg = try LiveAndAiChatConfig(
            apiKey: "sk_live_k",
            baseUrl: "https://chat.example.com"
        )
        XCTAssertEqual(cfg.gqlEndpoint.absoluteString, "https://chat.example.com/service")
        XCTAssertEqual(cfg.sseEndpoint.absoluteString, "https://chat.example.com/graphql/stream")
        XCTAssertEqual(cfg.wsEndpoint.absoluteString, "wss://chat.example.com/graphql/ws")
    }

    func testHttpBaseProducesWsNotWss() throws {
        let cfg = try LiveAndAiChatConfig(apiKey: "k", baseUrl: "http://localhost:8010")
        XCTAssertEqual(cfg.wsEndpoint.absoluteString, "ws://localhost:8010/graphql/ws")
    }

    func testDefaultBaseUrlIsProductionService() throws {
        let cfg = try LiveAndAiChatConfig(apiKey: "k")
        XCTAssertEqual(cfg.baseUrl, "https://service.newinstance.cloud")
        XCTAssertEqual(cfg.gqlEndpoint.absoluteString, "https://service.newinstance.cloud/service")
        XCTAssertEqual(cfg.wsEndpoint.absoluteString, "wss://service.newinstance.cloud/graphql/ws")
    }

    func testBlankApiKeyRejected() {
        XCTAssertThrowsError(try LiveAndAiChatConfig(apiKey: "", baseUrl: "https://chat.example.com"))
    }

    func testNonHttpBaseRejected() {
        XCTAssertThrowsError(try LiveAndAiChatConfig(apiKey: "k", baseUrl: "ftp://chat.example.com"))
    }

    func testKeyWithColonIsAcceptedButStripped() throws {
        let cfg = try LiveAndAiChatConfig(apiKey: "sk_live_k:secret", baseUrl: "https://chat.example.com")
        XCTAssertEqual(cfg.apiKey, "sk_live_k:secret")
        XCTAssertEqual(cfg.effectiveApiKey, "sk_live_k")
    }
}
