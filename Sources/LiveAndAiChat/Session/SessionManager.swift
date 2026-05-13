import Foundation

/// UserDefaults-backed session storage. Key names mirror the web's
/// `sessionStorage` prefix (`nisdk_*`) and the Android `SessionManager`
/// constants so the cross-platform contract feels consistent even though
/// the actual store is different on each OS.
///
/// A dedicated `UserDefaults` suite is used so the SDK never collides with
/// host-app preferences.
final class SessionManager {
    private let defaults: UserDefaults

    init(suiteName: String = "cloud.newinstance.liveandaichat.session") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    var conversationId: String? {
        get { defaults.string(forKey: Keys.conversationId) }
        set { setOrRemove(Keys.conversationId, newValue) }
    }

    var assignmentId: String? {
        get { defaults.string(forKey: Keys.assignmentId) }
        set { setOrRemove(Keys.assignmentId, newValue) }
    }

    var customerName: String? {
        get { defaults.string(forKey: Keys.customerName) }
        set { setOrRemove(Keys.customerName, newValue) }
    }

    var customerEmail: String? {
        get { defaults.string(forKey: Keys.customerEmail) }
        set { setOrRemove(Keys.customerEmail, newValue) }
    }

    var customerId: String? {
        get { defaults.string(forKey: Keys.customerId) }
        set { setOrRemove(Keys.customerId, newValue) }
    }

    func clear() {
        for k in Keys.all { defaults.removeObject(forKey: k) }
    }

    private func setOrRemove(_ key: String, _ value: String?) {
        if let v = value { defaults.set(v, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private enum Keys {
        static let conversationId = "nisdk_conversationId"
        static let assignmentId = "nisdk_assignmentId"
        static let customerName = "nisdk_customerName"
        static let customerEmail = "nisdk_customerEmail"
        static let customerId = "nisdk_customerId"
        static let all = [conversationId, assignmentId, customerName, customerEmail, customerId]
    }
}
