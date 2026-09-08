// swift-tools-version: 6.2
import Foundation
import PackageDescription

private func macOSSDKPath() -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
    process.standardOutput = pipe
    do {
        try process.run()
    } catch {
        fatalError("Unable to run xcrun: \(error)")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("xcrun could not locate the macOS developer kit")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
        fatalError("xcrun returned an empty macOS developer kit path")
    }
    return path
}

let privateFrameworks = macOSSDKPath() + "/System/Library/PrivateFrameworks"
let privateInterfaces = "Sources/PrivateInterfaces"
let xcodePrivateInterfaces = "${SRCROOT}/Sources/PrivateInterfaces"

let package = Package(
    name: "say2",
    platforms: [.macOS("15.6")],
    products: [
        .executable(name: "say2", targets: ["say2"]),
        .library(name: "Say2Client", targets: ["Say2Client"]),
    ],
    targets: [
        .target(name: "Say2Client"),
        .target(
            name: "Say2Core",
            swiftSettings: [
                .unsafeFlags([
                    "-enable-library-evolution",
                    "-I\(privateInterfaces)",
                    "-I\(xcodePrivateInterfaces)",
                    "-F\(privateFrameworks)",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", privateFrameworks,
                    "-Xlinker", "-weak_framework",
                    "-Xlinker", "SiriTTSService",
                ]),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "say2",
            dependencies: ["Say2Core"]
        ),
        .testTarget(
            name: "Say2CoreTests",
            dependencies: ["Say2Core"],
            swiftSettings: [
                .unsafeFlags([
                    "-I\(privateInterfaces)",
                    "-I\(xcodePrivateInterfaces)",
                    "-F\(privateFrameworks)",
                ]),
            ]
        ),
        .testTarget(
            name: "Say2ClientTests",
            dependencies: ["Say2Client"]
        ),
    ]
)
