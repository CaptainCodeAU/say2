import Foundation

enum SiriVoicePreview {
    static let systemDirectory = URL(
        fileURLWithPath: "/System/Library/PrivateFrameworks/SiriTTSService.framework/Versions/A/Resources/VoicePreviews_AX",
        isDirectory: true
    )

    private static let assetStemAliases = [
        "com.apple.speech.synthesis.voice.custom.siri.hattori.premium": "hiro",
        "com.apple.speech.synthesis.voice.custom.siri.oren.premium": "sakura",
        "com.apple.speech.synthesis.voice.custom.siri.limu.premium": "limu",
    ]

    static func fileName(for voice: SiriDownloadableVoice) -> String {
        let stem = assetStemAliases[voice.catalogAssetKey] ?? voice.name.lowercased()
        return "\(voice.language)_\(stem)_AX.caf"
    }

    static func url(
        for voice: SiriDownloadableVoice,
        directory: URL = systemDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let expected = fileName(for: voice)
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw unavailable(voice, detail: "the VoicePreviews_AX directory could not be read")
        }
        guard let actual = names.first(where: {
            $0.caseInsensitiveCompare(expected) == .orderedSame
        }) else {
            throw unavailable(voice, detail: "\(expected) is absent")
        }
        let result = directory.appendingPathComponent(actual, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: result.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: result.path) else {
            throw unavailable(voice, detail: "\(actual) is not a readable file")
        }
        return result
    }

    private static func unavailable(
        _ voice: SiriDownloadableVoice,
        detail: String
    ) -> CLIError {
        CLIError(
            "Apple's local preview audio is unavailable for '\(voice.name)' on this macOS build: \(detail)",
            code: .noAudio
        )
    }
}
