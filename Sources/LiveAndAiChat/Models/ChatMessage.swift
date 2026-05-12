import Foundation

public enum MessageType: String, Codable, Sendable {
    case customer = "CUSTOMER"
    case agent = "AGENT"
    case ai = "AI"
    case system = "SYSTEM"
}

public enum MessageStatus: String, Codable, Sendable {
    case sent = "SENT"
    case delivered = "DELIVERED"
    case read = "READ"
    case failed = "FAILED"
}

public struct MessageSender: Codable, Equatable, Sendable {
    public let senderId: String?
    public let senderName: String?
    public let senderType: MessageType?

    public init(senderId: String? = nil, senderName: String? = nil, senderType: MessageType? = nil) {
        self.senderId = senderId
        self.senderName = senderName
        self.senderType = senderType
    }
}

public struct MessageAttachment: Codable, Equatable, Sendable {
    public let url: String
    public let name: String
    public let type: String
    public let size: Int64

    public init(url: String, name: String, type: String, size: Int64) {
        self.url = url
        self.name = name
        self.type = type
        self.size = size
    }
}

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let clientId: String?
    public let conversationId: String
    public let content: String
    public let type: MessageType
    public let status: MessageStatus
    public let seq: Int64?
    public let sender: MessageSender?
    public let attachments: [MessageAttachment]
    public let createdAt: String?
    public let readAt: String?
    /// Total number of persisted messages in this message's
    /// conversation **at the moment the server published this
    /// envelope**. Only set when the message arrived via the
    /// `csMessageReceived` subscription — `nil` for messages loaded
    /// via `getCsMessages` or echoed from mutations.
    ///
    /// Used by the SDK's gap-fill path: when an SSE message arrives
    /// and `totalMessages > store.messages.count`, the SDK silently
    /// refetches the full history so the UI stays consistent if
    /// intermediate events were missed (reconnect, slow network,
    /// app backgrounded).
    public let totalMessages: Int?

    public init(
        id: String,
        clientId: String? = nil,
        conversationId: String,
        content: String = "",
        type: MessageType,
        status: MessageStatus = .sent,
        seq: Int64? = nil,
        sender: MessageSender? = nil,
        attachments: [MessageAttachment] = [],
        createdAt: String? = nil,
        readAt: String? = nil,
        totalMessages: Int? = nil
    ) {
        self.id = id
        self.clientId = clientId
        self.conversationId = conversationId
        self.content = content
        self.type = type
        self.status = status
        self.seq = seq
        self.sender = sender
        self.attachments = attachments
        self.createdAt = createdAt
        self.readAt = readAt
        self.totalMessages = totalMessages
    }

    /// `init(from:)` is lenient: missing fields fall back to sensible
    /// defaults so reasonable schema drift (e.g. an older server omitting
    /// `readAt`) doesn't crash the deserializer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        type = try c.decode(MessageType.self, forKey: .type)
        status = try c.decodeIfPresent(MessageStatus.self, forKey: .status) ?? .sent
        seq = try c.decodeIfPresent(Int64.self, forKey: .seq)
        sender = try c.decodeIfPresent(MessageSender.self, forKey: .sender)
        attachments = try c.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        // The server's `sendCsCustomerMessage` mutation echoes `sentAt`
        // instead of `createdAt`. Prefer `createdAt` when present, fall
        // back to `sentAt`.
        if let created = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = created
        } else {
            createdAt = try c.decodeIfPresent(String.self, forKey: .sentAt)
        }
        readAt = try c.decodeIfPresent(String.self, forKey: .readAt)
        totalMessages = try c.decodeIfPresent(Int.self, forKey: .totalMessages)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(clientId, forKey: .clientId)
        try c.encode(conversationId, forKey: .conversationId)
        try c.encode(content, forKey: .content)
        try c.encode(type, forKey: .type)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encodeIfPresent(sender, forKey: .sender)
        try c.encode(attachments, forKey: .attachments)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(readAt, forKey: .readAt)
        try c.encodeIfPresent(totalMessages, forKey: .totalMessages)
    }

    enum CodingKeys: String, CodingKey {
        case id, clientId, conversationId, content, type, status, seq, sender
        case attachments, createdAt, readAt, totalMessages
        // The server's `sendCsCustomerMessage` mutation echoes the
        // message with `sentAt` instead of `createdAt`. We accept both.
        case sentAt
    }
}
