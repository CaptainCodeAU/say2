import Foundation
import Say2Client

@main
struct Consumer {
    static func main() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["SAY2_HELPER_URL"],
              let helperURL = URL(string: rawURL) else {
            _ = Say2Client()
            return
        }

        let client = Say2Client(configuration: .init(baseURL: helperURL))
        let voices = try await client.voices()
        guard let voice = voices.first else {
            throw ConsumerError("The helper returned no voices")
        }
        let audio = try await client.synthesize(.init(
            text: "External Swift package client integration test.",
            voice: voice.id
        ))
        guard audio.data.starts(with: Data("RIFF".utf8)), audio.engine != nil else {
            throw ConsumerError("The helper returned invalid WAV metadata")
        }
        print("voice=\(voice.id) bytes=\(audio.data.count) engine=\(audio.engine!)")
    }
}

private struct ConsumerError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
