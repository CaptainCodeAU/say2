// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SiriTTSClientConsumer",
    platforms: [.macOS("15.6")],
    dependencies: [
        .package(name: "siri-tts-cli", path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "SiriTTSClientConsumer",
            dependencies: [
                .product(name: "SiriTTSClient", package: "siri-tts-cli"),
            ]
        ),
    ]
)
