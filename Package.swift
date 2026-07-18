// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OllamaKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "OllamaKit", targets: ["OllamaKit"]),
    ],
    targets: [
        .target(name: "OllamaKit"),
        .testTarget(
            name: "OllamaKitTests",
            dependencies: ["OllamaKit"]
        ),
    ]
)
