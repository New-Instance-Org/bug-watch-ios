import Foundation

/// Errors surfaced by the BugWatch SDK itself. SDK failures never crash the
/// host app; they are reported through this type and the diagnostic log.
public enum BugWatchError: Error, Equatable {
    case notStarted
    case invalidProjectKey
    case invalidOption(String)
}
