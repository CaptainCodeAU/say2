import Foundation
import XCTest
@testable import SiriTTSCore

final class WordTimingTests: XCTestCase {
    func testMapsUTF16RangesAndDerivesEnds() throws {
        let text = "Hi 👋🏽 世界"
        let ns = text as NSString
        let hi = ns.range(of: "Hi")
        let emoji = ns.range(of: "👋🏽")
        let world = ns.range(of: "世界")
        let mapped = try WordTimingMapper.map([
            RawWordTiming(start: 0, range: hi),
            RawWordTiming(start: 0.4, range: emoji),
            RawWordTiming(start: 1.1, range: world),
        ], in: text, duration: 1.8)

        XCTAssertEqual(mapped.map(\.text), ["Hi", "👋🏽", "世界"])
        XCTAssertEqual(mapped[0].end, 0.4)
        XCTAssertEqual(mapped[1].end, 1.1)
        XCTAssertEqual(mapped[2].end, 1.8)
        XCTAssertEqual(mapped[1].utf16Length, emoji.length)
        XCTAssertTrue(mapped.allSatisfy(\.endDerived))
    }

    func testRejectsNonMonotonicInputInsteadOfReordering() {
        XCTAssertThrowsError(try WordTimingMapper.map([
            RawWordTiming(start: 1, range: NSRange(location: 2, length: 1)),
            RawWordTiming(start: 0, range: NSRange(location: 0, length: 1)),
        ], in: "a b", duration: 2))
    }

    func testRejectsOutOfBoundsUTF16Range() {
        XCTAssertThrowsError(try WordTimingMapper.map([
            RawWordTiming(start: 0, range: NSRange(location: 2, length: 10)),
        ], in: "hi", duration: 1))
    }

    func testRejectsTimingBeyondAudio() {
        XCTAssertThrowsError(try WordTimingMapper.map([
            RawWordTiming(start: 2, range: NSRange(location: 0, length: 2)),
        ], in: "hi", duration: 1))
    }

    func testSanitizePreservesValidEntriesAndDropsMalformedOnes() {
        let text = "Hi 👋🏽 world"
        let nsText = text as NSString
        let hi = nsText.range(of: "Hi")
        let emoji = nsText.range(of: "👋🏽")
        let world = nsText.range(of: "world")
        let sanitized = WordTimingMapper.sanitize([
            RawWordTiming(start: 0, range: hi),
            RawWordTiming(start: .nan, range: emoji),
            RawWordTiming(start: 0.4, range: emoji),
            RawWordTiming(start: 0.2, range: world),
            RawWordTiming(start: 0.9, range: world),
            RawWordTiming(start: 5, range: NSRange(location: 100, length: 2)),
        ], in: text, duration: 1.5)

        XCTAssertEqual(sanitized, [
            RawWordTiming(start: 0, range: hi),
            RawWordTiming(start: 0.4, range: emoji),
            RawWordTiming(start: 0.9, range: world),
        ])
        XCTAssertNoThrow(
            try WordTimingMapper.map(sanitized, in: text, duration: 1.5)
        )
    }

    func testSanitizeAllowsMissingTimings() {
        XCTAssertEqual(
            WordTimingMapper.sanitize([], in: "Valid audio", duration: 1),
            []
        )
    }
}
