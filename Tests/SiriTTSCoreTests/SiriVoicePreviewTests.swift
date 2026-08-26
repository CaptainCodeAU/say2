import Foundation
import XCTest
@testable import SiriTTSCore

final class SiriVoicePreviewTests: XCTestCase {
    func testOrdinaryPreviewNameUsesLanguageAndLowercaseVoiceName() {
        XCTAssertEqual(
            SiriVoicePreview.fileName(for: voice(
                key: "com.apple.speech.synthesis.voice.custom.siri.damon.premium",
                name: "Damon",
                language: "en-US"
            )),
            "en-US_damon_AX.caf"
        )
    }

    func testLookupReturnsExistingLocalFileWithoutCopyingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = directory.appendingPathComponent("en-US_damon_AX.caf")
        XCTAssertTrue(FileManager.default.createFile(atPath: expected.path, contents: Data([0])))

        let resolved = try SiriVoicePreview.url(for: voice(
            key: "com.apple.speech.synthesis.voice.custom.siri.damon.premium",
            name: "Damon",
            language: "en-US"
        ), directory: directory)

        XCTAssertEqual(resolved.standardizedFileURL, expected.standardizedFileURL)
    }

    private func voice(key: String, name: String, language: String) -> SiriDownloadableVoice {
        SiriDownloadableVoice(
            catalogAssetKey: key,
            name: name,
            language: language,
            technology: "natural",
            gender: 1,
            version: 0,
            relativeDesirability: 1,
            locallyAvailable: false,
            downloadSize: 1,
            matchingNativeIdentityPrefixes: []
        )
    }
}
