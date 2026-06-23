import Foundation

/// Redacts values whose **key** matches a configured sensitive-field name
/// (case-insensitive), recursively over the `[String: String]` maps the SDK
/// attaches to events (tags, user, breadcrumb data).
///
/// The match is case-insensitive and ignores common separators (`_`, `-`, `.`,
/// spaces) so `access_token`, `accessToken`, and `Access-Token` all match a
/// configured `accesstoken`. Matched values become `"[Filtered]"`.
struct Redactor {
    /// Replacement marker written in place of a redacted value. Matches the
    /// other BugWatch SDKs.
    static let placeholder = "[Filtered]"

    /// Normalized (lowercased, separator-stripped) sensitive keys.
    private let sensitiveKeys: Set<String>

    init(sensitiveFields: [String]) {
        self.sensitiveKeys = Set(sensitiveFields.map { Redactor.normalize($0) })
    }

    /// Whether the given key should have its value redacted.
    func isSensitive(_ key: String) -> Bool {
        sensitiveKeys.contains(Redactor.normalize(key))
    }

    /// Returns a copy of `map` with sensitive values replaced. `nil` in → `nil`
    /// out. Empty sensitive set → returns the input unchanged.
    func redact(_ map: [String: String]?) -> [String: String]? {
        guard let map else { return nil }
        if sensitiveKeys.isEmpty { return map }
        var out = map
        for key in map.keys where isSensitive(key) {
            out[key] = Redactor.placeholder
        }
        return out
    }

    /// Redacts a `BugWatchUser` field-by-field (id/email/username/ip), treating
    /// each property name as a key.
    func redact(_ user: BugWatchUser?) -> BugWatchUser? {
        guard var user else { return nil }
        if sensitiveKeys.isEmpty { return user }
        if isSensitive("id"), user.id != nil { user.id = Redactor.placeholder }
        if isSensitive("email"), user.email != nil { user.email = Redactor.placeholder }
        if isSensitive("username"), user.username != nil { user.username = Redactor.placeholder }
        if isSensitive("ip"), user.ip != nil { user.ip = Redactor.placeholder }
        return user
    }

    /// Redacts the `data` maps of a breadcrumb list.
    func redact(_ crumbs: [Breadcrumb]?) -> [Breadcrumb]? {
        guard let crumbs else { return nil }
        if sensitiveKeys.isEmpty { return crumbs }
        return crumbs.map { crumb in
            var c = crumb
            c.data = redact(crumb.data)
            return c
        }
    }

    /// Lowercases and strips common separators so equivalent key spellings
    /// collapse to the same token.
    static func normalize(_ key: String) -> String {
        var out = ""
        out.reserveCapacity(key.count)
        for ch in key.lowercased() {
            switch ch {
            case "_", "-", ".", " ": continue
            default: out.append(ch)
            }
        }
        return out
    }
}
