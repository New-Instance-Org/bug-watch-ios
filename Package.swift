// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BugWatch",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "BugWatch",
            targets: ["BugWatch"]
        ),
    ],
    dependencies: [
        // Provides `import Crypto` (HMAC-SHA256). On Apple platforms swift-crypto
        // forwards to the system CryptoKit; on Linux it ships its own backend.
        .package(url: "https://github.com/apple/swift-crypto.git", "2.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(
            name: "BugWatch",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/BugWatch"
        ),
        .testTarget(
            name: "BugWatchTests",
            dependencies: ["BugWatch"],
            path: "Tests/BugWatchTests"
        ),
        // Dev-only E2E probe: drives the real SDK against a running backend.
        .executableTarget(
            name: "BugWatchE2EProbe",
            dependencies: ["BugWatch"],
            path: "Examples/E2EProbe"
        ),
    ]
)
