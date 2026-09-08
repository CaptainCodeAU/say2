import XCTest
@testable import Say2Core

final class CLIParserTests: XCTestCase {
    func testDefaultInvocationIsSynthesis() throws {
        guard case .synthesize(let options) = try CLIParser.parse(["Hello", "world"]) else {
            return XCTFail("Expected synthesis")
        }
        XCTAssertEqual(options.text, "Hello world")
        XCTAssertEqual(options.engine, .siri)
        XCTAssertEqual(options.format, .wav)
    }

    func testNativeSynthesisOptions() throws {
        guard case .synthesize(let options) = try CLIParser.parse([
            "synthesize", "--voice", "Aaron", "--language", "en-US",
            "--rate", "1.25", "--pitch", "0.8", "--volume", "0.7",
            "--engine", "auto", "--format", "pcm", "-o", "out.pcm", "Hi",
        ]) else {
            return XCTFail("Expected synthesis")
        }
        XCTAssertEqual(options.voice, "Aaron")
        XCTAssertEqual(options.language, "en-US")
        XCTAssertEqual(options.rate, 1.25)
        XCTAssertEqual(options.pitch, 0.8)
        XCTAssertEqual(options.volume, 0.7)
        XCTAssertEqual(options.engine, .auto)
        XCTAssertEqual(options.output, "out.pcm")
    }

    func testSayWPMConversion() throws {
        let normal = try CLIParser.parseSynthesis(["-r", "175", "Text"])
        let double = try CLIParser.parseSynthesis(["-r", "350", "Text"])
        XCTAssertEqual(normal.rate, 1, accuracy: 0.0001)
        XCTAssertEqual(double.rate, 2, accuracy: 0.0001)
    }

    func testSayFileOptions() throws {
        let options = try CLIParser.parseSynthesis([
            "--file-format", "WAVE", "--data-format", "LEI16@48000",
            "--quality", "127", "Text",
        ])
        XCTAssertEqual(options.format, .wav)
    }

    func testLongEqualsSyntax() throws {
        let options = try CLIParser.parseSynthesis([
            "--voice=Aaron", "--format=pcm", "-o", "out.pcm", "Text",
        ])
        XCTAssertEqual(options.voice, "Aaron")
        XCTAssertEqual(options.format, .pcm)
    }

    func testSayQuestionMarkListsVoices() throws {
        guard case .voices = try CLIParser.parse(["-v", "?"]) else {
            return XCTFail("Expected voices")
        }
    }

    func testEndOfOptionsAllowsHyphenText() throws {
        let options = try CLIParser.parseSynthesis(["--", "-not-a-flag"])
        XCTAssertEqual(options.text, "-not-a-flag")
    }

    func testUnknownOptionFailsAsUsage() {
        XCTAssertThrowsError(try CLIParser.parseSynthesis(["--bogus", "Text"])) {
            XCTAssertEqual(($0 as? CLIError)?.code, .usage)
        }
    }

    func testStdoutRequiresPCM() {
        XCTAssertThrowsError(try CLIParser.parseSynthesis(["-o", "-", "Text"]))
    }

    func testStdoutRejectsAutoFallbackToAvoidMixedAudio() {
        XCTAssertThrowsError(
            try CLIParser.parseSynthesis([
                "--engine", "auto", "--format", "pcm", "-o", "-", "Text",
            ])
        )
    }

    func testInputFileAndTextAreMutuallyExclusive() {
        XCTAssertThrowsError(try CLIParser.parseSynthesis(["-f", "input.txt", "Text"]))
    }

    func testVoiceInstallParsing() throws {
        guard case .voices(let options) = try CLIParser.parse(["voices", "--install", "Aaron"]) else {
            return XCTFail("Expected voices")
        }
        XCTAssertEqual(options.install, "Aaron")
    }

    func testVoiceInstallWaitParsing() throws {
        guard case .voices(let options) = try CLIParser.parse([
            "voices", "--install", "Aaron", "--wait", "--timeout", "45", "--json",
        ]) else {
            return XCTFail("Expected voices")
        }
        XCTAssertEqual(options.install, "Aaron")
        XCTAssertTrue(options.wait)
        XCTAssertEqual(options.timeout, 45)
        XCTAssertTrue(options.json)
    }

    func testVoiceStatusParsing() throws {
        guard case .voices(let options) = try CLIParser.parse([
            "voices", "--status", "com.apple.voice.compact.en-US.Aaron",
        ]) else {
            return XCTFail("Expected voices")
        }
        XCTAssertEqual(options.status, "com.apple.voice.compact.en-US.Aaron")
    }

    func testVoicePurgeParsingAcceptsDisplayNameAndTimeout() throws {
        guard case .voices(let options) = try CLIParser.parse([
            "voices", "--purge", "Damon", "--timeout", "45", "--json",
        ]) else {
            return XCTFail("Expected voices")
        }
        XCTAssertEqual(options.purge, "Damon")
        XCTAssertEqual(options.timeout, 45)
        XCTAssertTrue(options.json)
        XCTAssertThrowsError(try CLIParser.parse([
            "voices", "--purge", "Damon", "--timeout", "301",
        ]))
    }

    func testVoiceManageParsing() throws {
        guard case .voices(let options) = try CLIParser.parse(["voices", "--manage"]) else {
            return XCTFail("Expected voices")
        }
        XCTAssertTrue(options.manage)
    }

    func testVoiceWaitRequiresInstall() {
        XCTAssertThrowsError(try CLIParser.parse(["voices", "--wait"]))
        XCTAssertThrowsError(try CLIParser.parse(["voices", "--timeout", "300"]))
        XCTAssertThrowsError(try CLIParser.parse([
            "voices", "--install", "Aaron", "--timeout", "30",
        ]))
    }

    func testVoiceActionsAreMutuallyExclusive() {
        XCTAssertThrowsError(try CLIParser.parse([
            "voices", "--install", "Aaron", "--status", "Aaron",
        ]))
        XCTAssertThrowsError(try CLIParser.parse([
            "voices", "--manage", "--available",
        ]))
        XCTAssertThrowsError(try CLIParser.parse([
            "voices", "--purge", "Damon", "--install", "Damon",
        ]))
    }

    func testSystemSettingsDeepLinkTargetsAccessibility() {
        XCTAssertEqual(SystemVoiceSettings.url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(SystemVoiceSettings.url.absoluteString.contains("Accessibility"))
    }

    func testServeValidation() {
        XCTAssertThrowsError(try CLIParser.parse(["serve", "--port", "0"]))
        XCTAssertThrowsError(try CLIParser.parse(["serve", "--engine", "cloud"]))
    }

}
