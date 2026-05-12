#if canImport(UIKit)
import SwiftUI
import UIKit

/// Text input + attachment chip strip + send button. Mirrors the Android
/// `Composer` Composable and the web SDK's `Composer.tsx`.
///
/// Behaviour:
///   - Send is disabled while text + attachments are both empty.
///   - Pressing send clears the text field; the parent is responsible for
///     draining and clearing the attachment queue.
///   - Typing debounce: emits `onTyping(true)` on the first keystroke,
///     `onTyping(false)` after 4s of silence. This matches the typing
///     timeouts used by the Android composer.
struct Composer: View {
    let placeholderText: String
    let pendingAttachments: [QueuedAttachment]
    let attachmentsAllowed: Bool
    let enabled: Bool
    let onPickFile: () -> Void
    let onRemoveAttachment: (String) -> Void
    let onSend: (String) -> Void
    let onTyping: (Bool) -> Void

    @State private var text: String = ""
    @State private var isTyping: Bool = false
    @State private var typingDebounce: DispatchWorkItem?
    @Environment(\.chatColors) private var colors

    private var canSend: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUploaded = pendingAttachments.contains { $0.status == .uploaded }
        return enabled && !isUploading && (!trimmed.isEmpty || hasUploaded)
    }

    /// Send is held while any attachment is still mid-flight. Matches the
    /// Android composer's behaviour — we don't want the customer to send
    /// a message that references a URL that hasn't been minted yet.
    private var isUploading: Bool {
        pendingAttachments.contains { $0.status == .uploading || $0.status == .queued }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(colors.border)
            if !pendingAttachments.isEmpty {
                AttachmentChipStrip(
                    items: pendingAttachments,
                    onRemove: onRemoveAttachment
                )
                .environment(\.chatColors, colors)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if attachmentsAllowed {
                    Button(action: onPickFile) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18))
                            .foregroundColor(colors.attachmentButton)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholderText)
                            .foregroundColor(colors.inputPlaceholder)
                            .font(.system(size: 14))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 14))
                        .foregroundColor(colors.inputText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .scrollContentBackgroundHiddenIfAvailable()
                        .background(Color.clear)
                        .onChange(of: text) { newValue in
                            handleTextChange(newValue)
                        }
                }
                .frame(height: composerInputHeight)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(colors.inputBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(colors.inputBorder, lineWidth: 1)
                )

                Button(action: sendTapped) {
                    Group {
                        if isUploading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: colors.sendButtonIcon))
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(colors.sendButtonIcon)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(canSend ? colors.sendButtonBg : colors.sendButtonBg.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(isUploading ? "Uploading" : "Send")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(colors.footerContainer.ignoresSafeArea(edges: .bottom))
    }

    /// Compose-time height for the input rounded rect. Matches the web's
    /// `min-h-[36px] max-h-[120px]` semantics — we approximate line count
    /// via newline characters since TextEditor doesn't expose intrinsic
    /// content size. Single-line by default; grows up to ~5 lines then
    /// scrolls internally.
    private var composerInputHeight: CGFloat {
        let newlineCount = text.reduce(into: 0) { $0 += $1 == "\n" ? 1 : 0 }
        // 36 = single line; grow ~18pt per newline up to 120.
        let raw = 36 + CGFloat(newlineCount) * 18
        return min(max(raw, 36), 120)
    }

    private func handleTextChange(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !isTyping {
            isTyping = true
            onTyping(true)
        }
        typingDebounce?.cancel()
        let work = DispatchWorkItem {
            if isTyping {
                isTyping = false
                onTyping(false)
            }
        }
        typingDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func sendTapped() {
        guard canSend else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onSend(body)
        text = ""
        if isTyping {
            isTyping = false
            onTyping(false)
        }
        typingDebounce?.cancel()
    }
}

/// Horizontally scrolling row of 56×56 thumb chips — one per queued
/// attachment. Mirrors the web SDK's `DraggableStrip` layout (px-3 pt-2
/// pb-1, gap-2). Hidden scrollbar; native swipe scroll.
struct AttachmentChipStrip: View {
    let items: [QueuedAttachment]
    let onRemove: (String) -> Void
    @Environment(\.chatColors) private var colors

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(items) { item in
                    AttachmentChip(item: item, onRemove: onRemove)
                        .environment(\.chatColors, colors)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .background(colors.footerContainer)
    }
}

/// 56×56 square thumb with floating remove button and a two-line
/// label/status caption underneath. Matches the web SDK's
/// AttachmentChip vertical layout (image-grid friendly even with many
/// items queued).
struct AttachmentChip: View {
    let item: QueuedAttachment
    let onRemove: (String) -> Void
    @Environment(\.chatColors) private var colors

    var body: some View {
        VStack(spacing: 4) {
            thumbContainer
            Text(displayName)
                .font(.system(size: 10))
                .foregroundColor(item.status == .failed ? colors.errorColor : colors.textSecondary)
                .lineLimit(1)
                .frame(width: 64)
            Text(subline)
                .font(.system(size: 9))
                .foregroundColor(colors.textSecondary.opacity(0.7))
                .lineLimit(1)
                .frame(width: 64)
        }
        .frame(width: 64)
    }

    private var thumbContainer: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                colors.inputBg
                content
                if item.status == .uploading || item.status == .queued {
                    Color.black.opacity(0.30)
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.85)
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer()
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.85))
                                    .frame(width: max(0, geo.size.width * CGFloat(progressFraction)), height: 3)
                                Rectangle()
                                    .fill(Color.white.opacity(0.20))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 3)
                            }
                        }
                    }
                }
                if item.status == .failed {
                    Color(red: 0.94, green: 0.27, blue: 0.27).opacity(0.20)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(colors.errorColor)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(item.status == .failed ? colors.errorColor : Color.clear, lineWidth: 1)
            )

            if item.status != .uploading && item.status != .queued {
                Button { onRemove(item.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(colors.textSecondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(colors.background))
                        .overlay(Circle().stroke(colors.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove attachment")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isImageAttachment {
            if let preview = previewImage {
                preview
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundColor(colors.textSecondary)
            }
        } else {
            Image(systemName: "doc.fill")
                .font(.system(size: 22))
                .foregroundColor(colors.textSecondary)
        }
    }

    private var isImageAttachment: Bool {
        if item.mimeType.lowercased().hasPrefix("image/") { return true }
        let ext = (item.name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif", "heic"].contains(ext)
    }

    private var progressFraction: Double {
        item.status == .queued ? 0 : max(0, min(1, item.progress))
    }

    private var displayName: String {
        if item.status == .failed { return "Failed" }
        let max = 12
        if item.name.count <= max { return item.name }
        let ns = item.name as NSString
        let ext = ns.pathExtension
        if !ext.isEmpty {
            let base = (item.name as NSString).deletingPathExtension
            let suffix = "." + ext
            let available = max - suffix.count - 1
            if available > 2 {
                let endIdx = base.index(base.startIndex, offsetBy: min(available, base.count))
                return String(base[..<endIdx]) + "…" + suffix
            }
        }
        let endIdx = item.name.index(item.name.startIndex, offsetBy: max - 1)
        return String(item.name[..<endIdx]) + "…"
    }

    private var subline: String {
        switch item.status {
        case .queued: return "Queued"
        case .uploading: return "\(Int(item.progress * 100))%"
        case .uploaded: return MessageRowHelpers.formatBytes(item.size)
        case .failed: return item.errorReason ?? "Failed"
        }
    }

    private var previewImage: AnyView? {
        let primary = item.previewUri.flatMap { URL(string: $0) }
        let fallback = item.publicUrl.flatMap { URL(string: $0) }
        guard let url = primary ?? fallback else { return nil }

        if url.isFileURL,
           let data = try? Data(contentsOf: url),
           let uiImage = UIImage(data: data) {
            return AnyView(
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            )
        }

        if #available(iOS 15.0, *) {
            return AnyView(
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.clear
                    }
                }
            )
        }

        return nil
    }
}

// MARK: - iOS-15 niceties

private extension View {
    /// Hides the default TextEditor background on iOS 16+ so the editor
    /// transparently sits inside our rounded container. No-op on iOS 14/15
    /// — the SwiftUI default already paints white there.
    @ViewBuilder
    func scrollContentBackgroundHiddenIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

#endif
