import Foundation
import XCTest
@testable import Say2Client

final class Say2ClientTests: XCTestCase {
    func testListsVoicesFromHelper() async throws {
        let client = Say2Client(
            configuration: .init(baseURL: URL(string: "http://127.0.0.1:9000")!),
            transport: { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/v1/models")
                return (
                    Data(#"{"object":"list","data":[{"id":"Aaron","object":"model","owned_by":"local-macos"}]}"#.utf8),
                    Self.response(for: request, contentType: "application/json")
                )
            }
        )

        let voices = try await client.voices()

        XCTAssertEqual(voices, [
            .init(id: "Aaron", object: "model", ownedBy: "local-macos"),
        ])
    }

    func testSynthesizesWAVAndReportsSelectedEngine() async throws {
        let expectedAudio = Data([0x52, 0x49, 0x46, 0x46])
        let client = Say2Client(
            configuration: .init(baseURL: URL(string: "http://localhost:8080")!),
            transport: { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/v1/audio/speech")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(json["input"] as? String, "Hello")
                XCTAssertEqual(json["voice"] as? String, "Aaron")
                XCTAssertEqual(json["response_format"] as? String, "wav")
                XCTAssertEqual(json["speed"] as? Double, 1.25)
                return (
                    expectedAudio,
                    Self.response(
                        for: request,
                        contentType: "audio/wav",
                        headers: ["X-Say2-Engine": "siri"]
                    )
                )
            }
        )

        let audio = try await client.synthesize(.init(
            text: "Hello",
            voice: "Aaron",
            speed: 1.25
        ))

        XCTAssertEqual(audio.data, expectedAudio)
        XCTAssertEqual(audio.format, .wav)
        XCTAssertEqual(audio.engine, "siri")
    }

    func testLongAudioCanDownloadDirectlyToAFile() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "say2ent-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let downloaded = temporaryDirectory.appendingPathComponent("session-download")
        let destination = temporaryDirectory.appendingPathComponent("speech.wav")
        let expectedAudio = Data("RIFF long audio".utf8)
        try expectedAudio.write(to: downloaded)

        let client = Say2Client(
            configuration: .init(baseURL: URL(string: "http://localhost:8080")!),
            transport: { _ in throw Say2Client.ClientError.invalidResponse },
            downloadTransport: { request in
                (
                    downloaded,
                    Self.response(
                        for: request,
                        contentType: "audio/wav",
                        headers: ["X-Say2-Engine": "av"]
                    )
                )
            }
        )

        let audio = try await client.synthesize(
            .init(text: String(repeating: "Long input. ", count: 10_000), voice: "Aaron"),
            to: destination
        )

        XCTAssertEqual(try Data(contentsOf: destination), expectedAudio)
        XCTAssertEqual(audio.url, destination)
        XCTAssertEqual(audio.byteCount, Int64(expectedAudio.count))
        XCTAssertEqual(audio.engine, "av")
    }

    func testSurfacesHelperErrorMessage() async throws {
        let client = Say2Client(
            configuration: .init(),
            transport: { request in
                (
                    Data(#"{"error":{"message":"Voice not found"}}"#.utf8),
                    Self.response(
                        for: request,
                        statusCode: 400,
                        contentType: "application/json"
                    )
                )
            }
        )

        do {
            _ = try await client.synthesize(.init(text: "Hello", voice: "Missing"))
            XCTFail("Expected helper error")
        } catch let error as Say2Client.ClientError {
            XCTAssertEqual(error, .server(statusCode: 400, message: "Voice not found"))
        }
    }

    func testRejectsInvalidConfigurationBeforeTransport() async {
        let client = Say2Client(
            configuration: .init(baseURL: URL(fileURLWithPath: "/tmp")),
            transport: { _ in
                XCTFail("Transport should not be called")
                throw Say2Client.ClientError.invalidResponse
            }
        )

        do {
            _ = try await client.voices()
            XCTFail("Expected configuration error")
        } catch let error as Say2Client.ClientError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        contentType: String,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        var fields = headers
        fields["Content-Type"] = contentType
        return HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        )!
    }
}
