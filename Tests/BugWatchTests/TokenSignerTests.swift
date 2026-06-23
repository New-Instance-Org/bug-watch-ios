import XCTest
@testable import BugWatch

final class TokenSignerTests: XCTestCase {
    // The per-project secret used by the pinned vectors.
    private let secret = "qHJ80UA2fcTfpi-yiobmScytk-YlkWkAYGPO6DGsvQk"

    /// KNOWN VECTOR 1 — pure HMAC-SHA256 → base64url over a fixed message.
    func testKnownVectorPureHMAC() {
        let sig = TokenSigner.hmacBase64URL(key: secret, message: "hello.world")
        XCTAssertEqual(sig, "K0aC6D-y0HzMNQesM4_Wes2t_OV_vWX38dfUGFP7DLk")
    }

    /// KNOWN VECTOR 2 — full token with a fixed clock + nonce.
    func testKnownVectorFullToken() {
        let signer = TokenSigner(appSecret: secret)
        let now = Date(timeIntervalSince1970: 1_700_000_000) // iat
        let token = signer.sign(pid: "proj_abc123", env: "production", now: now, nonce: "0123456789abcdef")

        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        XCTAssertEqual(parts.count, 2)

        let expectedBody = "eyJwaWQiOiJwcm9qX2FiYzEyMyIsImVudiI6InByb2R1Y3Rpb24iLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MTcwMDAwMDMwMCwibm9uY2UiOiIwMTIzNDU2Nzg5YWJjZGVmIn0"
        let expectedSig = "QFH1H4KLlrYOGH8IwjnwxSQQi5znVSED9P3aCy4pVDc"
        XCTAssertEqual(parts[0], expectedBody, "body mismatch")
        XCTAssertEqual(parts[1], expectedSig, "sig mismatch")
        XCTAssertEqual(token, expectedBody + "." + expectedSig)
    }

    /// The claims JSON must be built in the exact pinned key order with no spaces.
    func testClaimsJSONCanonicalOrder() {
        let json = TokenSigner.claimsJSON(pid: "proj_abc123", env: "production", iat: 1_700_000_000, exp: 1_700_000_300, nonce: "0123456789abcdef")
        XCTAssertEqual(json, "{\"pid\":\"proj_abc123\",\"env\":\"production\",\"iat\":1700000000,\"exp\":1700000300,\"nonce\":\"0123456789abcdef\"}")
    }

    /// exp is always iat + 300.
    func testExpiryIsFiveMinutes() {
        let signer = TokenSigner(appSecret: secret)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = signer.sign(pid: "p", env: "e", now: now, nonce: "abc")
        let body = String(token.split(separator: ".").first!)
        // Decode the base64url body back to JSON and assert exp - iat == 300.
        var b64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let data = Data(base64Encoded: b64)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let iat = (obj["iat"] as! NSNumber).int64Value
        let exp = (obj["exp"] as! NSNumber).int64Value
        XCTAssertEqual(exp - iat, 300)
    }

    /// base64url uses -/_ and strips padding.
    func testBase64URLAlphabet() {
        // 0xFF 0xFE 0xFD → standard "//79", base64url "__79".
        let encoded = Base64URL.encode(Data([0xFF, 0xFE, 0xFD]))
        XCTAssertEqual(encoded, "__79")
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }

    /// randomNonce is 16 lowercase hex chars.
    func testRandomNonceShape() {
        let nonce = TokenSigner.randomNonce()
        XCTAssertEqual(nonce.count, 16)
        XCTAssertTrue(nonce.allSatisfy { "0123456789abcdef".contains($0) })
    }
}
