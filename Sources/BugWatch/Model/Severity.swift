import Foundation

/// BugWatch severity levels. Numeric values match the platform-wide scale used
/// by every BugWatch SDK and the ingest API.
public enum Severity: Int, Codable, Sendable, Comparable {
    case trace = 10
    case debug = 20
    case info = 30
    case warn = 40
    case error = 50
    case fatal = 60

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
