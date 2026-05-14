Pod::Spec.new do |s|
  s.name          = "LiveAndAiChat"
  s.version       = "0.1.0"
  s.summary       = "Native iOS chat SDK — AI + live agent, drop-in SwiftUI screen."
  s.description   = <<~DESC
    LiveAndAiChat is a complete iOS chat SDK for newinstance.cloud. It ships a
    SwiftUI chat screen, typing indicators, image and file attachments, an
    in-app image viewer, a two-tier image cache, and a transport stack
    resilient to flaky networks (HTTP/1.1-pinned Server-Sent Events with
    WebSocket fallback, silent gap-fill resync, exponential reconnect).
    Branding and behaviour are configured from the newinstance.cloud dashboard
    — your app just supplies an API key and a user identity.
  DESC
  s.homepage      = "https://github.com/talktothelaw/new-instance-livechat"
  s.license       = { :type => "MIT", :file => "LICENSE" }
  s.author        = {
    "newinstance.cloud"          => "support@newinstance.cloud",
    "Nwoko Lawrence Ndubueze"    => "nwokolawrence6@gmail.com"
  }
  s.platform      = :ios, "14.0"
  s.swift_version = "5.9"
  s.source        = {
    :git => "https://github.com/talktothelaw/new-instance-livechat.git",
    :tag => s.version.to_s
  }

  s.source_files  = "Sources/LiveAndAiChat/**/*.swift"
  s.frameworks    = "Foundation", "Combine", "Network", "Security",
                    "SwiftUI", "UIKit", "PhotosUI", "AVFoundation",
                    "CryptoKit"
end
