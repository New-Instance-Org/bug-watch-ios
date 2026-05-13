import SwiftUI
import UniformTypeIdentifiers
import UIKit
import PhotosUI
import LiveAndAiChat

/// Sample host UI. Mirrors the Android `HeadlessSampleActivity` flow:
///   1. Build a `LiveAndAiChat` instance with the dev API key.
///   2. Call `initialize()` on launch so the heavy config fetch happens
///      in the background.
///   3. Render an "Open chat" button. Tapping it presents the SDK's
///      built-in chat screen as a SwiftUI sheet (no UIKit required).
///   4. Show a status log so it's visible from the host whether the SSE
///      stream connects, messages arrive, etc.
struct RootView: View {

    @StateObject private var sdk: LiveAndAiChat
    @State private var showChat = false
    @State private var showAttachmentChooser = false
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var log: [String] = []

    init() {
        // SSE again — the SDK now uses HTTP1EventSource (Network.framework
        // + NWConnection with TLS ALPN pinned to `http/1.1`), which
        // bypasses iOS URLSession's HTTP/2-only behaviour and works
        // through ngrok-free / any HTTP/1.1-aware proxy. Set
        // `transport: .ws` if you want to force WebSocket instead.
        let config = try! LiveAndAiChatConfig(
            apiKey: Self.exampleApiKey,
            baseUrl: Self.exampleBaseUrl,
            transport: .sse
        )
        let instance = try! LiveAndAiChat.Builder()
            .config(config)
            .user(ChatUser(
                customerName: "Sample User",
                customerEmail: "sample@example.com"
            ))
            .build()
        _sdk = StateObject(wrappedValue: instance)
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                Button(action: openChat) {
                    HStack(spacing: 10) {
                        if sdk.lifecycle == .initializing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        Text(buttonLabel)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(buttonBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(sdk.lifecycle == .initializing)
                Divider()
                HStack(spacing: 8) {
                    Text("Event log")
                        .font(.headline)
                    Spacer()
                    Text("\(log.count) lines")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button(action: shareLog) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(log.isEmpty)
                    Button(action: clearLog) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Clear")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(log.isEmpty)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(log.enumerated()), id: \.offset) { idx, line in
                                logLine(line).id(idx)
                            }
                            Color.clear.frame(height: 1).id("__bottom__")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: log.count) { _ in
                        withAnimation { proxy.scrollTo("__bottom__", anchor: .bottom) }
                    }
                }
            }
            .padding()
            .navigationTitle("LiveAndAiChat")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(activityItems: shareItems)
        }
        .sheet(isPresented: $showChat) {
            ChatScreen(
                sdk: sdk,
                onClose: {
                    sdk.closeChat()
                    showChat = false
                },
                onPickFile: { showAttachmentChooser = true }
            )
            .actionSheet(isPresented: $showAttachmentChooser) {
                ActionSheet(
                    title: Text("Add attachment"),
                    buttons: [
                        .default(Text("Photo Library")) { showPhotoPicker = true },
                        .default(Text("Files")) { showFilePicker = true },
                        .cancel(),
                    ]
                )
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.png, .jpeg, .webP, .gif, .pdf],
                allowsMultipleSelection: true
            ) { result in
                handleFilePick(result)
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPickerSheet(
                    selectionLimit: 0,
                    onPicked: handlePhotoPick
                )
            }
        }
        .onAppear {
            sdk.initialize()
            attachListener()
        }
    }

    /// PHPicker callback — `items` is already loaded as `(data, name,
    /// mimeType)` triples by `PhotoPickerSheet`. We just hand each one
    /// to the SDK's attachment queue.
    private func handlePhotoPick(_ items: [PickedPhoto]) {
        for item in items {
            sdk.attachFile(
                data: item.data,
                name: item.name,
                mimeType: item.mimeType,
                previewUri: nil
            )
        }
    }

    /// Resolves the document-picker result into SDK attach calls. The
    /// security-scoped URL has to be opened with
    /// `startAccessingSecurityScopedResource` so reading the file's bytes
    /// is permitted; we then immediately copy them into memory and hand
    /// them to the SDK queue.
    private func handleFilePick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let mime = UTType(filenameExtension: url.pathExtension)?
                    .preferredMIMEType ?? "application/octet-stream"
                sdk.attachFile(
                    data: data,
                    name: url.lastPathComponent,
                    mimeType: mime,
                    previewUri: url.absoluteString
                )
            } catch {
                log.append("ERR [attach] \(error.localizedDescription)")
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow(label: "Lifecycle", value: String(describing: sdk.lifecycle))
            statusRow(label: "Connection", value: String(describing: sdk.connectionState))
            statusRow(label: "Conversation", value: sdk.conversation?.id ?? "—")
            statusRow(label: "Messages", value: "\(sdk.messages.count)")
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }

    private var buttonLabel: String {
        switch sdk.lifecycle {
        case .initializing, .notStarted: return "Connecting…"
        case .failed: return "Open chat (retry)"
        case .unavailable: return "Open chat (unavailable)"
        case .ready: return sdk.widgetOpen ? "Reopen chat" : "Open chat"
        }
    }

    private var buttonBg: Color {
        sdk.lifecycle == .initializing ? Color.gray : Color(red: 0.58, green: 0.20, blue: 0.92)
    }

    private func openChat() {
        sdk.openChat()
        showChat = true
    }

    private func attachListener() {
        let listener = ExampleListener { line in
            appendLog(line)
        }
        sdk.addDelegate(listener)
        ListenerHolder.shared.keepAlive(listener)

        // Pipe SDK's SSE-layer diagnostic stream into the same event log
        // so users can copy/share a unified transcript when SSE breaks.
        LACDiagnosticLog.setHandler { line in
            appendLog(line)
        }
    }

    private func appendLog(_ line: String) {
        let ts = Self.timeFormatter.string(from: Date())
        let stamped = "\(ts) \(line)"
        DispatchQueue.main.async {
            log.append(stamped)
            if log.count > 1000 { log.removeFirst(log.count - 1000) }
        }
    }

    private func shareLog() {
        let header = """
        === LiveAndAiChat iOS diagnostic ===
        captured: \(Self.timeFormatter.string(from: Date()))
        lifecycle: \(sdk.lifecycle)
        connection: \(sdk.connectionState)
        conversation: \(sdk.conversation?.id ?? "—")
        messages: \(sdk.messages.count)
        baseUrl: \(Self.exampleBaseUrl)
        keyPrefix: \(Self.exampleApiKey.prefix(12))…
        ===
        """
        shareItems = [header + "\n\n" + log.joined(separator: "\n")]
        showShareSheet = true
    }

    private func clearLog() {
        log.removeAll()
    }

    /// Render a single log line. iOS 15+ gets text selection; iOS 14
    /// falls back to plain Text.
    @ViewBuilder
    private func logLine(_ line: String) -> some View {
        if #available(iOS 15.0, *) {
            Text(line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(lineColor(line))
                .textSelection(.enabled)
        } else {
            Text(line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(lineColor(line))
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("WARN") || line.contains("ERR ") || line.contains("error=") {
            return .red
        }
        if line.contains("[LAC/SSE]") {
            return .secondary
        }
        if line.contains("RECV") || line.contains("→ sub") {
            return .blue
        }
        if line.contains("SENT") {
            return .purple
        }
        return .primary
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - Dev configuration

    /// Key used by the example app. Production lives at
    /// `https://service.newinstance.cloud` (the SDK's default); for SDK iteration
    /// we target the team's ngrok dev tunnel instead so we're not exercising
    /// prod with every rebuild. `baseUrl` override is only honoured in
    /// debug SDK builds — the example inherits Debug from its local SwiftPM
    /// build, so this works while developing.
    static let exampleApiKey = "sk_live_pTxXj494eQaARJ6sR42flJMfbKdLzs8j"
    static let exampleBaseUrl = "https://emerging-fleet-vervet.ngrok-free.app"
}

/// Holds a strong reference to delegates so they aren't deallocated.
/// `LiveAndAiChat.addDelegate(_:)` uses an `NSHashTable.weakObjects()`
/// for the listener list (matches Android), so the host has to keep its
/// own strong reference.
final class ListenerHolder {
    static let shared = ListenerHolder()
    private var live: [AnyObject] = []
    func keepAlive(_ obj: AnyObject) { live.append(obj) }
}

final class ExampleListener: LiveAndAiChatDelegate {
    private let onLine: (String) -> Void
    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func didReceiveMessage(_ message: ChatMessage) {
        onLine("RECV [\(message.type.rawValue)] \(message.content)")
    }
    func didSendMessage(_ message: ChatMessage) {
        onLine("SENT \(message.content)")
    }
    func agentTypingDidChange(_ isTyping: Bool) {
        onLine("TYPING \(isTyping)")
    }
    func connectionStateDidChange(_ state: ConnectionState) {
        onLine("CONN \(state)")
    }
    func didEncounterError(_ error: LiveAndAiChatError) {
        onLine("ERR [\(error.type)] \(error.message)")
    }
}

/// Wraps a `UIActivityViewController` so we can present it as a
/// SwiftUI sheet. Used by the "Share log" button so users can copy
/// the diagnostic transcript or send it via Mail / Messages / Files.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Resolved photo-picker output. `data` is the original bytes from
/// the Photos library item (kept as-is for non-image edge cases; for
/// HEIC etc. callers can re-encode if their backend doesn't accept
/// the source MIME). `mimeType` matches the source representation.
struct PickedPhoto {
    let data: Data
    let name: String
    let mimeType: String
}

/// SwiftUI wrapper around `PHPickerViewController` (iOS 14+). The
/// system Files picker (`.fileImporter`) only browses iCloud Drive /
/// On My iPhone / Shared — NOT the user's Photos library. To attach
/// a photo, this is the correct picker. Resolves each selected item
/// into `(data, name, mimeType)` and hands them back as `PickedPhoto`s
/// via the `onPicked` callback. Out-of-process — no `NSPhotoLibrary
/// UsageDescription` Info.plist entry required.
struct PhotoPickerSheet: UIViewControllerRepresentable {
    let selectionLimit: Int  // 0 = unlimited
    let onPicked: ([PickedPhoto]) -> Void

    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = selectionLimit
        config.filter = .images   // photos + screenshots, no video
        config.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPickerSheet
        init(_ parent: PhotoPickerSheet) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Dismiss immediately — the loads below are async.
            parent.presentationMode.wrappedValue.dismiss()

            // Resolve the bytes for every selected asset. We use a
            // serial-ish DispatchGroup so the final `onPicked` fires
            // once, with all items collected.
            let group = DispatchGroup()
            // Preserve picker order even though loads may complete out
            // of sequence — index the slot per result.
            var collected: [Int: PickedPhoto] = [:]
            let lock = NSLock()

            for (idx, result) in results.enumerated() {
                group.enter()
                let provider = result.itemProvider
                // Prefer a directly-loadable image format. The picker
                // delivers either the source representation (e.g. HEIC)
                // or a transcoded JPEG depending on
                // `preferredAssetRepresentationMode = .compatible`.
                let candidateUTIs = ["public.jpeg", "public.png", "public.heic", "public.image"]
                let typeId = candidateUTIs.first { provider.hasItemConformingToTypeIdentifier($0) }
                    ?? "public.image"
                provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    let mime = UTType(typeId)?.preferredMIMEType ?? "image/jpeg"
                    let ext = UTType(typeId)?.preferredFilenameExtension ?? "jpg"
                    let base = provider.suggestedName ?? "photo-\(idx + 1)"
                    let picked = PickedPhoto(
                        data: data,
                        name: "\(base).\(ext)",
                        mimeType: mime
                    )
                    lock.lock()
                    collected[idx] = picked
                    lock.unlock()
                }
            }

            group.notify(queue: .main) {
                let ordered = (0..<results.count).compactMap { collected[$0] }
                self.parent.onPicked(ordered)
            }
        }
    }
}
