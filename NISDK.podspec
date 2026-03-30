Pod::Spec.new do |s|
  s.name          = "NISDK"
  s.version       = "0.1.0"
  s.summary       = "NISDK iOS SDK."
  s.description   = "Minimal Swift Package and CocoaPods scaffold for NISDK development."
  s.homepage      = "https://example.com/nisdk-ios"
  s.license       = { :type => "MIT" }
  s.author        = { "New Instance" => "dev@example.com" }
  s.platform      = :ios, "13.0"
  s.swift_version = "5.9"
  s.source        = { :git => "https://example.com/newinstance/nisdk-ios.git", :tag => s.version.to_s }

  s.source_files  = "Sources/NISDK/**/*.swift"
  s.frameworks    = "Foundation"
end
