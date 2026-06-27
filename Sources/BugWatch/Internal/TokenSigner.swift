import Foundation
// Prefer swift-crypto's `Crypto` (SwiftPM dependency); fall back to the system
// `CryptoKit` (e.g. a CocoaPods/Xcode build that doesn't vendor swift-crypto).
// Both expose identical `HMAC<SHA256>` + `SymmetricKey` APIs.
#if canImport(Crypto)
import Crypto
#else
import CryptoKit
#endif

/// Encodes `Data` / `String` as **base64url** (RFC 4648 5): standard base64
/// with `+`→`-`, `/`→`_`, and `=` padding stripped. Shared by the token signer
/// and any other code that needs URL-safe base64.
enum Base64URL {
    /// base64url-encode raw bytes.
    static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        // Strip '=' padding.
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// base64url-encode the UTF-8 bytes of a string.
    static func encode(_ string: String) -> String {
        encode(Data(string.utf8))
    }
}

/// Signs the short-lived ingest token the mobile SDK presents in the
/// `x-bugwatch-token` header. The token is an HMAC-SHA256 over a base64url JSON
/// claims body, keyed by the per-project `appSecret`. **The secret is never
/// transmitted** — only the resulting token.
///
/// Contract (must match the backend byte-for-byte):
/// ```
/// body  = base64url(utf8( {"pid":"…","env":"…","iat":N,"exp":N,"nonce":"…"} ))
/// sig   = base64url( HMAC_SHA256(key = utf8(appSecret), msg = utf8(body)) )
/// token = body + "." + sig
/// ```
/// The claims JSON is built **manually** in this exact key order with no
/// whitespace — `JSONEncoder` is deliberately avoided because its key ordering
/// is nondeterministic and would break the signature.
struct TokenSigner {
    /// The per-project secret (a base64url string), used as the raw HMAC key bytes.
    let appSecret: String

    /// Pure HMAC-SHA256 → base64url. Exposed for testing against known vectors.
    static func hmacBase64URL(key: String, message: String) -> String {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Base64URL.encode(Data(mac))
    }

    /// Builds the canonical claims JSON string in the pinned key order.
    /// Built by hand (not `JSONEncoder`) to guarantee deterministic ordering.
    static func claimsJSON(pid: String, env: String, iat: Int64, exp: Int64, nonce: String) -> String {
        "{\"pid\":\"\(escape(pid))\",\"env\":\"\(escape(env))\",\"iat\":\(iat),\"exp\":\(exp),\"nonce\":\"\(escape(nonce))\"}"
    }

    /// Minimal JSON string escaping for values interpolated into the claims body.
    /// pid/env/nonce are controlled values, but escape defensively so a stray
    /// quote/backslash can never produce malformed JSON or a forgeable body.
    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Builds a signed token for the given claims. `now` and `nonce` are
    /// injectable so the signer can be asserted against fixed vectors in tests.
    /// `exp` is `iat + 300` (5 minutes).
    func sign(pid: String, env: String, now: Date, nonce: String) -> String {
        let iat = Int64(now.timeIntervalSince1970)
        let exp = iat + 300
        let body = Base64URL.encode(Self.claimsJSON(pid: pid, env: env, iat: iat, exp: exp, nonce: nonce))
        let sig = Self.hmacBase64URL(key: appSecret, message: body)
        return body + "." + sig
    }

    /// Generates a fresh token using the current time and a random 16-hex-char nonce.
    func signNow(pid: String, env: String) -> String {
        sign(pid: pid, env: env, now: Date(), nonce: Self.randomNonce())
    }

    /// 16 random lowercase hex characters (8 random bytes).
    static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
