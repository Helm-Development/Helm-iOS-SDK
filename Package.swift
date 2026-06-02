// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Helm",
    platforms: [
        .iOS(.v15)
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
            path: "Sources/Helm",
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "HelmTests",
            dependencies: ["Helm"],
            path: "Tests/HelmTests"
        )
    ]
)
