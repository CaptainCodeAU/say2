// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Say2ClientConsumer",
    platforms: [.macOS("15.6")],
    dependencies: [
        .package(name: "say2", path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "Say2ClientConsumer",
            dependencies: [
                .product(name: "Say2Client", package: "say2"),
            ]
        ),
    ]
)
