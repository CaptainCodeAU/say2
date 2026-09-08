import XCTest
@testable import Say2Core

final class LongFormSynthesisTests: XCTestCase {
    func testChunkerPreservesTextAndUTF16Locations() {
        let text = String(repeating: "Hello 👋🏽 world. ", count: 200)
        let chunks = TextChunker.chunks(text, byteLimit: 97)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        var expectedLocation = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.utf16Location, expectedLocation)
            XCTAssertFalse(chunk.text.isEmpty)
            expectedLocation += chunk.text.utf16.count
        }
    }

    func testChunkerPrefersNaturalBoundaries() {
        let text = "One short sentence. Two short sentences. Three."
        let chunks = TextChunker.chunks(text, byteLimit: 24)

        XCTAssertEqual(chunks.map(\.text).joined(), text)
        XCTAssertTrue(chunks.dropLast().allSatisfy {
            $0.text.last?.isWhitespace == true || ".!?;:".contains($0.text.last!)
        })
    }

    func testChunkerDoesNotSplitExtendedGraphemes() {
        let family = "👨‍👩‍👧‍👦"
        let chunks = TextChunker.chunks(family + family, byteLimit: 1)

        XCTAssertEqual(chunks.map(\.text), [family, family])
    }
}
