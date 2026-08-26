import XCTest
@testable import SiriTTSCore

final class AudioTests: XCTestCase {
    func testWAVHeaderAndPayload() throws {
        let pcm = pcmFixture(frames: 4_800)
        let wav = try AudioIO.makeWAV(pcm: pcm, spec: .siriPCM)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(wav.count, pcm.count + 44)
        XCTAssertEqual(readUInt32(wav, at: 24), 48_000)
        XCTAssertEqual(readUInt16(wav, at: 22), 1)
        XCTAssertEqual(readUInt16(wav, at: 34), 16)
        XCTAssertEqual(readUInt32(wav, at: 40), UInt32(pcm.count))
        XCTAssertEqual(Data(wav.dropFirst(44)), pcm)
    }

    func testPCMValidationComputesMetrics() throws {
        let pcm = pcmFixture(frames: 4_800)
        let result = try AudioIO.validatePCM(pcm, spec: .siriPCM, text: "hello")
        XCTAssertEqual(result.durationSeconds, 0.1, accuracy: 0.00001)
        XCTAssertEqual(result.sampleCount, 4_800)
        XCTAssertTrue(result.nonSilent)
    }

    func testPCMValidationRejectsSilence() {
        XCTAssertThrowsError(
            try AudioIO.validatePCM(
                Data(repeating: 0, count: 9_600),
                spec: .siriPCM,
                text: "hello"
            )
        )
    }

    func testPCMValidationRejectsPartialFrame() {
        XCTAssertThrowsError(
            try AudioIO.validatePCM(Data([1]), spec: .siriPCM, text: "hello")
        )
    }

    func testPCMValidationRejectsImplausiblyShortChapter() {
        let pcm = pcmFixture(frames: 4_800)
        XCTAssertThrowsError(
            try AudioIO.validatePCM(
                pcm,
                spec: .siriPCM,
                text: String(repeating: "chapter ", count: 1_000)
            )
        )
    }

    func testPCMValidationDoesNotTreatWhitespaceAsSpokenText() throws {
        let pcm = pcmFixture(frames: 4_800)
        let result = try AudioIO.validatePCM(
            pcm,
            spec: .siriPCM,
            text: String(repeating: " ", count: 10_000) + "Hello"
        )

        XCTAssertGreaterThanOrEqual(result.durationSeconds, 0.1)
    }

    private func pcmFixture(frames: Int) -> Data {
        var result = Data(capacity: frames * 2)
        for index in 0..<frames {
            var sample = Int16(sin(Double(index) / 10) * 12_000).littleEndian
            withUnsafeBytes(of: &sample) { result.append(contentsOf: $0) }
        }
        return result
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        UInt32(data[offset + 1]) << 8 |
        UInt32(data[offset + 2]) << 16 |
        UInt32(data[offset + 3]) << 24
    }
}
