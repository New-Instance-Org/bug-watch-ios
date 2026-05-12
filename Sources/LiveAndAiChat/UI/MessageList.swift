#if canImport(UIKit)
import SwiftUI

/// Reverse-anchored chat list. Mirrors the Android `MessageList`
/// composable: render the reversed message array inside a `ScrollView`
/// rotated 180°. Index 0 (newest message) sits at the visual bottom so
/// the chat opens at the latest message with no animated scroll.
///
/// Auto-scroll behaviour:
///   - On first paint: anchored at bottom by construction.
///   - On new message while the user is anchored at bottom: explicitly
///     scroll to the latest id (covers cases where the new bubble's
///     final height isn't known until its image loads).
///   - On image-load (`onImageLoaded` callback fired from
///     `MessageBubble`): re-anchor.
///   - When the user is intentionally scrolled up: show a pill with the
///     unseen-message count; tap to jump back.
struct MessageList: View {

    let messages: [ChatMessage]
    let agentTyping: Bool
    let onRetry: (String) -> Void
    let onImageTap: (MessageAttachment) -> Void
    @Environment(\.chatColors) private var colors

    @State private var seenIds: Set<String> = []
    @State private var initialised = false
    @State private var userScrolledAway = false
    @State private var imageLoadTick = 0

    var body: some View {
        let items = MessageList.buildItems(from: messages)
        let unseen = newMessageIds

        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        // Anchor marker for the visual bottom (newest).
                        // Used to detect when the user is "at bottom" via
                        // PreferenceKey.
                        Color.clear
                            .frame(height: 1)
                            .id("__lac_bottom_anchor__")
                            .rotationEffect(.degrees(180))
                            .scaleEffect(x: -1, y: 1, anchor: .center)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: BottomVisibilityKey.self,
                                        value: BottomVisibility(
                                            frame: geo.frame(in: .named("lacScroll"))
                                        )
                                    )
                                }
                            )
                        if agentTyping {
                            TypingIndicator()
                                .id("typing")
                                .rotationEffect(.degrees(180))
                                .scaleEffect(x: -1, y: 1, anchor: .center)
                        }
                        ForEach(items) { item in
                            row(for: item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .coordinateSpace(name: "lacScroll")
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollContainerHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
                .rotationEffect(.degrees(180))
                .scaleEffect(x: -1, y: 1, anchor: .center)
                .onAppear {
                    if !initialised && !messages.isEmpty {
                        seenIds = Set(messages.map { $0.id })
                        initialised = true
                    }
                }
                .onChange(of: messages.last?.id) { newId in
                    guard initialised, let id = newId else { return }
                    if seenIds.contains(id) { return }
                    if !userScrolledAway {
                        seenIds.insert(id)
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .onChange(of: imageLoadTick) { _ in
                    guard let id = messages.last?.id, !userScrolledAway else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
                .onPreferenceChange(BottomVisibilityKey.self) { value in
                    updateScrollIntent(bottom: value)
                }
                .onPreferenceChange(ScrollContainerHeightKey.self) { h in
                    containerHeight = h
                }
            }
            if userScrolledAway && !unseen.isEmpty {
                ScrollToBottomPill(count: unseen.count) {
                    seenIds.formUnion(unseen)
                    userScrolledAway = false
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var newMessageIds: [String] {
        guard initialised else { return [] }
        return messages.compactMap { seenIds.contains($0.id) ? nil : $0.id }
    }

    @State private var containerHeight: CGFloat = 0

    private func updateScrollIntent(bottom: BottomVisibility) {
        guard containerHeight > 0 else { return }
        // The anchor sits at the visual bottom (post-rotation it's the top
        // edge of the reversed scroll content). Its frame.minY in scroll
        // coords tells us how far past the visible window the latest
        // message has been pushed by user dragging up.
        let offsetFromBottom = bottom.frame.minY
        let threshold: CGFloat = 80
        let scrolledAway = offsetFromBottom > threshold
        if scrolledAway != userScrolledAway {
            userScrolledAway = scrolledAway
        }
    }

    @ViewBuilder
    private func row(for item: ListItem) -> some View {
        switch item.kind {
        case .day(let label):
            DaySeparator(label: label)
                .rotationEffect(.degrees(180))
                .scaleEffect(x: -1, y: 1, anchor: .center)
                .id(item.id)
        case .message(let msg):
            MessageRow(
                message: msg,
                onRetry: onRetry,
                onImageTap: onImageTap,
                onImageLoaded: { imageLoadTick += 1 }
            )
            .rotationEffect(.degrees(180))
            // Flip horizontally so text and bubbles aren't mirrored after
            // the outer rotation. Two operations compose to identity on
            // glyphs while preserving the reverse-stack layout.
            .scaleEffect(x: -1, y: 1, anchor: .center)
            .id(msg.id)
        }
    }

    enum ListItemKind {
        case day(String)
        case message(ChatMessage)
    }

    struct ListItem: Identifiable {
        let id: String
        let kind: ListItemKind
    }

    /// Build the rendered list (reversed for visual bottom-up display)
    /// inserting day-divider rows between messages on different days.
    static func buildItems(from messages: [ChatMessage]) -> [ListItem] {
        guard !messages.isEmpty else { return [] }
        // Chronological order first so day-divider insertion logic is
        // straightforward; then reverse for the rotated ScrollView.
        var inserted: [ListItem] = []
        var lastKey: String?
        for msg in messages {
            let key = MessageRowHelpers.dayKey(msg.createdAt)
            if let key, key != lastKey {
                if let label = MessageRowHelpers.dayLabel(msg.createdAt) {
                    inserted.append(ListItem(id: "day:\(key)", kind: .day(label)))
                }
                lastKey = key
            }
            inserted.append(ListItem(id: msg.id, kind: .message(msg)))
        }
        return inserted.reversed()
    }
}

/// Preference key for tracking the bottom-anchor row's frame in the
/// scroll view's coordinate space. Used to detect "user scrolled away
/// from bottom".
private struct BottomVisibility: Equatable {
    let frame: CGRect
}

private struct BottomVisibilityKey: PreferenceKey {
    static let defaultValue = BottomVisibility(frame: .zero)
    static func reduce(value: inout BottomVisibility, nextValue: () -> BottomVisibility) {
        value = nextValue()
    }
}

private struct ScrollContainerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScrollToBottomPill: View {
    let count: Int
    let onTap: () -> Void
    @Environment(\.chatColors) private var colors

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                Text(count > 1 ? "New messages (\(count))" : "New messages")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(colors.scrollToBottomIcon)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(colors.scrollToBottomBg))
            .shadow(color: Color.black.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct TypingIndicator: View {
    @Environment(\.chatColors) private var colors
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(colors.typingDot)
                    .frame(width: 6, height: 6)
                    .scaleEffect(scaleFor(index: i))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(colors.typingBg))
        .padding(.leading, 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func scaleFor(index: Int) -> CGFloat {
        let staggered = (phase + Double(index) * 0.15).truncatingRemainder(dividingBy: 1)
        return 0.6 + 0.4 * CGFloat(staggered)
    }
}

#endif
