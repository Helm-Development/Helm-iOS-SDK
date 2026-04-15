// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Helm",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Helm",
            targets: ["Helm"]
        )
    ],
    targets: [
        .target(
            name: "Helm",
            path: "Sources/Helm"
        ),
        .testTarget(
            name: "HelmTests",
            dependencies: ["Helm"],
            path: "Tests/HelmTests"
        )
    ]
)
