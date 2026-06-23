import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Device / runtime context attached to every outgoing event. All fields are
/// optional on the wire so the backend tolerates partial collection across
/// platforms (iOS device vs. macOS host vs. simulator).
public struct DeviceInfo: Codable, Sendable, Equatable {
    /// Hardware model identifier, e.g. "iPhone15,2" or the host's `hw.machine`.
    public var model: String?
    /// Device family, e.g. "iPhone", "iPad", "Mac".
    public var family: String?
    /// OS name, e.g. "iOS", "iPadOS", "macOS".
    public var osName: String?
    /// OS version string, e.g. "17.4.1".
    public var osVersion: String?
    /// Active locale identifier, e.g. "en_US".
    public var locale: String?
    /// IANA timezone identifier, e.g. "Africa/Lagos".
    public var timezone: String?
    /// Whether the app is running in a simulator.
    public var simulator: Bool?
    /// App marketing version (CFBundleShortVersionString).
    public var appVersion: String?
    /// App build number (CFBundleVersion).
    public var appBuild: String?
    /// Host app bundle identifier.
    public var bundleId: String?

    public init(
        model: String? = nil,
        family: String? = nil,
        osName: String? = nil,
        osVersion: String? = nil,
        locale: String? = nil,
        timezone: String? = nil,
        simulator: Bool? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        bundleId: String? = nil
    ) {
        self.model = model
        self.family = family
        self.osName = osName
        self.osVersion = osVersion
        self.locale = locale
        self.timezone = timezone
        self.simulator = simulator
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleId = bundleId
    }
}

/// Collects `DeviceInfo` and a stable, persisted install id. On iOS it reads
/// `UIDevice`; on the macOS host (where the package must still build/test) it
/// falls back to `ProcessInfo` / `utsname`.
enum DeviceContext {
    /// UserDefaults suite the SDK uses for its own persisted state.
    static let suiteName = "cloud.newinstance.bugwatch"
    /// Key under which the install id is stored.
    static let installIdKey = "bw_install_id"

    /// A random UUID generated once on first launch and persisted thereafter.
    /// Identifies a single install of the host app (cleared on app delete).
    static func installId() -> String {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if let existing = defaults.string(forKey: installIdKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: installIdKey)
        return fresh
    }

    /// Builds a `DeviceInfo` snapshot for the current process.
    static func collect() -> DeviceInfo {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let bundleId = bundle.bundleIdentifier
        let locale = Locale.current.identifier
        let timezone = TimeZone.current.identifier

        #if canImport(UIKit)
        let device = UIDevice.current
        let osName = device.systemName            // "iOS" / "iPadOS"
        let osVersion = device.systemVersion
        let family = device.model                  // "iPhone" / "iPad"
        let model = hardwareModel()
        let simulator = isSimulator()
        return DeviceInfo(
            model: model,
            family: family,
            osName: osName,
            osVersion: osVersion,
            locale: locale,
            timezone: timezone,
            simulator: simulator,
            appVersion: appVersion,
            appBuild: appBuild,
            bundleId: bundleId
        )
        #else
        // macOS host fallback so the package builds and tests off-device.
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        let osVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return DeviceInfo(
            model: hardwareModel(),
            family: "Mac",
            osName: "macOS",
            osVersion: osVersion,
            locale: locale,
            timezone: timezone,
            simulator: false,
            appVersion: appVersion,
            appBuild: appBuild,
            bundleId: bundleId
        )
        #endif
    }

    /// Hardware model identifier via `uname()` (`hw.machine` equivalent). On a
    /// simulator this returns the host Mac's identifier, so `simulator` is
    /// reported separately.
    private static func hardwareModel() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let chars = mirror.children.compactMap { $0.value as? Int8 }.prefix { $0 != 0 }
        let bytes = chars.map { UInt8(bitPattern: $0) }
        let model = String(decoding: bytes, as: UTF8.self)
        return model.isEmpty ? nil : model
    }

    #if canImport(UIKit)
    private static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    #endif
}
