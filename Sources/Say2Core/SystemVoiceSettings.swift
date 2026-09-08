import Foundation

public enum SystemVoiceSettings {
    /// The current macOS Accessibility > Read & Speak settings extension.
    public static let url = URL(
        string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"
    )!

    public static func open() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError(
                "Could not open System Settings: \(error.localizedDescription)",
                code: .internalFailure
            )
        }
        guard process.terminationStatus == 0 else {
            throw CLIError("Could not open System Settings", code: .internalFailure)
        }
    }
}
