import Foundation

/// A lightweight client for a separately running `say2 serve` helper.
///
/// This module deliberately does not link Apple's private speech framework into
/// the host application. The helper owns that compatibility boundary and exposes
/// the repository's versioned local HTTP interface instead.
public struct Say2Client: Sendable {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var timeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
            timeout: TimeInterval = 86_400
        ) {
            self.baseURL = baseURL
            self.timeout = timeout
        }
    }

    public struct Voice: Codable, Equatable, Sendable {
        public let id: String
        public let object: String
        public let ownedBy: String

        enum CodingKeys: String, CodingKey {
            case id, object
            case ownedBy = "owned_by"
        }
    }

    public enum AudioFormat: String, Codable, CaseIterable, Sendable {
        case wav
        case pcm
    }

    public struct SynthesisRequest: Equatable, Sendable {
        public var text: String
        public var voice: String
        public var format: AudioFormat
        public var speed: Double
        public var model: String

        public init(
            text: String,
            voice: String,
            format: AudioFormat = .wav,
            speed: Double = 1,
            model: String = "tts-1"
        ) {
            self.text = text
            self.voice = voice
            self.format = format
            self.speed = speed
            self.model = model
        }
    }

    public struct SynthesizedAudio: Equatable, Sendable {
        public let data: Data
        public let format: AudioFormat
        public let contentType: String
        public let engine: String?

        public init(
            data: Data,
            format: AudioFormat,
            contentType: String,
            engine: String?
        ) {
            self.data = data
            self.format = format
            self.contentType = contentType
            self.engine = engine
        }
    }

    /// Metadata for audio saved without first loading the response into memory.
    public struct SynthesizedAudioFile: Equatable, Sendable {
        public let url: URL
        public let format: AudioFormat
        public let contentType: String
        public let engine: String?
        public let byteCount: Int64

        public init(
            url: URL,
            format: AudioFormat,
            contentType: String,
            engine: String?,
            byteCount: Int64
        ) {
            self.url = url
            self.format = format
            self.contentType = contentType
            self.engine = engine
            self.byteCount = byteCount
        }
    }

    public enum ClientError: LocalizedError, Equatable, Sendable {
        case invalidConfiguration(String)
        case invalidResponse
        case server(statusCode: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let message):
                message
            case .invalidResponse:
                "The say2 helper returned an invalid HTTP response"
            case .server(let statusCode, let message):
                "say2 helper returned HTTP \(statusCode): \(message)"
            }
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [Voice]
    }

    private struct ServerErrorResponse: Decodable {
        struct Detail: Decodable {
            let message: String
        }

        let error: Detail
    }

    private struct WireSynthesisRequest: Encodable {
        let model: String
        let input: String
        let voice: String
        let responseFormat: String
        let speed: Double

        enum CodingKeys: String, CodingKey {
            case model, input, voice, speed
            case responseFormat = "response_format"
        }
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias DownloadTransport = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    private let configuration: Configuration
    private let transport: Transport
    private let downloadTransport: DownloadTransport

    public init(
        configuration: Configuration = Configuration(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.transport = { request in
            try await session.data(for: request)
        }
        self.downloadTransport = { request in
            try await session.download(for: request)
        }
    }

    init(
        configuration: Configuration,
        transport: @escaping Transport,
        downloadTransport: @escaping DownloadTransport = { _ in
            throw ClientError.invalidResponse
        }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.downloadTransport = downloadTransport
    }

    public func voices() async throws -> [Voice] {
        let request = try makeRequest(path: ["v1", "models"])
        let (data, response) = try await transport(request)
        let http = try validate(response, data: data)
        guard http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("application/json") == true else {
            throw ClientError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(ModelsResponse.self, from: data).data
        } catch {
            throw ClientError.invalidResponse
        }
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        let urlRequest = try makeSynthesisRequest(request)
        let (data, response) = try await transport(urlRequest)
        let http = try validate(response, data: data)
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let expectedType = request.format == .wav ? "audio/wav" : "application/octet-stream"
        guard contentType.lowercased().contains(expectedType), !data.isEmpty else {
            throw ClientError.invalidResponse
        }
        return SynthesizedAudio(
            data: data,
            format: request.format,
            contentType: contentType,
            engine: http.value(forHTTPHeaderField: "X-Say2-Engine")
        )
    }

    /// Saves a response to disk without retaining the complete audio payload in memory.
    /// Prefer this method for books, articles, and other long input.
    public func synthesize(
        _ request: SynthesisRequest,
        to destination: URL
    ) async throws -> SynthesizedAudioFile {
        let urlRequest = try makeSynthesisRequest(request)
        let (downloadedURL, response) = try await downloadTransport(urlRequest)
        let http: HTTPURLResponse
        if let candidate = response as? HTTPURLResponse,
           !(200...299).contains(candidate.statusCode) {
            let errorData = (try? Data(contentsOf: downloadedURL)) ?? Data()
            _ = try validate(response, data: errorData)
            throw ClientError.invalidResponse
        } else {
            http = try validate(response, data: Data())
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let expectedType = request.format == .wav ? "audio/wav" : "application/octet-stream"
        let byteCount = try downloadedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard contentType.lowercased().contains(expectedType), byteCount > 0 else {
            throw ClientError.invalidResponse
        }
        try installDownloadedFile(downloadedURL, at: destination)
        return SynthesizedAudioFile(
            url: destination,
            format: request.format,
            contentType: contentType,
            engine: http.value(forHTTPHeaderField: "X-Say2-Engine"),
            byteCount: Int64(byteCount)
        )
    }

    private func makeSynthesisRequest(_ request: SynthesisRequest) throws -> URLRequest {
        let body = WireSynthesisRequest(
            model: request.model,
            input: request.text,
            voice: request.voice,
            responseFormat: request.format.rawValue,
            speed: request.speed
        )
        var urlRequest = try makeRequest(path: ["v1", "audio", "speech"])
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    private func installDownloadedFile(_ source: URL, at destination: URL) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard manager.fileExists(atPath: parent.path) else {
            throw ClientError.invalidConfiguration("The output folder does not exist")
        }
        let staging = parent.appendingPathComponent(
            ".say2-download-\(UUID().uuidString)"
        )
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }

    private func makeRequest(path: [String]) throws -> URLRequest {
        guard let scheme = configuration.baseURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              configuration.baseURL.host != nil,
              configuration.timeout > 0 else {
            throw ClientError.invalidConfiguration(
                "The say2 helper URL and timeout are invalid"
            )
        }
        let url = path.reduce(configuration.baseURL) {
            $0.appendingPathComponent($1)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.timeout
        return request
    }

    private func validate(_ response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data))?
                .error.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ClientError.server(statusCode: http.statusCode, message: message)
        }
        return http
    }
}
