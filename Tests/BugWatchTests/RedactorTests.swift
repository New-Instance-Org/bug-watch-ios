import XCTest
@testable import BugWatch

final class RedactorTests: XCTestCase {
    func testRedactsMatchingKeysCaseInsensitively() {
        let r = Redactor(sensitiveFields: ["password", "accessToken"])
        let input = ["Password": "hunter2", "AccessToken": "abc", "screen": "checkout"]
        let out = r.redact(input)
        XCTAssertEqual(out?["Password"], "[Filtered]")
        XCTAssertEqual(out?["AccessToken"], "[Filtered]")
        XCTAssertEqual(out?["screen"], "checkout")
    }

    func testSeparatorInsensitiveMatch() {
        // configured "accesstoken" should match access_token / access-token / accessToken
        let r = Redactor(sensitiveFields: ["accesstoken"])
        let out = r.redact(["access_token": "a", "access-token": "b", "accessToken": "c"])
        XCTAssertEqual(out?["access_token"], "[Filtered]")
        XCTAssertEqual(out?["access-token"], "[Filtered]")
        XCTAssertEqual(out?["accessToken"], "[Filtered]")
    }

    func testNonSensitiveUntouched() {
        let r = Redactor(sensitiveFields: ["password"])
        let out = r.redact(["city": "Lagos", "count": "3"])
        XCTAssertEqual(out, ["city": "Lagos", "count": "3"])
    }

    func testEmptySensitiveSetReturnsInputUnchanged() {
        let r = Redactor(sensitiveFields: [])
        let input = ["password": "secret"]
        XCTAssertEqual(r.redact(input), input)
    }

    func testNilInputNilOutput() {
        let r = Redactor(sensitiveFields: ["password"])
        XCTAssertNil(r.redact(nil as [String: String]?))
    }

    func testRedactsUserFields() {
        let r = Redactor(sensitiveFields: ["email", "ip"])
        let user = BugWatchUser(id: "u1", email: "a@b.com", username: "amy", ip: "1.2.3.4")
        let out = r.redact(user)
        XCTAssertEqual(out?.id, "u1")
        XCTAssertEqual(out?.email, "[Filtered]")
        XCTAssertEqual(out?.username, "amy")
        XCTAssertEqual(out?.ip, "[Filtered]")
    }

    func testRedactsBreadcrumbDataRecursively() {
        let r = Redactor(sensitiveFields: ["token"])
        let crumb = Breadcrumb(category: "auth", message: "login", data: ["token": "xyz", "method": "otp"])
        let out = r.redact([crumb])
        XCTAssertEqual(out?.first?.data?["token"], "[Filtered]")
        XCTAssertEqual(out?.first?.data?["method"], "otp")
    }

    func testDefaultSensitiveFieldsCoverCommonSecrets() {
        let r = Redactor(sensitiveFields: BugWatchOptions.defaultSensitiveFields)
        let out = r.redact(["password": "x", "authorization": "Bearer y", "cardNumber": "4111", "ok": "v"])
        XCTAssertEqual(out?["password"], "[Filtered]")
        XCTAssertEqual(out?["authorization"], "[Filtered]")
        XCTAssertEqual(out?["cardNumber"], "[Filtered]")
        XCTAssertEqual(out?["ok"], "v")
    }
}
