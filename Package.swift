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
    name: "siri-tts-cli",
    platforms: [.macOS("15.6")],
    products: [
        .executable(name: "siri-tts", targets: ["siri-tts"]),
        .library(name: "SiriTTSClient", targets: ["SiriTTSClient"]),
    ],
    targets: [
        .target(name: "SiriTTSClient"),
        .target(
            name: "SiriTTSCore",
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
            name: "siri-tts",
            dependencies: ["SiriTTSCore"]
        ),
        .testTarget(
            name: "SiriTTSCoreTests",
            dependencies: ["SiriTTSCore"],
            swiftSettings: [
                .unsafeFlags([
                    "-I\(privateInterfaces)",
                    "-I\(xcodePrivateInterfaces)",
                    "-F\(privateFrameworks)",
                ]),
            ]
        ),
        .testTarget(
            name: "SiriTTSClientTests",
            dependencies: ["SiriTTSClient"]
        ),
    ]
)
