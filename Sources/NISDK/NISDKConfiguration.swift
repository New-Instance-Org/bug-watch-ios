import Foundation

public enum NISDKEnvironment: String, CaseIterable {
    case sandbox
    case production

    public var defaultBaseURL: URL {
        switch self {
        case .sandbox:
            return URL(string: "https://sandbox.example.com")!
        case .production:
            return URL(string: "https://api.example.com")!
        }
    }
}

public struct NISDKConfiguration: Equatable {
    public let apiKey: String
    public let environment: NISDKEnvironment
    public let baseURL: URL

    public init(
        apiKey: String,
        environment: NISDKEnvironment = .sandbox,
        baseURL: URL? = nil
    ) {
        self.apiKey = apiKey
        self.environment = environment
        self.baseURL = baseURL ?? environment.defaultBaseURL
    }
}
