#if canImport(UIKit)
import SwiftUI
import Combine

/// Top-level SwiftUI view shipped by the SDK. Hosts can use this directly
/// (e.g. inside their own `NavigationStack`) or rely on
/// ``LiveAndAiChat/openChat()`` which presents it modally.
///
/// Behavioural parity with the Android `ChatScreen` Composable + the web
/// SDK's `ChatWidget`:
///   - Header with company name / agent name + status subtitle + close button
///   - Connection banner on offline / disconnected
///   - Reverse-anchored message list (no animated scroll on first paint)
///   - Composer with attachment chip strip, send button, FAILED-retry on bubble tap
///   - Welcome bubble surfaced from `orgConfig.settings.welcomeMessage` (no
///     hardcoded fallback — matches the web/Android decision)
public struct ChatScreen: View {

    @ObservedObject var sdk: LiveAndAiChat
    @ObservedObject var store: ChatStore
    @ObservedObject var attachmentQueue: AttachmentQueue
    let onClose: () -> Void
    let onPickFile: () -> Void

    @State private var viewerAttachment: MessageAttachment?

    public init(
        sdk: LiveAndAiChat,
        onClose: @escaping () -> Void,
        onPickFile: @escaping () -> Void = {}
    ) {
        self.sdk = sdk
        self.store = sdk._store
        self.attachmentQueue = sdk._attachmentQueue
        self.onClose = onClose
        self.onPickFile = onPickFile
    }

    public var body: some View {
        let colors = ChatColors.from(sdk.orgConfig?.appearance)
        let companyName = sdk.orgConfig?.branding.companyName ?? ""
        let title = store.conversation?.assignedAgentName
            ?? (companyName.isEmpty ? "Chat" : companyName)
        let subtitle = subtitleText
        let attachmentsAllowed = sdk.orgConfig?.settings.enableFileUpload ?? true
        let typingAllowed = sdk.orgConfig?.settings.enableTypingIndicator ?? true
        let logoUrl = sdk.orgConfig?.branding.logoUrl
        let showOnlineStatus = sdk.orgConfig?.widget.showOnlineStatus ?? true
        let canRequestHandoff = store.flowState == .botConversation && sdk.lifecycle == .ready
        let subtitleIcon: HeaderSubtitleIcon = {
            switch store.flowState {
            case .botConversation: return .bot
            case .liveChat: return .agent
            default: return .none
            }
        }()

        VStack(spacing: 0) {
            ChatHeader(
                title: title,
                subtitle: subtitle,
                subtitleIcon: subtitleIcon,
                logoUrl: logoUrl,
                showOnlineStatus: showOnlineStatus,
                isOnline: sdk.connectionState == .connected,
                showHandoffButton: canRequestHandoff,
                onRequestHandoff: { sdk.requestHandoff(reason: "user_requested") },
                onClose: onClose
            )
            .environment(\.chatColors, colors)

            switch sdk.connectionState {
            case .offline:
                ConnectionBanner(
                    text: sdk.orgConfig?.settings.offlineMessage.isEmpty == false
                        ? sdk.orgConfig!.settings.offlineMessage
                        : "You appear to be offline"
                )
                .environment(\.chatColors, colors)
            case .disconnected:
                ConnectionBanner(text: "Reconnecting…")
                    .environment(\.chatColors, colors)
            default:
                EmptyView()
            }

            ZStack {
                colors.background
                body(for: sdk.lifecycle, colors: colors, typingAllowed: typingAllowed)
            }
            .frame(maxHeight: .infinity)

            Composer(
                placeholderText: sdk.orgConfig?.settings.placeholderText.isEmpty == false
                    ? sdk.orgConfig!.settings.placeholderText
                    : "Type a message",
                pendingAttachments: attachmentQueue.items,
                attachmentsAllowed: attachmentsAllowed,
                enabled: sdk.lifecycle == .ready,
                onPickFile: onPickFile,
                onRemoveAttachment: { attachmentQueue.remove(id: $0) },
                onSend: { sdk.sendMessage($0) },
                onTyping: { typing in
                    if typing { sdk.sendTypingStart() } else { sdk.sendTypingStop() }
                }
            )
            .environment(\.chatColors, colors)
        }
        .background(colors.background.ignoresSafeArea(edges: .bottom))
        .fullScreenCover(item: $viewerAttachment) { att in
            ImageViewerView(attachment: att, onClose: { viewerAttachment = nil })
        }
    }

    @ViewBuilder
    private func body(
        for lifecycle: ChatSdkLifecycle,
        colors: ChatColors,
        typingAllowed: Bool
    ) -> some View {
        switch lifecycle {
        case .initializing, .notStarted:
            ConnectingPlaceholder(text: "Connecting to chat service…")
                .environment(\.chatColors, colors)
        case .unavailable:
            SystemNoticeBlock(
                text: "Chat is currently unavailable",
                iconName: "moon.zzz",
                actionLabel: nil,
                onAction: nil
            )
            .environment(\.chatColors, colors)
        case .failed:
            SystemNoticeBlock(
                text: "Could not start chat. Check your connection and try again.",
                iconName: "wifi.exclamationmark",
                actionLabel: "Retry",
                onAction: { sdk.initialize() }
            )
            .environment(\.chatColors, colors)
        case .ready:
            if store.messages.isEmpty {
                let welcome = sdk.orgConfig?.settings.welcomeMessage
                if let welcome, !welcome.isEmpty {
                    VStack(alignment: .leading) {
                        EmptyState(welcomeMessage: welcome)
                            .environment(\.chatColors, colors)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                } else {
                    Color.clear
                }
            } else {
                MessageList(
                    messages: store.messages,
                    agentTyping: typingAllowed && store.agentTyping,
                    onRetry: { sdk.retryMessage(messageId: $0) },
                    onImageTap: { att in viewerAttachment = att }
                )
                .environment(\.chatColors, colors)
            }
        }
    }

    private var subtitleText: String {
        switch sdk.lifecycle {
        case .initializing, .notStarted: return "Connecting to chat service…"
        case .unavailable: return "Chat unavailable"
        case .failed: return "Failed to start chat"
        case .ready: break
        }
        switch store.flowState {
        case .handoffPending: return "Waiting for an agent…"
        case .liveChat: return "Live agent"
        case .botConversation: return "AI Assistant"
        case .ended: return "Conversation ended"
        default: break
        }
        switch sdk.connectionState {
        case .connected: return "Online"
        case .connecting: return "Connecting…"
        case .disconnected: return "Reconnecting…"
        case .offline: return "Offline"
        case .idle: return ""
        }
    }
}

/// Need Identifiable conformance so `.fullScreenCover(item:)` can drive the
/// viewer presentation. Attachments are already Equatable; URL is unique
/// per attachment within a conversation so it's a fine identifier.
extension MessageAttachment: Identifiable {
    public var id: String { url }
}

// MARK: - Subviews

/// Flow-state icon shown alongside the header subtitle. `bot` for AI
/// conversations, `agent` for live-chat. Mirrors the lucide Bot /
/// Headphones icons from the web `ChatHeader.tsx`.
enum HeaderSubtitleIcon { case none, bot, agent }

struct ChatHeader: View {
    let title: String
    let subtitle: String
    let subtitleIcon: HeaderSubtitleIcon
    let logoUrl: String?
    let showOnlineStatus: Bool
    let isOnline: Bool
    let showHandoffButton: Bool
    let onRequestHandoff: () -> Void
    let onClose: () -> Void
    @Environment(\.chatColors) private var colors

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let url = logoUrl, !url.isEmpty {
                HeaderLogo(url: url)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ChatHeader.titleCase(title))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colors.headerPrimaryText)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    HStack(spacing: 4) {
                        if showOnlineStatus {
                            ZStack {
                                if isOnline {
                                    Circle()
                                        .fill(colors.onlineStatus.opacity(0.45))
                                        .frame(width: 8, height: 8)
                                        .blur(radius: 1)
                                }
                                Circle()
                                    .fill(isOnline ? colors.onlineStatus : Color.white.opacity(0.4))
                                    .frame(width: 6, height: 6)
                            }
                            .frame(width: 8, height: 8)
                        }
                        if let iconName = subtitleIconName {
                            Image(systemName: iconName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(colors.headerSecondaryText)
                        }
                        Text(ChatHeader.titleCase(subtitle))
                            .font(.system(size: 11))
                            .foregroundColor(colors.headerSecondaryText)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if showHandoffButton {
                HeaderIconButton(systemName: "headphones", color: colors.headerIcon, action: onRequestHandoff)
                    .accessibilityLabel("Talk to a live agent")
            }
            HeaderIconButton(systemName: "xmark", color: colors.closeButton, action: onClose)
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(colors.headerBackground)
    }

    private var subtitleIconName: String? {
        switch subtitleIcon {
        case .none: return nil
        case .bot: return "sparkles"
        case .agent: return "headphones"
        }
    }

    /// Title-case every word — "live agent" → "Live Agent". Acronyms
    /// already in uppercase ≤4 chars (AI, FAQ, etc.) are preserved.
    /// Matches the `titleCase` helper in the web SDK.
    static func titleCase(_ s: String) -> String {
        let words = s.split(separator: " ", omittingEmptySubsequences: false)
        let mapped: [String] = words.map { raw in
            let word = String(raw)
            if word.isEmpty { return word }
            if word == word.uppercased() && word.count <= 4 { return word }
            let first = word.prefix(1).uppercased()
            let rest = word.dropFirst().lowercased()
            return first + rest
        }
        return mapped.joined(separator: " ")
    }
}

/// 32-pt round icon button used by the header for handoff / close.
/// Subtle hover-style background via a semi-transparent shape so the
/// merchant's header tint comes through.
private struct HeaderIconButton: View {
    let systemName: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.001)))
        }
        .buttonStyle(.plain)
    }
}

/// Cached 32×32 rounded logo in the header. Falls back to a tinted
/// silhouette when the URL fails to load.
struct HeaderLogo: View {
    let url: String
    @Environment(\.chatColors) private var colors

    var body: some View {
        Group {
            if #available(iOS 15.0, *) {
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 32, height: 32)
        .background(colors.headerPrimaryText.opacity(0.15))
        .clipShape(Circle())
    }

    private var fallback: some View {
        Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.system(size: 14))
            .foregroundColor(colors.headerPrimaryText.opacity(0.7))
    }
}

/// Centered notice rendered inside the conversation area when chat is
/// unavailable or initialization failed. Mirrors the web SDK's
/// SystemNotice layout: muted glyph, message, optional inline action
/// pill.
struct SystemNoticeBlock: View {
    let text: String
    let iconName: String
    let actionLabel: String?
    let onAction: (() -> Void)?
    @Environment(\.chatColors) private var colors

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(colors.typingBg)
                    .frame(width: 56, height: 56)
                Image(systemName: iconName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(colors.textSecondary)
            }
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let label = actionLabel, let action = onAction {
                Button(action: action) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                        Text(label)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(colors.primary)
                    )
                    .foregroundColor(colors.sendButtonIcon)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Connecting to chat service…" placeholder shown while the SDK is
/// bootstrapping the session. Composer is disabled at the call site;
/// this just communicates *why*.
struct ConnectingPlaceholder: View {
    let text: String
    @Environment(\.chatColors) private var colors

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: colors.primary))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConnectionBanner: View {
    let text: String
    @Environment(\.chatColors) private var colors

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(colors.typingBg)
    }
}

struct EmptyState: View {
    let welcomeMessage: String
    @Environment(\.chatColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AI")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(colors.textSecondary)
                .padding(.leading, 4)
            HStack {
                Text(welcomeMessage)
                    .foregroundColor(colors.receivedText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedCorners(tl: 16, tr: 16, bl: 4, br: 16)
                            .fill(colors.receivedBubble)
                    )
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif
