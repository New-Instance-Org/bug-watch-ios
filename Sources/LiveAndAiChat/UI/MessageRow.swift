#if canImport(UIKit)
import SwiftUI

/// Renders one message row: optional sender label, optional text bubble,
/// attachments rendered OUTSIDE the bubble (matches the web /
/// Android implementations). A FAILED message shows a tap-to-retry
/// affordance below the bubble.
struct MessageRow: View {

    let message: ChatMessage
    let onRetry: (String) -> Void
    let onImageTap: (MessageAttachment) -> Void
    let onImageLoaded: () -> Void
    @Environment(\.chatColors) private var colors

    var body: some View {
        // System messages render as centered italic text with no bubble,
        // no sender label, no timestamp — matches the web SDK exactly.
        if message.type == .system {
            SystemMessageRow(content: message.content)
                .environment(\.chatColors, colors)
        } else {
            chatMessageBody
        }
    }

    private var chatMessageBody: some View {
        let isCustomer = message.type == .customer
        let hasContent = !message.content.isEmpty
        let hasAttachments = !message.attachments.isEmpty
        let isFailed = message.status == .failed

        return VStack(alignment: isCustomer ? .trailing : .leading, spacing: 4) {
            if !isCustomer, let label = senderLabel {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
                    .padding(.leading, 4)
            }
            if hasContent {
                TextBubble(message: message, isCustomer: isCustomer)
                    .environment(\.chatColors, colors)
            }
            if hasAttachments {
                AttachmentsBlock(
                    attachments: message.attachments,
                    isCustomer: isCustomer,
                    topPadding: hasContent ? 6 : 0,
                    onImageTap: onImageTap,
                    onImageLoaded: onImageLoaded
                )
                .environment(\.chatColors, colors)
            }
            if isFailed {
                Button { onRetry(message.id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text("Failed · tap to retry")
                            .font(.system(size: 11))
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(colors.errorColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: isCustomer ? .trailing : .leading)
    }

    private var senderLabel: String? {
        switch message.type {
        case .ai: return "AI"
        case .agent:
            let raw = message.sender?.senderName ?? "Agent"
            return ChatHeader.titleCase(raw)
        case .system, .customer: return nil
        }
    }
}

/// Centered italic system notice rendered inline with the message
/// stream. No bubble, no sender label, no timestamp — matches the web
/// SDK's `MessageBubble` SYSTEM branch.
private struct SystemMessageRow: View {
    let content: String
    @Environment(\.chatColors) private var colors

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(content)
                .font(.system(size: 12).italic())
                .foregroundColor(colors.systemMessageText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TextBubble: View {
    let message: ChatMessage
    let isCustomer: Bool
    @Environment(\.chatColors) private var colors

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(message.content)
                .foregroundColor(foregroundColor)
                .frame(maxWidth: 280, alignment: .leading)
            BubbleFooter(message: message, isCustomer: isCustomer)
                .environment(\.chatColors, colors)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bubbleShape.fill(backgroundColor))
    }

    private var backgroundColor: Color {
        switch message.type {
        case .customer: return colors.sentBubble
        case .agent, .ai, .system: return colors.receivedBubble
        }
    }

    private var foregroundColor: Color {
        switch message.type {
        case .customer: return colors.sentText
        case .agent, .ai: return colors.receivedText
        case .system: return colors.systemMessageText
        }
    }

    private var bubbleShape: RoundedCorners {
        isCustomer
            ? RoundedCorners(tl: 16, tr: 16, bl: 16, br: 4)
            : RoundedCorners(tl: 16, tr: 16, bl: 4, br: 16)
    }
}

/// Timestamp + status checkmark row that lives inside the bubble's bottom-right
/// — matches WhatsApp / web SDK / Android. System messages don't render either.
private struct BubbleFooter: View {
    let message: ChatMessage
    let isCustomer: Bool
    @Environment(\.chatColors) private var colors

    var body: some View {
        if message.type == .system {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                if let ts = MessageRowHelpers.formatTimestamp(message.createdAt) {
                    Text(ts)
                        .font(.system(size: 10))
                        .foregroundColor(timestampColor)
                }
                if isCustomer {
                    statusIcon
                }
            }
        }
    }

    private var timestampColor: Color {
        isCustomer ? colors.sentTimestamp : colors.receivedTimestamp
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundColor(colors.errorColor)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(timestampColor)
        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(timestampColor)
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(colors.successColor)
        }
    }
}

/// 4-corner rounded rectangle. SwiftUI's stock `RoundedRectangle` doesn't
/// support asymmetric corners until iOS 16+; we hand-roll a path so the
/// SDK can build for iOS 14.
struct RoundedCorners: Shape {
    var tl: CGFloat = 0
    var tr: CGFloat = 0
    var bl: CGFloat = 0
    var br: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let tlc = min(tl, min(w, h) / 2)
        let trc = min(tr, min(w, h) / 2)
        let blc = min(bl, min(w, h) / 2)
        let brc = min(br, min(w, h) / 2)
        path.move(to: CGPoint(x: tlc, y: 0))
        path.addLine(to: CGPoint(x: w - trc, y: 0))
        path.addArc(
            center: CGPoint(x: w - trc, y: trc),
            radius: trc, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        path.addLine(to: CGPoint(x: w, y: h - brc))
        path.addArc(
            center: CGPoint(x: w - brc, y: h - brc),
            radius: brc, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: blc, y: h))
        path.addArc(
            center: CGPoint(x: blc, y: h - blc),
            radius: blc, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.addLine(to: CGPoint(x: 0, y: tlc))
        path.addArc(
            center: CGPoint(x: tlc, y: tlc),
            radius: tlc, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Attachments

struct AttachmentsBlock: View {
    let attachments: [MessageAttachment]
    let isCustomer: Bool
    let topPadding: CGFloat
    let onImageTap: (MessageAttachment) -> Void
    let onImageLoaded: () -> Void
    @Environment(\.chatColors) private var colors

    var body: some View {
        let split = MessageRowHelpers.splitAttachments(attachments)
        VStack(alignment: isCustomer ? .trailing : .leading, spacing: 6) {
            if !split.images.isEmpty {
                ImageGrid(
                    images: split.images,
                    isCustomer: isCustomer,
                    onImageTap: onImageTap,
                    onImageLoaded: onImageLoaded
                )
                .environment(\.chatColors, colors)
            }
            ForEach(split.files, id: \.url) { att in
                FileAttachmentRow(attachment: att, isCustomer: isCustomer)
                    .environment(\.chatColors, colors)
            }
        }
        .padding(.top, topPadding)
    }
}

struct ImageGrid: View {
    let images: [MessageAttachment]
    let isCustomer: Bool
    let onImageTap: (MessageAttachment) -> Void
    let onImageLoaded: () -> Void
    @Environment(\.chatColors) private var colors

    private var frameBg: Color {
        isCustomer ? colors.sentBubble.opacity(0.15) : colors.receivedBubble
    }

    var body: some View {
        Group {
            if images.count == 1 {
                singleImage
            } else {
                tiledGrid
            }
        }
        .padding(6)
        .background(RoundedCorners(tl: 16, tr: 16, bl: 16, br: 16).fill(frameBg))
    }

    private var singleImage: some View {
        ImageBubble(attachment: images[0], onTap: onImageTap, onLoaded: onImageLoaded)
            .frame(maxWidth: 280)
    }

    private var tiledGrid: some View {
        let visible = Array(images.prefix(4))
        let overflow = images.count - visible.count
        let indexed: [(offset: Int, element: MessageAttachment)] =
            visible.enumerated().map { ($0.offset, $0.element) }
        let rows: [[(offset: Int, element: MessageAttachment)]] = indexed.chunked(into: 2)
        return VStack(spacing: 3) {
            ForEach(rows, id: \.first!.offset) { row in
                tileRow(row: row, lastVisibleIndex: visible.count - 1, overflow: overflow)
            }
        }
    }

    private func tileRow(
        row: [(offset: Int, element: MessageAttachment)],
        lastVisibleIndex: Int,
        overflow: Int
    ) -> some View {
        HStack(spacing: 3) {
            ForEach(row, id: \.element.url) { item in
                tile(
                    attachment: item.element,
                    showOverflow: item.offset == lastVisibleIndex && overflow > 0,
                    overflow: overflow
                )
            }
        }
    }

    private func tile(
        attachment: MessageAttachment,
        showOverflow: Bool,
        overflow: Int
    ) -> some View {
        ZStack {
            ImageBubble(
                attachment: attachment,
                cropToSquare: true,
                onTap: onImageTap,
                onLoaded: onImageLoaded
            )
            .frame(width: 110, height: 110)
            if showOverflow {
                Color.black.opacity(0.55)
                Text("+\(overflow)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .clipShape(RoundedCorners(tl: 8, tr: 8, bl: 8, br: 8))
    }
}

struct ImageBubble: View {
    let attachment: MessageAttachment
    var cropToSquare: Bool = false
    let onTap: (MessageAttachment) -> Void
    let onLoaded: () -> Void
    @Environment(\.chatColors) private var colors

    var body: some View {
        imageContent
            .frame(
                minWidth: cropToSquare ? nil : 140,
                maxWidth: cropToSquare ? nil : 260,
                minHeight: cropToSquare ? nil : 100,
                maxHeight: cropToSquare ? nil : 360
            )
            .background(colors.background)
            .clipShape(RoundedCorners(tl: 12, tr: 12, bl: 12, br: 12))
            .contentShape(Rectangle())
            .onTapGesture { onTap(attachment) }
    }

    @ViewBuilder
    private var imageContent: some View {
        if #available(iOS 15.0, *) {
            AsyncImage(url: URL(string: attachment.url)) { phase in
                switch phase {
                case .empty:
                    loadingPlaceholder
                case .failure:
                    errorPlaceholder
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: cropToSquare ? .fill : .fit)
                        .onAppear { onLoaded() }
                @unknown default:
                    loadingPlaceholder
                }
            }
        } else {
            loadingPlaceholder
        }
    }

    private var loadingPlaceholder: some View {
        ZStack {
            colors.typingBg
            ProgressView()
                .progressViewStyle(.circular)
                .foregroundColor(colors.textSecondary)
        }
        .frame(width: cropToSquare ? 110 : 220, height: cropToSquare ? 110 : 165)
    }

    private var errorPlaceholder: some View {
        ZStack {
            colors.typingBg
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundColor(colors.textSecondary)
        }
        .frame(width: cropToSquare ? 110 : 220, height: cropToSquare ? 110 : 165)
    }
}

struct FileAttachmentRow: View {
    let attachment: MessageAttachment
    let isCustomer: Bool
    @Environment(\.chatColors) private var colors

    private var isPdf: Bool {
        attachment.type.lowercased() == "application/pdf"
            || attachment.name.lowercased().hasSuffix(".pdf")
    }

    private var pillBg: Color {
        isCustomer ? colors.sentBubble.opacity(0.15) : colors.border
    }

    private var pillText: Color {
        isCustomer ? colors.sentText : colors.text
    }

    var body: some View {
        HStack(spacing: 10) {
            if isPdf {
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 28))
                    .foregroundColor(colors.errorColor)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 28))
                    .foregroundColor(pillText)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(pillText)
                    .lineLimit(1)
                if attachment.size > 0 {
                    Text(MessageRowHelpers.formatBytes(attachment.size))
                        .font(.system(size: 10))
                        .foregroundColor(pillText.opacity(0.7))
                }
            }
            Spacer()
            Image(systemName: "eye")
                .font(.system(size: 14))
                .foregroundColor(pillText.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 280)
        .background(RoundedCorners(tl: 10, tr: 10, bl: 10, br: 10).fill(pillBg))
        .onTapGesture {
            if let url = URL(string: attachment.url) {
                UIApplication.shared.open(url)
            }
        }
    }
}

// MARK: - Helpers

enum MessageRowHelpers {
    struct Split {
        let images: [MessageAttachment]
        let files: [MessageAttachment]
    }

    static func splitAttachments(_ atts: [MessageAttachment]) -> Split {
        var images: [MessageAttachment] = []
        var files: [MessageAttachment] = []
        for a in atts { isImage(a) ? images.append(a) : files.append(a) }
        return Split(images: images, files: files)
    }

    static func isImage(_ att: MessageAttachment) -> Bool {
        if att.type.lowercased().hasPrefix("image/") { return true }
        let ext = (att.name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif"].contains(ext)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = iso8601.date(from: raw) { return d }
        if let d = iso8601NoFraction.date(from: raw) { return d }
        return nil
    }

    /// Localized short time for a message bubble. Returns nil when no
    /// timestamp is present so the caller can simply omit the row.
    static func formatTimestamp(_ raw: String?) -> String? {
        guard let date = parseDate(raw) else { return nil }
        return timeFormatter.string(from: date)
    }

    /// Stable day-bucket key (yyyy-MM-dd in current calendar) so the
    /// message list can detect day boundaries without comparing Dates
    /// directly.
    static func dayKey(_ raw: String?) -> String? {
        guard let date = parseDate(raw) else { return nil }
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Human-readable day separator label. Today / Yesterday / localized
    /// medium date. Matches the Android `MessageList` day-header rule.
    static func dayLabel(_ raw: String?) -> String? {
        guard let date = parseDate(raw) else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }
}

/// Centered date chip rendered between messages on different days.
struct DaySeparator: View {
    let label: String
    @Environment(\.chatColors) private var colors

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(colors.daySeparatorText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(colors.daySeparatorBg))
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

extension Array {
    /// Splits the array into rows of size `n`. Tail row may be shorter.
    /// Used by ``ImageGrid`` to pack a 2-column tile grid without
    /// dropping the trailing odd image.
    func chunked(into n: Int) -> [[Element]] {
        guard n > 0 else { return [] }
        return stride(from: 0, to: count, by: n).map {
            Array(self[$0..<Swift.min($0 + n, count)])
        }
    }
}

#endif
