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
