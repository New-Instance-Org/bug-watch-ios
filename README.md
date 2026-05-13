# LiveAndAiChat — iOS SDK

A native Swift SDK that drops a complete AI + live-agent chat experience into
your iOS app. Hosted by [newinstance.cloud](https://newinstance.cloud).

- SwiftUI chat screen with typing indicators, attachment thumbnails, image
  viewer, and per-message status receipts
- AI conversation with seamless handoff to a live human agent
- Photo Library + Files attachment pickers
- Two-tier image cache (memory + disk) — repeat renders never re-fetch
- Resilient transport: HTTP/1.1-pinned Server-Sent Events with WebSocket fallback
- Offline-tolerant — silent gap-fill resync when the network drops events
- Light / dark themes, Dynamic Type, VoiceOver, Reduce Motion, iPad layout

## Requirements

- iOS 14.0+
- Swift 5.9 (Xcode 15+)

## Installation

### Swift Package Manager

In Xcode → **File → Add Package Dependencies…** and enter:

```
https://gitlab.com/talktothelaw/liveandaichat-ios.git
```

Or in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://gitlab.com/talktothelaw/liveandaichat-ios.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "LiveAndAiChat", package: "liveandaichat-ios"),
        ]
    )
]
```

### CocoaPods

```ruby
pod 'LiveAndAiChat', '~> 0.1.0'
```

## Quick start

```swift
import SwiftUI
import LiveAndAiChat

@main
struct MyApp: App {
    @StateObject private var sdk: LiveAndAiChat = {
        let config = try! LiveAndAiChatConfig(apiKey: "sk_live_…")
        return try! LiveAndAiChat.Builder()
            .config(config)
            .user(ChatUser(customerName: "Ada", customerEmail: "ada@example.com"))
            .build()
    }()

    @State private var showChat = false

    var body: some Scene {
        WindowGroup {
            Button("Talk to support") { showChat = true }
                .sheet(isPresented: $showChat) {
                    ChatScreen(
                        sdk: sdk,
                        onClose: { showChat = false },
                        onPickFile: { /* present your attachment picker */ }
                    )
                }
                .onAppear { sdk.initialize() }
        }
    }
}
```

That's the entire integration. Brand colours, agent assignment, AI bot config,
and welcome message all come from the dashboard at
[`newinstance.cloud`](https://newinstance.cloud) — there's nothing else to wire up.

### UIKit hosts

If you don't use SwiftUI, present the chat as a modal:

```swift
import LiveAndAiChat

class ViewController: UIViewController {
    let sdk = try! LiveAndAiChat.Builder()
        .config(try! LiveAndAiChatConfig(apiKey: "sk_live_…"))
        .user(ChatUser(customerName: "Ada"))
        .build()

    @IBAction func talkToSupport() {
        sdk.present(from: self)
    }
}
```

## Configuration

`LiveAndAiChatConfig` only requires an API key. Get one from your dashboard at
[newinstance.cloud](https://newinstance.cloud) → **Settings → API keys**.

```swift
let config = try LiveAndAiChatConfig(
    apiKey: "sk_live_…",       // required — keyId only, never embed the secret half
    transport: .sse,           // .sse (default), .ws, or nil to let the server decide
    initialMessage: "Hi!"      // optional — pre-seeds the first message
)
```

### User identity

```swift
sdk.setUser(ChatUser(
    customerName: "Ada Lovelace",     // required
    customerEmail: "ada@example.com", // optional
    customerId: "user_42"             // optional — your internal id
))
```

You can call `setUser` after `build()` if identity becomes available later
(post-login). Changing the email or customerId clears any saved conversation
and starts fresh.

## Sending messages and attachments

```swift
sdk.sendMessage("Hi, I have a question.")

// Queue an attachment from a PHPickerResult / UIDocumentPicker pick:
sdk.attachFile(
    data: fileData,
    name: "screenshot.png",
    mimeType: "image/png",
    previewUri: localFileURL.absoluteString
)
// Next sendMessage() drains the queue and includes uploaded attachments.

sdk.retryMessage(messageId: failedMessage.id)
sdk.requestHandoff(reason: "billing question")
sdk.sendTypingStart()  // automatically followed by sendTypingStop after idle
```

## Observing state

`LiveAndAiChat` is an `ObservableObject`. Bind any `@Published` property to your
SwiftUI views or subscribe with Combine:

| Property | Type | What it tells you |
|---|---|---|
| `lifecycle` | `ChatSdkLifecycle` | `.notStarted` / `.initializing` / `.ready` / `.unavailable` / `.failed` |
| `connectionState` | `ConnectionState` | `.idle` / `.connecting` / `.connected` / `.disconnected` / `.offline` |
| `messages` | `[ChatMessage]` | the conversation, ordered |
| `conversation` | `Conversation?` | server-side conversation status |
| `assignment` | `Assignment?` | live-agent assignment state |
| `agentTyping` | `Bool` | true while the agent is typing |
| `unreadCount` | `Int` | unread inbound messages while the widget is closed |
| `orgConfig` | `OrgChatConfig?` | merchant branding + appearance + settings |
| `widgetOpen` | `Bool` | true between `openChat()` and `closeChat()` |

For UIKit / closure-based hosts, use the delegate:

```swift
class MyHandler: LiveAndAiChatDelegate {
    func didReceiveMessage(_ m: ChatMessage) { … }
    func didSendMessage(_ m: ChatMessage) { … }
    func agentTypingDidChange(_ t: Bool) { … }
    func connectionStateDidChange(_ s: ConnectionState) { … }
    func didEncounterError(_ e: LiveAndAiChatError) { … }
}

sdk.addDelegate(MyHandler())
```

## Customisation

Branding (colours, logo, company name, welcome message) is configured from your
dashboard at [newinstance.cloud](https://newinstance.cloud) — the SDK fetches it on
launch and applies it automatically. You do not need to ship colour values in
the app.

If no merchant appearance is configured, the SDK falls back to a sensible
light or dark default based on the system colour scheme.

## Privacy

The SDK does not require any `Info.plist` permission keys. Photo Library
access for attachments uses `PHPickerViewController`, which runs out-of-process
and doesn't trigger the `NSPhotoLibraryUsageDescription` prompt.

If you save attachments to the device's Photos library from the in-app image
viewer, add:

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>So you can save chat images to Photos.</string>
```

## Error handling

```swift
sdk.addDelegate(MyHandler())  // see above

// Or via Combine:
sdk.$lifecycle
    .sink { lifecycle in
        if lifecycle == .failed {
            // initialize() failed — show retry CTA
            // sdk.initialize() will try again
        }
    }
    .store(in: &bag)
```

`LiveAndAiChatError.type` is one of `.network` / `.validation` / `.auth` /
`.system`. `error.recoverable == true` means a retry has a chance of
succeeding.

## Sample app

The repository's `Example/` directory contains a runnable sample app
demonstrating the full integration. Open `Example/LiveAndAiChatExample.xcodeproj`
in Xcode 15+.

## License

MIT — see [LICENSE](./LICENSE).
