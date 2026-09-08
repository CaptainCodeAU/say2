import XCTest
@testable import Say2Core

final class SiriDownloadableVoiceCatalogTests: XCTestCase {
    func testPreferredVoicesSelectsOnePremiumPlatformPreferredGeneration() throws {
        let rows = [
            metadata(technology: "neural", desirability: 23_800),
            metadata(technology: "natural", desirability: 23_900),
            metadata(
                identifier: "compact",
                quality: "compact",
                technology: "neural",
                desirability: 99_999
            ),
        ]

        let voices = SiriDownloadableVoiceCatalog.preferredVoices(from: rows)

        XCTAssertEqual(voices.count, 1)
        XCTAssertEqual(voices[0].catalogAssetKey, "catalog-aaron")
        XCTAssertEqual(voices[0].technology, "natural")
        XCTAssertEqual(
            voices[0].nativeAssetKey,
            "en-US:natural:male:Aaron:premium:0"
        )
        let olderGeneration = try SiriDownloadableVoiceCatalog.preferredVoices(from: [
            metadata(technology: "neural", desirability: 23_800),
        ])[0].makeSynthesisVoice()
        XCTAssertTrue(voices[0].matchesInstalled(olderGeneration))
    }

    func testStableCatalogIdentityDoesNotContainMutableContentVersion() {
        let before = SiriDownloadableVoiceCatalog.preferredVoices(from: [
            metadata(version: 0, locallyAvailable: false),
        ])[0]
        let after = SiriDownloadableVoiceCatalog.preferredVoices(from: [
            metadata(version: 5_030, locallyAvailable: true),
        ])[0]

        XCTAssertEqual(before.catalogAssetKey, after.catalogAssetKey)
        XCTAssertNotEqual(before.nativeAssetKey, after.nativeAssetKey)
    }

    func testConstructedSubscriptionVoiceMatchesInstalledVersion() throws {
        let catalogVoice = SiriDownloadableVoiceCatalog.preferredVoices(from: [
            metadata(version: 0),
        ])[0]
        let nativeVoice = try catalogVoice.makeSynthesisVoice()
        XCTAssertEqual(nativeVoice.assetKey, "en-US:natural:male:Aaron:premium:0")

        nativeVoice.version = 5_030
        XCTAssertTrue(catalogVoice.matchesInstalled(nativeVoice))
    }

    func testPreferredVoicesRejectsIncompleteOrUnsupportedRows() {
        let rows = [
            metadata(identifier: "", technology: "natural"),
            metadata(identifier: "unknown", technology: "future-engine"),
            metadata(identifier: "bad-gender", gender: 9),
            metadata(identifier: "not-downloadable", downloadSize: 0),
        ]

        XCTAssertTrue(SiriDownloadableVoiceCatalog.preferredVoices(from: rows).isEmpty)
    }

    func testResolvePrefersStableIdentityAndRejectsAmbiguousDisplayName() throws {
        let voices = SiriDownloadableVoiceCatalog.preferredVoices(from: [
            metadata(identifier: "catalog-aaron", language: "en-US"),
            metadata(identifier: "catalog-aaron-other", language: "en-GB"),
        ])

        XCTAssertEqual(
            try SiriDownloadableVoiceCatalog.resolve("catalog-aaron", in: voices)?.language,
            "en-US"
        )
        XCTAssertThrowsError(try SiriDownloadableVoiceCatalog.resolve("Aaron", in: voices)) {
            XCTAssertEqual(($0 as? CLIError)?.code, .voiceNotFound)
        }
        XCTAssertNil(try SiriDownloadableVoiceCatalog.resolve(
            "Aaron",
            in: voices,
            allowDisplayName: false
        ))
    }

    func testPurgeCandidateRequiresExactInstalledGeneration() throws {
        let rows = [
            metadata(technology: "neural", version: 0, locallyAvailable: false),
            metadata(technology: "natural", version: 5_030, locallyAvailable: true),
        ]

        let index = try SiriDownloadableVoiceCatalog.exactPurgeCandidateIndex(
            catalogAssetKey: "catalog-aaron",
            installedNativeAssetKey: "en-US:natural:male:Aaron:premium:5030",
            metadata: rows
        )

        XCTAssertEqual(index, 1)
        XCTAssertTrue(rows[index].locallyAvailable)
    }

    func testPurgeCandidateRefusesMissingOrAmbiguousGeneration() {
        let exact = metadata(technology: "natural", version: 5_030, locallyAvailable: true)
        XCTAssertThrowsError(try SiriDownloadableVoiceCatalog.exactPurgeCandidateIndex(
            catalogAssetKey: "catalog-aaron",
            installedNativeAssetKey: "en-US:natural:male:Aaron:premium:5029",
            metadata: [exact]
        ))
        XCTAssertThrowsError(try SiriDownloadableVoiceCatalog.exactPurgeCandidateIndex(
            catalogAssetKey: "catalog-aaron",
            installedNativeAssetKey: "en-US:natural:male:Aaron:premium:5030",
            metadata: [exact, exact]
        ))
    }

    func testPurgeResultKeepsPhysicalAvailabilityExplicit() {
        let result = VoicePurgeResult(
            assetKey: "catalog-aaron",
            nativeAssetKey: "en-US:natural:male:Aaron:premium:5030",
            name: "Aaron",
            language: "en-US",
            status: .localAssetStillAvailable,
            localAssetAvailableAfterPurge: true
        )

        XCTAssertTrue(result.localAssetAvailableAfterPurge)
        XCTAssertEqual(result.status.rawValue, "local-asset-still-available")
    }

    func testUAFAssetSpecifierUsesExactCatalogIdentity() {
        XCTAssertEqual(
            SiriDownloadableVoiceCatalog.uafAssetSpecifier(for: metadata(
                technology: "natural",
                language: "en-IE"
            )),
            "com.apple.siri.tts.voice.en_IE.aaron.natural.premium"
        )
    }

    func testDeletedBundleOverridesStaleReportedAvailability() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        XCTAssertFalse(SiriDownloadableVoiceCatalog.effectiveLocalAvailability(
            reported: true,
            localBundlePath: missingPath
        ))
        XCTAssertFalse(SiriDownloadableVoiceCatalog.effectiveLocalAvailability(
            reported: false,
            localBundlePath: nil
        ))
        XCTAssertTrue(SiriDownloadableVoiceCatalog.effectiveLocalAvailability(
            reported: true,
            localBundlePath: nil
        ))
    }

    func testFilesystemStateOverridesStaleCatalogVersionAndAvailability() {
        let row = metadata(version: 5_128, locallyAvailable: true)
        let specifier = SiriDownloadableVoiceCatalog.uafAssetSpecifier(for: row)
        let absent = SiriDownloadableVoiceCatalog.applyingLocalState(
            to: row,
            states: [:]
        )
        let present = SiriDownloadableVoiceCatalog.applyingLocalState(
            to: metadata(version: 0, locallyAvailable: false),
            states: [specifier: SiriUAFLocalAssetState(
                contentVersion: 5_030,
                assetDataPath: "/System/Library/AssetsV2/example.asset/AssetData"
            )]
        )

        XCTAssertFalse(absent.locallyAvailable)
        XCTAssertEqual(absent.version, 0)
        XCTAssertTrue(present.locallyAvailable)
        XCTAssertEqual(present.version, 5_030)
    }

    func testInstalledFilterRejectsMatchedStaleDaemonRowsButKeepsCompatibleUnknownRows() throws {
        let missing = SiriDownloadableVoiceCatalog.preferredVoices(from: [
            metadata(version: 5_030, locallyAvailable: false),
        ])[0]
        let present = SiriDownloadableVoiceCatalog.preferredVoices(from: [
            metadata(
                identifier: "catalog-tara",
                language: "en-IN",
                version: 1_029,
                locallyAvailable: true
            ),
        ])[0]
        let staleNative = try missing.makeSynthesisVoice()
        let presentNative = try present.makeSynthesisVoice()
        let unknownNative = try SiriDownloadableVoiceCatalog.preferredVoices(from: [
            metadata(
                identifier: "catalog-future",
                language: "fr-FR",
                version: 9_999,
                locallyAvailable: true
            ),
        ])[0].makeSynthesisVoice()

        let filtered = SiriDownloadableVoiceCatalog.filterLocallyInstalled(
            [staleNative, presentNative, unknownNative],
            against: [missing, present]
        )

        XCTAssertEqual(filtered.map(\.assetKey), [
            presentNative.assetKey,
            unknownNative.assetKey,
        ])
    }

    private func metadata(
        identifier: String = "catalog-aaron",
        quality: String = "premium",
        technology: String = "natural",
        language: String = "en-US",
        gender: Int = 1,
        version: Int = 0,
        desirability: Int = 23_900,
        locallyAvailable: Bool = false,
        downloadSize: Int = 100_000_000
    ) -> SiriCatalogAssetMetadata {
        SiriCatalogAssetMetadata(
            identifier: identifier,
            name: "Aaron",
            language: language,
            technology: technology,
            gender: gender,
            quality: quality,
            version: version,
            relativeDesirability: desirability,
            locallyAvailable: locallyAvailable,
            downloadSize: downloadSize
        )
    }
}
