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
    targets: [
        .target(
            name: "BugWatch",
            path: "Sources/BugWatch"
        ),
        .testTarget(
            name: "BugWatchTests",
            dependencies: ["BugWatch"],
            path: "Tests/BugWatchTests"
        ),
    ]
)
