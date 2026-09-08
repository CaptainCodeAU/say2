import Foundation
import XCTest
@testable import Say2Core

final class HTTPTests: XCTestCase {
    func testParsesRequestWithCaseInsensitiveHeaders() throws {
        let body = Data(#"{"model":"tts-1"}"#.utf8)
        let headers = "POST /v1/audio/speech HTTP/1.1\r\n" +
            "Host: localhost\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.count)\r\n\r\n"
        let requestData = Data(headers.utf8) + body
        let request = try HTTPParser.parse(requestData)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/audio/speech")
        XCTAssertEqual(request.headers["content-type"], "application/json")
        XCTAssertEqual(request.body, body)
    }

    func testRejectsIncorrectContentLength() {
        let data = Data(
            "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort".utf8
        )
        XCTAssertThrowsError(try HTTPParser.parse(data))
    }

    func testAcceptsRequestBodyLargerThanFormerOneMegabyteLimit() throws {
        let body = Data(repeating: 0x20, count: 1_100_000)
        let headers = "POST /v1/audio/speech HTTP/1.1\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.count)\r\n\r\n"

        let request = try HTTPParser.parse(Data(headers.utf8) + body)

        XCTAssertEqual(request.body.count, body.count)
    }

    func testRejectsEmptyAndDuplicateContentLength() {
        XCTAssertThrowsError(try HTTPParser.parse(Data(
            "POST / HTTP/1.1\r\nContent-Length:\r\n\r\n".utf8
        )))
        XCTAssertThrowsError(try HTTPParser.parse(Data(
            "POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8
        )))
    }

    func testDecodesOpenAIRequestShape() throws {
        let data = Data(
            """
            {
              "model": "tts-1",
              "input": "Hello",
              "voice": "Aaron",
              "response_format": "wav",
              "speed": 1.25
            }
            """.utf8
        )
        let value = try JSONDecoder().decode(SpeechAPIRequest.self, from: data)
        XCTAssertEqual(value.responseFormat, "wav")
        XCTAssertEqual(value.speed, 1.25)
    }

    func testRemoteBindGuardRequiresAllowRemoteForNonLoopbackHosts() {
        let error = SpeechServer.remoteBindError(host: "0.0.0.0", allowRemote: false)
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, .usage)
        XCTAssertTrue(error?.message.contains("--allow-remote") == true)

        XCTAssertNil(SpeechServer.remoteBindError(host: "0.0.0.0", allowRemote: true))
        XCTAssertNil(SpeechServer.remoteBindError(host: "192.168.1.5", allowRemote: true))
    }

    func testRemoteBindGuardNeverBlocksLoopbackHosts() {
        for host in ["127.0.0.1", "::1", "localhost"] {
            XCTAssertNil(SpeechServer.remoteBindError(host: host, allowRemote: false))
        }
    }

    func testInternalFailuresReturnGenericMessageButKnownFailuresDoNot() {
        let server = SpeechServer(options: ServeOptions(), coordinator: EngineCoordinator())

        let internalResponse = server.errorResponse(CLIError("posix error 13: permission denied at /private/secret", code: .internalFailure))
        let internalText = String(decoding: internalResponse, as: UTF8.self)
        XCTAssertTrue(internalText.hasPrefix("HTTP/1.1 500 Internal Server Error\r\n"))
        XCTAssertTrue(internalText.contains("Internal server error"))
        XCTAssertFalse(internalText.contains("permission denied"))
        XCTAssertFalse(internalText.contains("/private/secret"))

        let usageResponse = server.errorResponse(CLIError("response_format must be wav or pcm", code: .usage))
        let usageText = String(decoding: usageResponse, as: UTF8.self)
        XCTAssertTrue(usageText.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        XCTAssertTrue(usageText.contains("response_format must be wav or pcm"))
    }

    func testEndpointRejectsUnsupportedFormatWithValidHTTP() throws {
        let server = SpeechServer(options: ServeOptions(), coordinator: EngineCoordinator())
        let body = Data(
            #"{"model":"tts-1","input":"Hello","voice":"Aaron","response_format":"mp3"}"#.utf8
        )
        let response = try server.route(HTTPRequest(
            method: "POST",
            path: "/v1/audio/speech",
            headers: ["content-type": "application/json"],
            body: body
        ))
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        XCTAssertTrue(text.contains("\r\n\r\n"))
        XCTAssertTrue(text.contains("response_format must be wav or pcm"))
    }
}
