// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NISDK",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "NISDK",
            targets: ["NISDK"]
        ),
    ],
    targets: [
        .target(
            name: "NISDK"
        ),
        .testTarget(
            name: "NISDKTests",
            dependencies: ["NISDK"]
        ),
    ]
)
