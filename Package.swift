// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceFlowKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v2)
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
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VoiceFlowKitTests",
            dependencies: ["VoiceFlowKit"],
            path: "Tests/VoiceFlowKitTests",
            resources: [
                .copy("Fixtures/tts_all_caps_24k.wav")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
