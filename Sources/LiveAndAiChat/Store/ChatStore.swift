import Foundation
import Combine

/// In-memory state store for an active chat session. Mirrors the Android
/// `ChatStore.kt` field-for-field — published properties replace Kotlin
/// `StateFlow`. UI layers (SwiftUI views in Phase 2.B) and the SDK
/// callbacks both observe this through Combine.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var flowState: FlowState = .idle
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var conversation: Conversation?
    @Published private(set) var assignment: Assignment?
    @Published private(set) var agentTyping: Bool = false
    @Published private(set) var unreadCount: Int = 0
    @Published private(set) var widgetOpen: Bool = false
    /// Highest `seq` seen so far. Drives gap-fill on reconnect, mirroring
    /// the web SDK's `highestSeq` and Android `ChatStore.highestSeq`.
    @Published private(set) var highestSeq: Int64 = 0

    func setConversation(_ conversation: Conversation?, assignment: Assignment?) {
        self.conversation = conversation
        self.assignment = assignment
        self.flowState = Self.derive(conversation: conversation, assignment: assignment)
    }

    func setAssignment(_ assignment: Assignment?) {
        self.assignment = assignment
        self.flowState = Self.derive(conversation: conversation, assignment: assignment)
    }

    func setAgentTyping(_ value: Bool) {
        self.agentTyping = value
    }

    func openWidget() {
        widgetOpen = true
        unreadCount = 0
    }

    func closeWidget() {
        widgetOpen = false
    }

    /// Idempotent insert/merge.
    /// - If a message with the same `id` exists → replace.
    /// - Else if a message with the same `clientId` (and clientId not blank) exists → replace.
    /// - Else append.
    /// After insert/replace, re-sort by (`seq` ?? `Int64.max`).
    func mergeMessage(_ message: ChatMessage) {
        let before = messages.count
        var list = messages
        var action: String
        if let idx = list.firstIndex(where: { $0.id == message.id }) {
            list[idx] = message
            action = "replace-by-id"
        } else if let cid = message.clientId, !cid.isEmpty,
                  let idx = list.firstIndex(where: { $0.clientId == cid }) {
            list[idx] = message
            action = "replace-by-clientId"
        } else {
            list.append(message)
            action = "append"
        }
        list.sort { ($0.seq ?? .max) < ($1.seq ?? .max) }
        messages = list

        if let seq = message.seq { highestSeq = max(highestSeq, seq) }

        let isInbound = message.type == .agent || message.type == .ai
        if isInbound && !widgetOpen {
            unreadCount += 1
        }
        SseLog.debug("store.mergeMessage \(action) id=\(message.id.suffix(8)) type=\(message.type.rawValue) seq=\(message.seq ?? -1) count: \(before)→\(messages.count)")
    }

    func setInitialMessages(_ messages: [ChatMessage]) {
        let sorted = messages.sorted { ($0.seq ?? .max) < ($1.seq ?? .max) }
        self.messages = sorted
        let maxSeq = messages.compactMap { $0.seq }.max() ?? 0
        highestSeq = max(highestSeq, maxSeq)
    }

    /// Replaces a message in-place if it exists. Used for status
    /// transitions (e.g. `.sent` → `.failed`) without re-running the
    /// merge dedup path.
    func updateMessage(messageId: String, transform: (ChatMessage) -> ChatMessage) {
        messages = messages.map { $0.id == messageId ? transform($0) : $0 }
    }

    func removeMessage(_ messageId: String) {
        messages.removeAll { $0.id == messageId }
    }

    func reset() {
        flowState = .idle
        messages = []
        conversation = nil
        assignment = nil
        agentTyping = false
        unreadCount = 0
        widgetOpen = false
        highestSeq = 0
    }

    /// Pure derivation, exposed for unit tests.
    static func derive(conversation: Conversation?, assignment: Assignment?) -> FlowState {
        guard let c = conversation else { return .idle }
        if c.status == .closed || c.status == .resolved { return .ended }
        if c.status == .active { return .liveChat }
        if c.assignedAgentId != nil { return .liveChat }
        if assignment?.status == .accepted || assignment?.status == .assigned { return .liveChat }
        if c.status == .waiting { return .handoffPending }
        if assignment?.status == .pending { return .handoffPending }
        if c.status == .botActive { return .botConversation }
        return .botConversation
    }
}
