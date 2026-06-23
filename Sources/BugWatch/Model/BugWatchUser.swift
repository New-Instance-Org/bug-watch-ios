import Foundation

/// Identity of the end user affected by an event. All fields optional; supply
/// only what the merchant intentionally wants attached.
public struct BugWatchUser: Codable, Sendable, Equatable {
    public var id: String?
    public var email: String?
    public var username: String?
    public var ip: String?

    public init(id: String? = nil, email: String? = nil, username: String? = nil, ip: String? = nil) {
        self.id = id
        self.email = email
        self.username = username
        self.ip = ip
    }
}
