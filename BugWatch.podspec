Pod::Spec.new do |s|
  s.name          = "BugWatch"
  s.version       = "0.1.0"
  s.summary       = "BugWatch — crash, error, and log observability for iOS."
  s.description   = <<~DESC
    BugWatch is the native iOS SDK for the BugWatch observability platform.
    Capture crashes, handled exceptions, and logs with release and session
    context and deliver them to your BugWatch project. Part of the
    newinstance.cloud platform.
  DESC
  s.homepage      = "https://newinstance.cloud"
  s.license       = { :type => "MIT", :file => "LICENSE" }
  s.author        = { "newinstance.cloud" => "support@newinstance.cloud" }
  s.platform      = :ios, "14.0"
  s.swift_version = "5.9"
  s.source        = {
    :git => "https://github.com/talktothelaw/bug-watch-ios.git",
    :tag => s.version.to_s
  }

  s.source_files  = "Sources/BugWatch/**/*.swift"
  s.frameworks    = "Foundation", "Combine", "Network"
end
