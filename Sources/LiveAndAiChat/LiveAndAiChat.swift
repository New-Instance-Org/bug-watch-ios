import Foundation
import Combine
import OSLog

/// Public entry point for the LiveAndAiChat iOS SDK. Mirrors the Android
/// `LiveAndAiChat` and web `WidgetInstance` API surfaces — `initialize`,
/// `openChat`, `sendMessage`, `retryMessage`, `requestHandoff`, etc.
///
/// Hosts can subscribe to state two ways:
///   - **Combine / SwiftUI**: the `@Published` properties on this
///     `ObservableObject` (preferred).
///   - **Callback-style**: implement ``LiveAndAiChatDelegate`` and pass it
///     to ``addDelegate(_:)``.
@MainActor
public final class LiveAndAiChat: ObservableObject {

    // MARK: - Construction

    /// Builder for the SDK instance. Mirrors the Kotlin builder pattern.
    public final class Builder {
        private var config: LiveAndAiChatConfig?
        private var user: ChatUser?

        public init() {}

        public func config(_ config: LiveAndAiChatConfig) -> Builder { self.config = config; return self }
        public func user(_ user: ChatUser) -> Builder { self.user = user; return self }

        @MainActor
        public func build() throws -> LiveAndAiChat {
            guard let cfg = config else {
                throw LiveAndAiChatError(type: .validation, message: "config(_:) is required", recoverable: false)
            }
            return LiveAndAiChat(config: cfg, user: user)
        }
    }

    private let config: LiveAndAiChatConfig
    private let gql: GqlClient
    private let session: SessionManager
    private let uploader: FileUploader
    /// Internal — also exposed as ``_store`` so the SwiftUI views in this
    /// module can observe the same `ChatStore` instance the SDK uses.
    let store: ChatStore
    /// Internal — surfaced to the SwiftUI views (and the public
    /// ``attachmentQueue`` property) so the composer chip strip and the
    /// SDK share one source of truth.
    let attachmentQueue: AttachmentQueue
    private let networkMonitor: NetworkMonitor
    private let log = Logger(subsystem: "com.cinstance.liveandaichat", category: "SDK")

    private var user: ChatUser?
    private var bootstrap: LiveChatBootstrap?
    private var subscriptionClient: (any SubscriptionClient)?
    private var connectionSubscription: AnyCancellable?
    private var subscriptionCancellables: Set<AnyCancellable> = []
    private var networkSubscription: AnyCancellable?
    private var destroyed = false
    private var opened = false
    private var initTask: Task<Void, Never>?

    // MARK: - Internal accessors for the bundled SwiftUI views

    /// Module-internal handle used by ``ChatScreen``. Tests need access
    /// too, hence not `private`. Hosts should bind to the read-through
    /// `@Published` properties on `LiveAndAiChat` instead — those keep
    /// this stable across SDK versions.
    var _store: ChatStore { store }
    var _attachmentQueue: AttachmentQueue { attachmentQueue }

    // MARK: - Public state (Combine)

    /// The latest config returned from `getCsConfig`. Hosts use this to
    /// theme their UI and to read merchant settings (welcome message,
    /// placeholder, feature toggles). `nil` until the first fetch
    /// resolves.
    @Published public private(set) var orgConfig: OrgChatConfig?

    /// Aggregate connection state. Hosts bind a status pill to this.
    @Published public private(set) var connectionState: ConnectionState = .idle

    /// Coarse SDK lifecycle. Drives the host's open-chat button.
    @Published public private(set) var lifecycle: ChatSdkLifecycle = .notStarted

    /// Re-exports the store's state so SwiftUI hosts can observe a single
    /// `ObservableObject`. Each property is a one-line read-through.
    public var flowState: FlowState { store.flowState }
    public var messages: [ChatMessage] { store.messages }
    public var conversation: Conversation? { store.conversation }
    public var assignment: Assignment? { store.assignment }
    public var agentTyping: Bool { store.agentTyping }
    public var unreadCount: Int { store.unreadCount }
    public var widgetOpen: Bool { store.widgetOpen }

    // MARK: - Delegate

    private let delegates = NSHashTable<AnyObject>.weakObjects()

    public func addDelegate(_ delegate: any LiveAndAiChatDelegate) {
        delegates.add(delegate as AnyObject)
    }

    public func removeDelegate(_ delegate: any LiveAndAiChatDelegate) {
        delegates.remove(delegate as AnyObject)
    }

    private func forEachDelegate(_ block: (any LiveAndAiChatDelegate) -> Void) {
        for case let d as any LiveAndAiChatDelegate in delegates.allObjects { block(d) }
    }

    private func emitMessage(_ message: ChatMessage) { forEachDelegate { $0.didReceiveMessage(message) } }
    private func emitSent(_ message: ChatMessage) { forEachDelegate { $0.didSendMessage(message) } }
    private func emitTyping(_ value: Bool) { forEachDelegate { $0.agentTypingDidChange(value) } }
    private func emitConnection(_ state: ConnectionState) { forEachDelegate { $0.connectionStateDidChange(state) } }
    private func emitError(_ error: LiveAndAiChatError) { forEachDelegate { $0.didEncounterError(error) } }

    // MARK: - Init

    private init(config: LiveAndAiChatConfig, user: ChatUser?) {
        self.config = config
        self.user = user
        self.gql = GqlClient(endpoint: config.gqlEndpoint, apiKey: config.effectiveApiKey)
        self.session = SessionManager()
        self.store = ChatStore()
        self.attachmentQueue = AttachmentQueue()
        self.uploader = FileUploader(gql: GqlClient(endpoint: config.gqlEndpoint, apiKey: config.effectiveApiKey))
        self.networkMonitor = NetworkMonitor()

        // Track underlying store changes so this ObservableObject
        // republishes when its read-through properties move.
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptionCancellables)
        attachmentQueue.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptionCancellables)

        // Tell the host when the system network drops/restores.
        networkMonitor.start()
        networkSubscription = networkMonitor.$isOnline.sink { [weak self] online in
            guard let self else { return }
            if !online {
                self.connectionState = .offline
                self.emitConnection(.offline)
            }
        }

        Self.currentInstance = self
    }

    deinit {
        // We can't call @MainActor methods from deinit; rely on host
        // calling destroy() explicitly. As a defensive measure, stop the
        // network monitor (safe from any thread).
        networkMonitor.stop()
    }

    // MARK: - Public API

    public func setUser(_ user: ChatUser) {
        precondition(!destroyed, "SDK has been destroyed")
        self.user = user
        session.customerName = user.customerName
        session.customerEmail = user.customerEmail
        session.customerId = user.customerId
    }

    /// Kick off init in the background so a subsequent `openChat()` is
    /// near-instant. Safe to call repeatedly; concurrent calls share the
    /// same in-flight task.
    public func initialize() {
        precondition(!destroyed, "SDK has been destroyed")
        if lifecycle == .ready || lifecycle == .initializing { return }
        lifecycle = .initializing
        initTask = Task { [weak self] in
            await self?.runInit()
        }
    }

    /// Open the chat — equivalent to `WidgetInstance.open()` on the web.
    /// Idempotent: calling twice while already open is a no-op other than
    /// marking the widget as in-foreground.
    public func openChat() {
        precondition(!destroyed, "SDK has been destroyed")
        store.openWidget()
        if opened { return }
        opened = true
        if lifecycle != .ready && lifecycle != .initializing {
            initialize()
        }
    }

    public func closeChat() {
        store.closeWidget()
    }

    /// Send a customer text message. Optimistic insert, then awaits the
    /// server echo. On failure the optimistic message transitions to
    /// `.failed` so the UI can surface a retry affordance.
    ///
    /// Attachments: any items currently in the ``AttachmentQueue`` whose
    /// status is `.uploaded` are drained and attached to this outgoing
    /// message — matching the web/Android behaviour where the composer's
    /// send button consumes the queue.
    public func sendMessage(_ content: String) {
        precondition(!destroyed, "SDK has been destroyed")
        guard let convId = session.conversationId else {
            emitError(LiveAndAiChatError(type: .validation, message: "No active conversation", recoverable: true))
            return
        }
        let drained = attachmentQueue.drainUploaded()
        let clientId = "c_\(UUID().uuidString)"
        let optimisticId = "temp_\(clientId)"
        let optimistic = ChatMessage(
            id: optimisticId,
            clientId: clientId,
            conversationId: convId,
            content: content,
            type: .customer,
            status: .sent,
            attachments: drained
        )
        store.mergeMessage(optimistic)
        Task { [weak self] in
            await self?.runSendMutation(
                convId: convId,
                content: content,
                attachments: drained,
                clientId: clientId,
                optimisticId: optimisticId
            )
        }
    }

    /// Queue a file for upload and (if successful) inclusion in the next
    /// outgoing message. Mirrors Android's `attach()` API.
    public func attachFile(data: Data, name: String, mimeType: String, previewUri: String? = nil) {
        precondition(!destroyed, "SDK has been destroyed")
        let item = QueuedAttachment(
            name: name,
            mimeType: mimeType,
            size: Int64(data.count),
            status: .uploading,
            progress: 0,
            previewUri: previewUri
        )
        attachmentQueue.add(item)
        Task { [weak self] in
            guard let self else { return }
            do {
                let publicUrl = try await self.uploader.upload(
                    data: data,
                    name: name,
                    mimeType: mimeType,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.attachmentQueue.update(id: item.id) { existing in
                                var copy = existing
                                copy.progress = progress
                                copy.status = .uploading
                                return copy
                            }
                        }
                    }
                )
                await MainActor.run {
                    self.attachmentQueue.update(id: item.id) { existing in
                        var copy = existing
                        copy.status = .uploaded
                        copy.progress = 1.0
                        copy.publicUrl = publicUrl
                        return copy
                    }
                }
            } catch let e as LiveAndAiChatError {
                await MainActor.run {
                    self.attachmentQueue.update(id: item.id) { existing in
                        var copy = existing
                        copy.status = .failed
                        copy.errorReason = e.message
                        return copy
                    }
                    self.emitError(e)
                }
            } catch {
                await MainActor.run {
                    self.attachmentQueue.update(id: item.id) { existing in
                        var copy = existing
                        copy.status = .failed
                        copy.errorReason = error.localizedDescription
                        return copy
                    }
                }
            }
        }
    }

    /// Remove a queued (or failed) attachment without sending it. Safe to
    /// call mid-upload — the upload still completes but the resulting
    /// public URL is dropped.
    public func removeAttachment(id: String) {
        attachmentQueue.remove(id: id)
    }

    /// Retry a previously-failed customer message. Re-uses the same
    /// `clientId` so the server dedupes on idempotency.
    public func retryMessage(messageId: String) {
        precondition(!destroyed, "SDK has been destroyed")
        guard let msg = store.messages.first(where: { $0.id == messageId }),
              msg.type == .customer,
              msg.status == .failed
        else { return }
        let cid = msg.clientId ?? "c_\(UUID().uuidString)"
        store.updateMessage(messageId: messageId) { existing in
            ChatMessage(
                id: existing.id,
                clientId: existing.clientId,
                conversationId: existing.conversationId,
                content: existing.content,
                type: existing.type,
                status: .sent,
                seq: existing.seq,
                sender: existing.sender,
                attachments: existing.attachments,
                createdAt: existing.createdAt,
                readAt: existing.readAt
            )
        }
        Task { [weak self] in
            await self?.runSendMutation(
                convId: msg.conversationId,
                content: msg.content,
                attachments: msg.attachments,
                clientId: cid,
                optimisticId: msg.id
            )
        }
    }

    /// Explicit live-agent handoff request.
    public func requestHandoff(reason: String? = nil) {
        precondition(!destroyed, "SDK has been destroyed")
        guard let convId = session.conversationId else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                var vars: [String: Any] = ["conversationId": convId]
                if let r = reason, !r.isEmpty { vars["reason"] = r }
                let data = try await self.gql.execute(query: Operations.requestHandoff, variables: vars)
                guard let payload = data["requestCsHandoff"] as? [String: Any],
                      let assignmentDict = payload["assignment"] as? [String: Any],
                      let assignment = try? GqlClient.decode(Assignment.self, from: assignmentDict)
                else { return }
                await MainActor.run {
                    self.store.setAssignment(assignment)
                    self.session.assignmentId = assignment.id
                }
            } catch let e as LiveAndAiChatError {
                await MainActor.run { self.emitError(e) }
            } catch { /* ignore */ }
        }
    }

    public func sendTypingStart() {
        guard let convId = session.conversationId else { return }
        Task { [weak self] in
            guard let self else { return }
            var vars: [String: Any] = ["conversationId": convId]
            if let name = self.user?.customerName { vars["userName"] = name }
            _ = try? await self.gql.execute(query: Operations.sendTypingStart, variables: vars)
        }
    }

    public func sendTypingStop() {
        guard let convId = session.conversationId else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.gql.execute(query: Operations.sendTypingStop, variables: ["conversationId": convId])
        }
    }

    public func destroy() {
        if destroyed { return }
        destroyed = true
        opened = false
        initTask?.cancel()
        subscriptionClient?.stop()
        subscriptionClient = nil
        connectionSubscription = nil
        subscriptionCancellables.removeAll()
        networkMonitor.stop()
        store.reset()
        if Self.currentInstance === self { Self.currentInstance = nil }
    }

    // MARK: - Init pipeline

    private func runInit() async {
        do {
            await fetchBootstrap()
            let conversationId = try await ensureSession()
            connectTransport()
            subscribeAll(conversationId: conversationId)
            await fetchOrgConfig()
            lifecycle = .ready
        } catch let e as LiveAndAiChatError {
            emitError(e)
            lifecycle = .failed
        } catch {
            emitError(LiveAndAiChatError(type: .system, message: error.localizedDescription, recoverable: true, underlying: error))
            lifecycle = .failed
        }
    }

    private func fetchBootstrap() async {
        guard let data = try? await gql.execute(query: Operations.getLiveChatBootstrap),
              let node = data["getLiveChatBootstrap"]
        else { return }
        bootstrap = try? GqlClient.decode(LiveChatBootstrap.self, from: node)
    }

    private func fetchOrgConfig() async {
        guard let data = try? await gql.execute(query: Operations.getCsConfig),
              let node = data["getCsConfig"],
              let cfg = try? GqlClient.decode(OrgChatConfig.self, from: node)
        else { return }
        orgConfig = cfg
    }

    private func ensureSession() async throws -> String {
        // User mismatch detection: wipe stored session when the host
        // sets a different identity from what's persisted.
        if let u = user {
            let savedEmail = session.customerEmail ?? ""
            let savedId = session.customerId ?? ""
            let emailChanged = (u.customerEmail ?? "") != savedEmail
            let idChanged = (u.customerId ?? "") != savedId
            if (u.customerEmail != nil || u.customerId != nil) && (emailChanged || idChanged) {
                session.clear()
            }
            session.customerName = u.customerName
            session.customerEmail = u.customerEmail
            session.customerId = u.customerId
        }

        if let savedConv = session.conversationId {
            // Hydrate existing conversation, then load message history.
            if let data = try? await gql.execute(
                query: Operations.getConversationState,
                variables: ["conversationId": savedConv]
            ), let state = data["getCsConversationState"] as? [String: Any] {
                let conv = (state["conversation"] as? [String: Any])
                    .flatMap { try? GqlClient.decode(Conversation.self, from: $0) }
                let assign = (state["assignment"] as? [String: Any])
                    .flatMap { try? GqlClient.decode(Assignment.self, from: $0) }
                await MainActor.run { self.store.setConversation(conv, assignment: assign) }
            }
            await loadInitialHistory(conversationId: savedConv)
            return savedConv
        }

        // Fresh init.
        let u = user ?? ChatUser(customerName: "Guest")
        var input: [String: Any] = ["customerName": u.customerName]
        if let v = u.customerEmail { input["customerEmail"] = v }
        if let v = u.customerId { input["customerId"] = v }
        if let v = config.initialMessage { input["initialMessage"] = v }
        let data = try await gql.execute(query: Operations.initChat, variables: ["input": input])
        guard let result = data["initCsAiChat"] as? [String: Any],
              let convId = result["conversationId"] as? String, !convId.isEmpty
        else {
            throw LiveAndAiChatError(type: .system, message: "Init returned no conversationId", recoverable: false)
        }
        session.conversationId = convId
        let conv = (result["conversation"] as? [String: Any])
            .flatMap { try? GqlClient.decode(Conversation.self, from: $0) }
        let assign = (result["assignment"] as? [String: Any])
            .flatMap { try? GqlClient.decode(Assignment.self, from: $0) }
        if let a = assign { session.assignmentId = a.id }
        await MainActor.run { self.store.setConversation(conv, assignment: assign) }
        if let msgs = result["messages"] as? [[String: Any]] {
            let decoded = msgs.compactMap { try? GqlClient.decode(ChatMessage.self, from: $0) }
            await MainActor.run { self.store.setInitialMessages(decoded) }
        }
        return convId
    }

    private func loadInitialHistory(conversationId: String) async {
        guard let data = try? await gql.execute(
            query: Operations.getMessages,
            variables: ["conversationId": conversationId, "limit": 200]
        ), let arr = data["getCsMessages"] as? [[String: Any]] else { return }
        let decoded = arr.compactMap { try? GqlClient.decode(ChatMessage.self, from: $0) }
        if !decoded.isEmpty {
            await MainActor.run { self.store.setInitialMessages(decoded) }
        }
    }

    // MARK: - Gap-fill (silent history resync)

    /// Set of conversation IDs with an in-flight silent gap-fill. Stops
    /// us from firing N concurrent fetches when a burst of subscription
    /// events all carry `totalMessages` that exceed the local cache.
    private var inFlightGapFill: Set<String> = []
    /// Debounce timer per conversation so a rapid sequence of events
    /// (typical when the app un-backgrounds and replays a queue)
    /// triggers a single fetch ~250ms after the last event.
    private var gapFillDebounceTasks: [String: Task<Void, Never>] = [:]

    /// Compare the `totalMessages` field carried by a `csMessageReceived`
    /// event against the local store. If the server has more than we do,
    /// schedule a silent merge-fetch — no loading state, no UI flicker.
    /// Idempotent and debounced.
    private func scheduleGapFillIfBehind(conversationId: String, remoteTotal: Int) {
        let localCount = store.messages.count
        guard remoteTotal > localCount else { return }
        SseLog.debug("gap-fill scheduled: local=\(localCount) remote=\(remoteTotal) conv=\(conversationId.suffix(8))")

        gapFillDebounceTasks[conversationId]?.cancel()
        gapFillDebounceTasks[conversationId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250 * 1_000_000)
            if Task.isCancelled { return }
            await self?.runGapFill(conversationId: conversationId)
        }
    }

    /// One-shot silent history fetch that merges into the existing
    /// store instead of replacing it. Preserves optimistic
    /// (clientId-only, no server id yet) entries — `mergeMessage` is
    /// idempotent on `id` and falls back to `clientId`.
    private func runGapFill(conversationId: String) async {
        if inFlightGapFill.contains(conversationId) {
            SseLog.debug("gap-fill skip — already in flight for conv=\(conversationId.suffix(8))")
            return
        }
        inFlightGapFill.insert(conversationId)
        defer { inFlightGapFill.remove(conversationId) }

        SseLog.debug("gap-fill fetching getCsMessages for conv=\(conversationId.suffix(8))")
        guard let data = try? await gql.execute(
            query: Operations.getMessages,
            variables: ["conversationId": conversationId, "limit": 500]
        ), let arr = data["getCsMessages"] as? [[String: Any]] else {
            SseLog.warn("gap-fill fetch returned no data for conv=\(conversationId.suffix(8))")
            return
        }
        let decoded = arr.compactMap { try? GqlClient.decode(ChatMessage.self, from: $0) }
        SseLog.debug("gap-fill merging \(decoded.count) message(s) into store (was \(store.messages.count))")
        await MainActor.run {
            for msg in decoded { self.store.mergeMessage(msg) }
        }
        SseLog.debug("gap-fill done. store now has \(store.messages.count) message(s)")
    }

    private func connectTransport() {
        if subscriptionClient != nil { return }
        let mode = config.transport ?? bootstrap?.transport ?? .sse
        let policy = bootstrap?.reconnect ?? ReconnectPolicy()
        let timeout = bootstrap?.heartbeatTimeoutMs ?? 30_000

        let client: any SubscriptionClient
        switch mode {
        case .ws:
            SseLog.debug("connectTransport using WebSocket → \(config.wsEndpoint.absoluteString)")
            client = WsSubscriptionClient(
                endpoint: config.wsEndpoint,
                apiKey: config.effectiveApiKey,
                reconnect: policy,
                heartbeatTimeoutMs: timeout
            )
        case .sse:
            SseLog.debug("connectTransport using SSE → \(config.sseEndpoint.absoluteString)")
            client = SseSubscriptionClient(
                endpoint: config.sseEndpoint,
                apiKey: config.effectiveApiKey,
                reconnect: policy,
                heartbeatTimeoutMs: timeout
            )
        }
        subscriptionClient = client
        connectionSubscription = client.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.emitConnection(state)
            }
        client.start()
    }

    private func subscribeAll(conversationId: String) {
        guard let client = subscriptionClient else { return }
        SseLog.debug("subscribeAll convId=\(conversationId.suffix(8))")
        subscriptionCancellables.removeAll()

        client.subscribe(SubscriptionRequest(
            query: Operations.subMessageReceived,
            variables: ["conversationId": conversationId]
        ))
        .receive(on: DispatchQueue.main)
        .sink { [weak self] data in
            guard let self else { return }
            SseLog.debug("→ sub csMessageReceived sink fired, keys=\(Array(data.keys))")
            guard let node = data["csMessageReceived"] as? [String: Any] else {
                SseLog.warn("→ sub csMessageReceived: missing 'csMessageReceived' key")
                return
            }
            guard let msg = try? GqlClient.decode(ChatMessage.self, from: node) else {
                SseLog.warn("→ sub csMessageReceived: decode failed for node=\(node)")
                return
            }
            SseLog.debug("→ sub csMessageReceived decoded id=\(msg.id.suffix(8)) type=\(msg.type.rawValue) total=\(msg.totalMessages.map(String.init) ?? "?") content=\"\(msg.content.prefix(60))\"")
            self.store.mergeMessage(msg)
            SseLog.debug("→ store.mergeMessage done, messages.count=\(self.store.messages.count)")
            self.emitMessage(msg)
            // Gap-fill: if the server says the conversation has more
            // messages than we hold locally, the SSE stream likely
            // skipped events while the app was backgrounded / network
            // was flaky. Silently refetch — debounced & idempotent.
            if let total = msg.totalMessages {
                self.scheduleGapFillIfBehind(
                    conversationId: msg.conversationId,
                    remoteTotal: total
                )
            }
            let inbound = msg.type == .agent || msg.type == .ai
            let soundsOn = self.orgConfig?.widget.enableSounds ?? true
            if inbound && soundsOn {
                NotificationTone.shared.play()
            }
        }
        .store(in: &subscriptionCancellables)

        client.subscribe(SubscriptionRequest(
            query: Operations.subTypingIndicator,
            variables: ["conversationId": conversationId]
        ))
        .receive(on: DispatchQueue.main)
        .sink { [weak self] data in
            guard let self else { return }
            SseLog.debug("→ sub csTypingIndicator sink fired, keys=\(Array(data.keys))")
            guard let ind = data["csTypingIndicator"] as? [String: Any] else { return }
            let isTyping = (ind["isTyping"] as? Bool) ?? false
            let userType = ind["userType"] as? String
            SseLog.debug("→ typing isTyping=\(isTyping) userType=\(userType ?? "?")")
            if userType != "customer" {
                self.store.setAgentTyping(isTyping)
                self.emitTyping(isTyping)
            }
        }
        .store(in: &subscriptionCancellables)

        client.subscribe(SubscriptionRequest(
            query: Operations.subConversationUpdated,
            variables: ["conversationId": conversationId]
        ))
        .receive(on: DispatchQueue.main)
        .sink { [weak self] data in
            guard let self else { return }
            SseLog.debug("→ sub csConversationUpdated sink fired")
            guard let node = data["csConversationUpdated"] as? [String: Any],
                  let conv = try? GqlClient.decode(Conversation.self, from: node)
            else { return }
            self.store.setConversation(conv, assignment: self.store.assignment)
        }
        .store(in: &subscriptionCancellables)

        client.subscribe(SubscriptionRequest(
            query: Operations.subAssignmentUpdated,
            variables: ["conversationId": conversationId]
        ))
        .receive(on: DispatchQueue.main)
        .sink { [weak self] data in
            guard let self else { return }
            SseLog.debug("→ sub csAssignmentUpdated sink fired")
            guard let node = data["csAssignmentUpdated"] as? [String: Any],
                  let a = try? GqlClient.decode(Assignment.self, from: node)
            else { return }
            self.store.setAssignment(a)
            self.session.assignmentId = a.id
        }
        .store(in: &subscriptionCancellables)

        // Heartbeat — its presence is enough; transport tracks lastEventAt.
        client.subscribe(SubscriptionRequest(query: Operations.subHeartbeat))
            .sink { _ in /* no-op */ }
            .store(in: &subscriptionCancellables)
    }

    private func runSendMutation(
        convId: String,
        content: String,
        attachments: [MessageAttachment] = [],
        clientId: String,
        optimisticId: String
    ) async {
        do {
            var vars: [String: Any] = [
                "conversationId": convId,
                "content": content,
                "clientId": clientId,
            ]
            if !attachments.isEmpty {
                vars["attachments"] = attachments.map {
                    [
                        "url": $0.url,
                        "name": $0.name,
                        "type": $0.type,
                        "size": $0.size,
                    ] as [String: Any]
                }
            }
            let data = try await gql.execute(query: Operations.sendMessage, variables: vars)
            guard let payload = data["sendCsCustomerMessage"] as? [String: Any] else { return }
            if let echo = payload["customerMessage"] as? [String: Any],
               let msg = try? GqlClient.decode(ChatMessage.self, from: echo) {
                await MainActor.run {
                    self.store.mergeMessage(msg)
                    self.emitSent(msg)
                }
            }
            if let aiNode = payload["aiResponse"] as? [String: Any],
               let ai = try? GqlClient.decode(ChatMessage.self, from: aiNode) {
                await MainActor.run {
                    self.store.mergeMessage(ai)
                    self.emitMessage(ai)
                }
            }
        } catch let e as LiveAndAiChatError {
            await MainActor.run {
                self.store.updateMessage(messageId: optimisticId) { msg in
                    ChatMessage(
                        id: msg.id,
                        clientId: msg.clientId,
                        conversationId: msg.conversationId,
                        content: msg.content,
                        type: msg.type,
                        status: .failed,
                        seq: msg.seq,
                        sender: msg.sender,
                        attachments: msg.attachments,
                        createdAt: msg.createdAt,
                        readAt: msg.readAt
                    )
                }
                self.emitError(e)
            }
        } catch {
            let e = LiveAndAiChatError(type: .system, message: error.localizedDescription, recoverable: true, underlying: error)
            await MainActor.run {
                self.store.updateMessage(messageId: optimisticId) { msg in
                    ChatMessage(
                        id: msg.id, clientId: msg.clientId, conversationId: msg.conversationId,
                        content: msg.content, type: msg.type, status: .failed, seq: msg.seq,
                        sender: msg.sender, attachments: msg.attachments,
                        createdAt: msg.createdAt, readAt: msg.readAt
                    )
                }
                self.emitError(e)
            }
        }
    }

    // MARK: - Instance registry (matches Android `LiveAndAiChat.current`)

    @MainActor private static weak var currentInstance: LiveAndAiChat?

    /// The most recently-registered active SDK instance. The eventual
    /// SwiftUI `ChatView` (Phase 2.B) will look this up so hosts can use
    /// the same `sdk.openChat()` pattern as on Android.
    @MainActor public static func current() -> LiveAndAiChat? { currentInstance }

    public static let version = "0.1.0"
}

/// Callback-style delegate alternative to Combine subscriptions. Optional
/// for hosts that prefer not to use Combine / SwiftUI bindings.
public protocol LiveAndAiChatDelegate: AnyObject {
    func didReceiveMessage(_ message: ChatMessage)
    func didSendMessage(_ message: ChatMessage)
    func agentTypingDidChange(_ isTyping: Bool)
    func connectionStateDidChange(_ state: ConnectionState)
    func didEncounterError(_ error: LiveAndAiChatError)
}

// Default no-ops so adopters only implement what they care about.
public extension LiveAndAiChatDelegate {
    func didReceiveMessage(_ message: ChatMessage) {}
    func didSendMessage(_ message: ChatMessage) {}
    func agentTypingDidChange(_ isTyping: Bool) {}
    func connectionStateDidChange(_ state: ConnectionState) {}
    func didEncounterError(_ error: LiveAndAiChatError) {}
}
