import Foundation
import XCTest
@testable import Say2Core

/// A prewarm failure used to be thrown away silently (#4769). These pin the
/// warning text a caller now sees, without loading the private framework.
final class PrewarmWarningTests: XCTestCase {
    func testSuccessGivesNoWarning() {
        XCTAssertNil(SiriEngine.prewarmWarning(for: .success(()), timeout: 30))
    }

    func testFailureNamesTheErrorAndSaysRenderingWentOn() {
        let error = NSError(
            domain: "SiriTTSService",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "engine not ready"]
        )
        XCTAssertEqual(
            SiriEngine.prewarmWarning(for: .failure(error), timeout: 30),
            "Siri prewarm failed: engine not ready; rendering went on"
        )
    }

    func testTimeoutNamesTheLimit() {
        XCTAssertEqual(
            SiriEngine.prewarmWarning(for: nil, timeout: 30),
            "Siri prewarm timed out after 30 s; rendering went on"
        )
    }

    func testPrewarmTextIsShortAndFixed() {
        // The prewarm before a render must not carry the caller's text (#4770).
        XCTAssertEqual(SiriEngine.prewarmText, "Siri TTS prewarm")
    }

    func testRenderedAudioHasNoWarningByDefault() {
        let audio = RenderedAudio(
            pcm: Data(),
            spec: AudioSpec.siriPCM,
            voice: VoiceInfo(name: "A", language: "en-US", assetKey: "k", version: 1, engine: "siri"),
            timings: [],
            timingsSupported: false,
            engine: .siri,
            elapsed: 0,
            timeToFirstAudio: nil
        )
        XCTAssertNil(audio.prewarmWarning)
    }
}
