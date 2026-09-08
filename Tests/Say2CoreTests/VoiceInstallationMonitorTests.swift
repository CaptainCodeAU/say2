import XCTest
@testable import Say2Core

final class VoiceInstallationMonitorTests: XCTestCase {
    func testPollReturnsInstalledVoice() throws {
        let voice = VoiceInfo(
            name: "Aaron",
            language: "en-US",
            assetKey: "aaron-key",
            version: 1,
            engine: "siri"
        )
        var clock: TimeInterval = 10
        var fetches = 0
        var states: [VoiceInstallationState] = []

        let result = try VoiceInstallationMonitor.poll(
            identifier: "Aaron",
            assetKey: voice.assetKey,
            timeout: 20,
            pollInterval: 2,
            now: { clock },
            sleep: { clock += $0 },
            onUpdate: { states.append($0.state) },
            fetchInstalled: {
                fetches += 1
                return fetches >= 3 ? [voice] : []
            }
        )

        XCTAssertEqual(result.state, .installed)
        XCTAssertEqual(result.voice, voice)
        XCTAssertEqual(result.elapsedSeconds, 4)
        XCTAssertEqual(fetches, 3)
        XCTAssertEqual(states, [.waiting, .waiting, .installed])
    }

    func testPollTimeoutDoesNotClaimFailureOrInstallation() throws {
        var clock: TimeInterval = 100
        let result = try VoiceInstallationMonitor.poll(
            identifier: "Missing",
            assetKey: "missing-key",
            timeout: 5,
            pollInterval: 2,
            now: { clock },
            sleep: { clock += $0 },
            fetchInstalled: { [] }
        )

        XCTAssertEqual(result.state, .timedOut)
        XCTAssertNil(result.voice)
        XCTAssertEqual(result.elapsedSeconds, 5)
    }

    func testPollMatchesStableAssetKeyNotDisplayName() throws {
        let wrong = VoiceInfo(
            name: "Requested Name",
            language: "en-US",
            assetKey: "other-key",
            version: 1,
            engine: "siri"
        )
        var clock: TimeInterval = 0
        let result = try VoiceInstallationMonitor.poll(
            identifier: "Requested Name",
            assetKey: "wanted-key",
            timeout: 1,
            pollInterval: 1,
            now: { clock },
            sleep: { clock += $0 },
            fetchInstalled: { [wrong] }
        )

        XCTAssertEqual(result.state, .timedOut)
    }

    func testPollCanBeCancelledWithoutPoisoningAResult() {
        var cancelled = false
        XCTAssertThrowsError(try VoiceInstallationMonitor.poll(
            identifier: "Voice",
            assetKey: "voice-key",
            timeout: 10,
            pollInterval: 1,
            sleep: { _ in cancelled = true },
            isCancelled: { cancelled },
            fetchInstalled: { [] }
        )) {
            XCTAssertEqual(($0 as? CLIError)?.code, .cancelled)
        }
    }
}
