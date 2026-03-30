import Foundation

public final class NISDK {
    public static let version = "0.1.0"

    public let configuration: NISDKConfiguration

    public init(configuration: NISDKConfiguration) {
        self.configuration = configuration
    }

    public func defaultHeaders() -> [String: String] {
        [
            "x-sdk-api-key": configuration.apiKey,
            "x-sdk-platform": "ios"
        ]
    }

    public func statusMessage() -> String {
        "NISDK ready for \(configuration.environment.rawValue)."
    }
}
