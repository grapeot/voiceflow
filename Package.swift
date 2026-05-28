// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoiceFlowKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "VoiceFlowKit", targets: ["VoiceFlowKit"])
    ],
    targets: [
        .target(
            name: "VoiceFlowKit",
            path: "Sources/VoiceFlowKit",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "VoiceFlowKitTests",
            dependencies: ["VoiceFlowKit"],
            path: "Tests/VoiceFlowKitTests"
        )
    ]
)
