import Foundation
import OSLog

/// Transport selection mode. When ``LiveAndAiChatConfig/transport`` is nil
/// the SDK respects the value advertised in the server bootstrap, falling
/// back to ``TransportMode/sse`` if no bootstrap is available.
public enum TransportMode: String, Codable, Sendable {
    case sse
    case ws
}

/// Identity passed to ``LiveAndAiChat/setUser(_:)``. `customerName` is
/// REQUIRED — the backend's `initCsAiChat` rejects blank names and the chat
/// UI cannot attribute the customer's messages without one. `id` and
/// `email` remain optional.
public struct ChatUser: Sendable, Equatable {
    public let customerName: String
    public let customerId: String?
    public let customerEmail: String?

    public init(customerName: String, customerId: String? = nil, customerEmail: String? = nil) {
        precondition(!customerName.isEmpty, "ChatUser.customerName is required and cannot be blank.")
        self.customerName = customerName
        self.customerId = customerId
        self.customerEmail = customerEmail
    }
}

/// SDK configuration. Only ``apiKey`` is required for production usage —
/// `baseUrl` defaults to the production NewInstance host and is rejected
/// at construction time if a release SDK build tries to point at any other
/// origin. Debug builds may override for local-server testing.
public struct LiveAndAiChatConfig: Sendable {
    /// The API key ID for this organization (e.g. `sk_live_abc123`).
    /// Because the SDK ships embedded in customer apps, the key SHOULD be
    /// the keyId-only form — `keyId:secret` exposes the secret to anyone
    /// who can decompile the app. If a `keyId:secret` form is supplied here,
    /// the SDK strips the secret half and logs a warning instead of
    /// crashing the host app.
    public let apiKey: String

    /// Backend base URL. Defaults to ``LiveAndAiChatConfig/defaultBaseUrl``.
    /// Custom values are accepted in debug builds only; release builds throw
    /// at construction time if you try to override this so merchants can't
    /// redirect SDK traffic.
    public let baseUrl: String

    public let gqlPath: String
    public let ssePath: String
    public let wsPath: String

    /// Optional transport override. When `nil`, the SDK uses whatever the
    /// server bootstrap advertises (SSE by default).
    public let transport: TransportMode?

    /// Optional initial message sent on `initCsAiChat`. Web parity.
    public let initialMessage: String?

    public init(
        apiKey: String,
        baseUrl: String = LiveAndAiChatConfig.defaultBaseUrl,
        gqlPath: String = "/service",
        ssePath: String = "/graphql/stream",
        wsPath: String = "/graphql/ws",
        transport: TransportMode? = nil,
        initialMessage: String? = nil
    ) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            throw LiveAndAiChatError(
                type: .validation,
                message: "apiKey must not be blank",
                recoverable: false
            )
        }
        if trimmedKey.contains(":") {
            // Don't crash — warn so misconfigured builds keep working while
            // developers see the issue. Matches Android `LiveAndAiChatConfig`.
            Self.log.warning("""
                apiKey contains ':' — embedding the keyId:secret form in an iOS app exposes \
                the secret to any user with access to the IPA. The SDK will use the keyId \
                portion only (chat-widget mode). Use the keyId-only form (e.g. sk_live_xxx).
                """)
        }
        guard baseUrl.hasPrefix("http://") || baseUrl.hasPrefix("https://") else {
            throw LiveAndAiChatError(
                type: .validation,
                message: "baseUrl must start with http:// or https://",
                recoverable: false
            )
        }
        if baseUrl != Self.defaultBaseUrl && !Self.isDebugBuild {
            throw LiveAndAiChatError(
                type: .validation,
                message: "baseUrl override is only allowed in debug SDK builds. " +
                    "Shipped (release) builds must use the default \(Self.defaultBaseUrl).",
                recoverable: false
            )
        }
        self.apiKey = trimmedKey
        self.baseUrl = baseUrl
        self.gqlPath = gqlPath
        self.ssePath = ssePath
        self.wsPath = wsPath
        self.transport = transport
        self.initialMessage = initialMessage
    }

    /// The value sent on `x-api-key`. If the host passed a `keyId:secret`
    /// pair we strip the secret half — never embed it in an iOS request.
    /// Stripped value matches what the backend's `validateApiKey` treats
    /// as widget-mode auth.
    var effectiveApiKey: String {
        guard let colonIdx = apiKey.firstIndex(of: ":") else { return apiKey }
        return String(apiKey[..<colonIdx]).trimmingCharacters(in: .whitespaces)
    }

    public var gqlEndpoint: URL {
        URL(string: baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + gqlPath)!
    }

    public var sseEndpoint: URL {
        URL(string: baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + ssePath)!
    }

    public var wsEndpoint: URL {
        let trimmed = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let wsBase: String
        if trimmed.hasPrefix("https://") {
            wsBase = "wss://" + trimmed.dropFirst("https://".count)
        } else if trimmed.hasPrefix("http://") {
            wsBase = "ws://" + trimmed.dropFirst("http://".count)
        } else {
            wsBase = trimmed
        }
        return URL(string: wsBase + wsPath)!
    }

    public static let defaultBaseUrl = "https://service.newinstance.cloud"

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static let log = Logger(subsystem: "cloud.newinstance.liveandaichat", category: "Config")
}
