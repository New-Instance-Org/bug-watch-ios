import Foundation

/// A single pre-event breadcrumb. The SDK retains a bounded history and
/// attaches it to outgoing events.
public struct Breadcrumb: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var category: String
    public var type: String
    public var level: Severity
    public var message: String?
    public var data: [String: String]?

    public init(
        category: String,
        type: String = "default",
        level: Severity = .info,
        message: String? = nil,
        data: [String: String]? = nil,
        timestamp: Date = Date()
    ) {
        self.timestamp = timestamp
        self.category = category
        self.type = type
        self.level = level
        self.message = message
        self.data = data
    }
}
