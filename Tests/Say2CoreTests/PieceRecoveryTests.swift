import Foundation
import XCTest
@testable import Say2Core

/// Apple's voice sometimes fails one request partway, and that used to end the
/// whole reading with exit 5 (#4774). These pin the recovery: one retry, then
/// sentence by sentence, without loading the private framework.
final class PieceRecoveryTests: XCTestCase {
    private let voice = VoiceInfo(
        name: "Test", language: "en-US", assetKey: "test", version: 1, engine: "siri"
    )

    /// A stand-in for Siri: 0.1 s of non-silent audio per UTF-16 unit, one word
    /// timing covering the whole piece. `fail` decides, per call, whether to
    /// fail; `streamFirst` sends some audio out before failing.
    private final class FakeSiri: @unchecked Sendable {
        var calls: [String] = []
        var fail: (String, Int) -> CLIError? = { _, _ in nil }
        var streamBeforeFailing = false
        let voice: VoiceInfo

        init(voice: VoiceInfo) { self.voice = voice }

        func render(
            _ options: SynthesisOptions,
            _ onPCM: (@Sendable (Data) -> Void)?
        ) throws -> (audio: RenderedAudio, fallbackFrom: EngineKind?) {
            calls.append(options.text)
            let units = options.text.utf16.count
            let pcm = Data(repeating: 1, count: units * 4_800 * 2)
            if let error = fail(options.text, calls.count) {
                if streamBeforeFailing { onPCM?(pcm.prefix(20)) }
                throw error
            }
            onPCM?(pcm)
            return (
                RenderedAudio(
                    pcm: pcm,
                    spec: .siriPCM,
                    voice: voice,
                    timings: [RawWordTiming(start: 0, range: NSRange(location: 0, length: units))],
                    timingsSupported: true,
                    engine: .siri,
                    elapsed: 0,
                    timeToFirstAudio: 0
                ),
                nil
            )
        }
    }

    private let siriFault = CLIError("Siri synthesis failed: invalid value", code: .daemonUnreachable)

    private func run(
        _ text: String,
        _ fake: FakeSiri,
        streaming: Bool = false,
        pauses: inout [TimeInterval]
    ) throws -> (IncrementalSynthesisResult, Data) {
        var options = SynthesisOptions()
        options.text = text
        options.engine = .siri
        var sunk = Data()
        var paused: [TimeInterval] = []
        defer { pauses = paused }
        let result = try LongFormSynthesis.render(
            options,
            onProvisionalPCMChunk: streaming ? { @Sendable _ in } : nil,
            renderPiece: { try fake.render($0, $1) },
            pause: { paused.append($0) },
            sink: { sunk.append($0) }
        )
        return (result, sunk)
    }

    func testSentencesKeepEveryCharacter() {
        let text = "First one.  Second? Third!\nFourth line\n\nLast bit"
        let pieces = TextChunker.sentences(text)
        XCTAssertEqual(pieces.map(\.text), [
            "First one.  ", "Second? ", "Third!\n", "Fourth line\n\n", "Last bit",
        ])
        XCTAssertEqual(pieces.map(\.text).joined(), text)
        for piece in pieces {
            let start = text.utf16.index(text.utf16.startIndex, offsetBy: piece.utf16Location)
            let end = text.utf16.index(start, offsetBy: piece.text.utf16.count)
            XCTAssertEqual(String(text.utf16[start..<end]), piece.text)
        }
    }

    func testPunctuationOnlyPiecesJoinANeighbour() {
        XCTAssertEqual(TextChunker.sentences("Hello. ... World.").map(\.text), [
            "Hello. ... ", "World.",
        ])
        XCTAssertEqual(TextChunker.sentences("... Hello.").map(\.text), ["... Hello."])
        XCTAssertEqual(TextChunker.sentences("").map(\.text), [])
    }

    func testCleanRenderMakesNoRetryAndNoWarning() throws {
        let fake = FakeSiri(voice: voice)
        var pauses: [TimeInterval] = []
        let (result, _) = try run("One. Two.", fake, pauses: &pauses)
        XCTAssertEqual(fake.calls, ["One. Two."])
        XCTAssertTrue(pauses.isEmpty)
        XCTAssertTrue(result.recoveryWarnings.isEmpty)
    }

    func testOneFailureIsRetriedOnceAndTheAudioIsNotDoubled() throws {
        let fake = FakeSiri(voice: voice)
        fake.fail = { [siriFault] _, call in call == 1 ? siriFault : nil }
        var pauses: [TimeInterval] = []
        let (result, sunk) = try run("One. Two.", fake, pauses: &pauses)
        XCTAssertEqual(fake.calls, ["One. Two.", "One. Two."])
        XCTAssertEqual(pauses, [PieceRecovery.retryPause])
        XCTAssertEqual(sunk.count, "One. Two.".utf16.count * 9_600)
        XCTAssertEqual(result.recoveryWarnings.count, 1)
        XCTAssertTrue(result.recoveryWarnings[0].contains("tried it again and it worked"))
    }

    func testTwoFailuresFallBackToSentencesWithCorrectTimings() throws {
        let text = "One. Two. Three."
        let fake = FakeSiri(voice: voice)
        // The whole piece fails twice; then "Two. " fails once more.
        fake.fail = { [siriFault] piece, call in
            if piece == text { return siriFault }
            if piece == "Two. ", call == 4 { return siriFault }
            return nil
        }
        var pauses: [TimeInterval] = []
        let (result, sunk) = try run(text, fake, pauses: &pauses)
        XCTAssertEqual(fake.calls, [text, text, "One. ", "Two. ", "Two. ", "Three."])
        XCTAssertEqual(pauses.count, 2)
        XCTAssertEqual(sunk.count, text.utf16.count * 9_600)
        XCTAssertEqual(result.timings.map(\.range.location), [0, 5, 10])
        XCTAssertEqual(result.timings.map(\.start), [0, 0.5, 1.0])
        XCTAssertEqual(result.recoveryWarnings.count, 1)
        XCTAssertTrue(result.recoveryWarnings[0].contains("3 sentences, 1 needed a second try"))
    }

    func testASentenceFailingTwiceStillEndsWithExit5() {
        let fake = FakeSiri(voice: voice)
        fake.fail = { [siriFault] piece, _ in piece.hasPrefix("Two") || piece.count > 6 ? siriFault : nil }
        var pauses: [TimeInterval] = []
        XCTAssertThrowsError(try run("One. Two.", fake, pauses: &pauses)) { error in
            let error = error as? CLIError
            XCTAssertEqual(error?.code, .daemonUnreachable)
            XCTAssertTrue(error?.message.contains("sentence by sentence") == true)
        }
        XCTAssertEqual(fake.calls, ["One. Two.", "One. Two.", "One. ", "Two.", "Two."])
    }

    func testASingleSentenceFailingTwiceIsNotSplit() {
        let fake = FakeSiri(voice: voice)
        fake.fail = { [siriFault] _, _ in siriFault }
        var pauses: [TimeInterval] = []
        XCTAssertThrowsError(try run("Only one sentence", fake, pauses: &pauses)) { error in
            XCTAssertEqual((error as? CLIError)?.code, .daemonUnreachable)
            XCTAssertTrue((error as? CLIError)?.message.contains("after one retry") == true)
        }
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testFailuresARetryCannotFixAreNotRetried() {
        let fake = FakeSiri(voice: voice)
        fake.fail = { _, _ in CLIError("Voice not found", code: .voiceNotFound) }
        var pauses: [TimeInterval] = []
        XCTAssertThrowsError(try run("One. Two.", fake, pauses: &pauses)) { error in
            XCTAssertEqual((error as? CLIError)?.code, .voiceNotFound)
            XCTAssertEqual((error as? CLIError)?.message, "Voice not found")
        }
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(pauses.isEmpty)
    }

    func testStreamedAudioIsNeverRepeated() {
        let fake = FakeSiri(voice: voice)
        fake.fail = { [siriFault] _, call in call == 1 ? siriFault : nil }
        fake.streamBeforeFailing = true
        var pauses: [TimeInterval] = []
        XCTAssertThrowsError(try run("One. Two.", fake, streaming: true, pauses: &pauses)) { error in
            XCTAssertEqual((error as? CLIError)?.code, .daemonUnreachable)
        }
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testStreamingRetriesWhenNothingWentOut() throws {
        let fake = FakeSiri(voice: voice)
        fake.fail = { [siriFault] _, call in call == 1 ? siriFault : nil }
        var pauses: [TimeInterval] = []
        let (result, _) = try run("One. Two.", fake, streaming: true, pauses: &pauses)
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertEqual(result.recoveryWarnings.count, 1)
    }
}
