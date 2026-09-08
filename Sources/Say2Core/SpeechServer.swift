import Darwin
import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

public enum HTTPParser {
    public static func parse(_ data: Data) throws -> HTTPRequest {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(
                  data: data[..<headerRange.lowerBound],
                  encoding: .utf8
              ) else {
            throw CLIError("Malformed HTTP request", code: .usage)
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw CLIError("Missing HTTP request line", code: .usage)
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            throw CLIError("Malformed HTTP request line", code: .usage)
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw CLIError("Malformed HTTP header", code: .usage)
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil else {
                throw CLIError("Duplicate HTTP header '\(name)'", code: .usage)
            }
            headers[name] = value
        }
        let bodyStart = headerRange.upperBound
        let body = Data(data[bodyStart...])
        if let rawLength = headers["content-length"] {
            guard let length = Int(rawLength), length >= 0 else {
                throw CLIError("Invalid Content-Length", code: .usage)
            }
            guard body.count == length else {
                throw CLIError("Incomplete HTTP request body", code: .usage)
            }
        }
        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: body
        )
    }
}

public struct SpeechAPIRequest: Codable, Equatable, Sendable {
    public let model: String
    public let input: String
    public let voice: String
    public let responseFormat: String?
    public let speed: Double?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case responseFormat = "response_format"
        case speed
    }
}

private struct HTTPFailure: LocalizedError {
    let status: String
    let message: String

    var errorDescription: String? { message }
}

private struct FileSpeechResponse {
    let url: URL
    let contentType: String
    let engine: EngineKind
}

public final class SpeechServer {
    private let options: ServeOptions
    private let coordinator: EngineCoordinator
    private let stateLock = NSLock()
    private var listeningDescriptor: Int32 = -1
    private var stopping = false

    public init(options: ServeOptions, coordinator: EngineCoordinator) {
        self.options = options
        self.coordinator = coordinator
    }

    public func run() throws {
        if options.engine != .av {
            coordinator.siri.enableKeepActive()
        }
        if let error = Self.remoteBindError(host: options.host, allowRemote: options.allowRemote) {
            throw error
        }
        if !Self.loopbackHosts.contains(options.host) {
            writeStderr(
                "warning: binding \(options.host) exposes unauthenticated speech synthesis to the network\n"
            )
        }

        let descriptor = try makeListeningSocket()
        stateLock.withLock {
            listeningDescriptor = descriptor
            stopping = false
        }
        defer {
            stateLock.withLock { listeningDescriptor = -1 }
            close(descriptor)
        }

        guard listen(descriptor, 32) == 0 else {
            throw CLIError("Could not listen: \(posixMessage())", code: .internalFailure)
        }
        let displayHost = options.host.contains(":") ? "[\(options.host)]" : options.host
        writeStderr("say2 listening on http://\(displayHost):\(options.port)\n")

        while true {
            if stateLock.withLock({ stopping }) {
                throw CLIError("Server stopped", code: .cancelled)
            }
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&readiness, 1, 250)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CLIError("Server poll failed: \(posixMessage())", code: .internalFailure)
            }
            var peer = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(descriptor, &peer, &length)
            if client < 0 {
                if errno == EINTR { continue }
                if stateLock.withLock({ stopping }) {
                    throw CLIError("Server stopped", code: .cancelled)
                }
                if [ECONNABORTED, EMFILE, ENFILE].contains(errno) { continue }
                throw CLIError("Could not accept connection: \(posixMessage())", code: .internalFailure)
            }
            autoreleasepool {
                defer { close(client) }
                do {
                    configureClientSocket(client)
                    let request = try readRequest(from: client)
                    if request.method == "POST", request.path == "/v1/audio/speech" {
                        try writeSpeechResponse(request, to: client)
                    } else {
                        try writeAll(try route(request), to: client)
                    }
                } catch {
                    let response = errorResponse(error)
                    try? writeAll(response, to: client)
                }
            }
        }
    }

    public func stop() {
        stateLock.withLock {
            stopping = true
        }
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    /// Returns the error to throw when `host` needs `--allow-remote` and doesn't have it, or `nil` if binding may proceed.
    static func remoteBindError(host: String, allowRemote: Bool) -> CLIError? {
        guard !loopbackHosts.contains(host), !allowRemote else { return nil }
        return CLIError(
            "Binding \(host) would expose unauthenticated speech synthesis to the network. Pass --allow-remote to confirm this is intended.",
            code: .usage
        )
    }


    private func makeListeningSocket() throws -> Int32 {
        let bindHost = options.host == "localhost" ? "127.0.0.1" : options.host

        var ipv4 = sockaddr_in()
        if inet_pton(AF_INET, bindHost, &ipv4.sin_addr) == 1 {
            ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            ipv4.sin_family = sa_family_t(AF_INET)
            ipv4.sin_port = options.port.bigEndian
            return try bindSocket(family: AF_INET) { descriptor in
                withUnsafePointer(to: &ipv4) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(
                            descriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
        }

        var ipv6 = sockaddr_in6()
        if inet_pton(AF_INET6, bindHost, &ipv6.sin6_addr) == 1 {
            ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            ipv6.sin6_family = sa_family_t(AF_INET6)
            ipv6.sin6_port = options.port.bigEndian
            return try bindSocket(family: AF_INET6) { descriptor in
                var onlyIPv6: Int32 = 1
                guard setsockopt(
                    descriptor,
                    IPPROTO_IPV6,
                    IPV6_V6ONLY,
                    &onlyIPv6,
                    socklen_t(MemoryLayout.size(ofValue: onlyIPv6))
                ) == 0 else {
                    return -1
                }
                return withUnsafePointer(to: &ipv6) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(
                            descriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in6>.size)
                        )
                    }
                }
            }
        }

        throw CLIError(
            "Invalid IP bind address '\(options.host)'",
            code: .usage
        )
    }

    private func bindSocket(
        family: Int32,
        bind: (Int32) -> Int32
    ) throws -> Int32 {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CLIError(
                "Could not create server socket: \(posixMessage())",
                code: .internalFailure
            )
        }
        var succeeded = false
        defer { if !succeeded { close(descriptor) } }

        var reuse: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse))
        ) == 0 else {
            throw CLIError(
                "Could not configure server socket: \(posixMessage())",
                code: .internalFailure
            )
        }
        guard bind(descriptor) == 0 else {
            throw CLIError(
                "Could not bind \(options.host):\(options.port): \(posixMessage())",
                code: .internalFailure
            )
        }
        succeeded = true
        return descriptor
    }

    public func route(_ request: HTTPRequest) throws -> Data {
        if request.method == "GET", request.path == "/v1/models" {
            return try modelsResponse()
        }
        guard request.method == "POST", request.path == "/v1/audio/speech" else {
            return response(
                status: "404 Not Found",
                contentType: "application/json",
                body: encodedJSON(["error": ["message": "Route not found"]])
            )
        }
        do {
            let apiRequest = try parseSpeechRequest(request)
            let rendered = try renderSpeechToFile(apiRequest)
            defer { try? FileManager.default.removeItem(at: rendered.url) }
            let body = try Data(contentsOf: rendered.url)
            return response(
                status: "200 OK",
                contentType: rendered.contentType,
                body: body,
                extraHeaders: ["X-Say2-Engine": rendered.engine.rawValue]
            )
        } catch {
            return errorResponse(error)
        }
    }

    private func parseSpeechRequest(_ request: HTTPRequest) throws -> SpeechAPIRequest {
        guard request.headers["content-type"]?
            .lowercased().contains("application/json") == true else {
            throw HTTPFailure(
                status: "415 Unsupported Media Type",
                message: "Content-Type must be application/json"
            )
        }
        let apiRequest: SpeechAPIRequest
        do {
            apiRequest = try JSONDecoder().decode(SpeechAPIRequest.self, from: request.body)
        } catch {
            throw HTTPFailure(
                status: "400 Bad Request",
                message: "Invalid request JSON: \(error.localizedDescription)"
            )
        }
        guard !apiRequest.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPFailure(
                status: "400 Bad Request",
                message: "input must contain spoken text"
            )
        }
        let format = (apiRequest.responseFormat ?? "wav").lowercased()
        guard ["wav", "pcm"].contains(format) else {
            throw HTTPFailure(
                status: "400 Bad Request",
                message: "response_format must be wav or pcm"
            )
        }
        let speed = apiRequest.speed ?? 1
        guard (0.25...4).contains(speed) else {
            throw HTTPFailure(
                status: "400 Bad Request",
                message: "speed must be between 0.25 and 4.0"
            )
        }
        return apiRequest
    }

    private func renderSpeechToFile(_ apiRequest: SpeechAPIRequest) throws -> FileSpeechResponse {
        let format = (apiRequest.responseFormat ?? "wav").lowercased()
        var synthesis = SynthesisOptions()
        synthesis.text = apiRequest.input
        synthesis.voice = apiRequest.voice
        synthesis.engine = options.engine
        synthesis.rate = Float(apiRequest.speed ?? 1)
        synthesis.format = format == "wav" ? .wav : .pcm

        let spool = try PCMSpool()
        let rendered = try LongFormSynthesis.render(
            synthesis,
            coordinator: coordinator,
            sink: spool.append
        )
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "say2-response-\(UUID().uuidString).\(format)"
        )
        do {
            try spool.materialize(format: synthesis.format, spec: rendered.spec, at: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return FileSpeechResponse(
            url: output,
            contentType: format == "wav" ? "audio/wav" : "application/octet-stream",
            engine: rendered.engine
        )
    }

    private func writeSpeechResponse(_ request: HTTPRequest, to descriptor: Int32) throws {
        let rendered: FileSpeechResponse
        do {
            rendered = try renderSpeechToFile(parseSpeechRequest(request))
        } catch {
            try writeAll(errorResponse(error), to: descriptor)
            return
        }
        defer { try? FileManager.default.removeItem(at: rendered.url) }
        let size = try rendered.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size else {
            throw CLIError("Could not determine speech response size", code: .internalFailure)
        }
        try writeAll(
            responseHeader(
                status: "200 OK",
                contentType: rendered.contentType,
                contentLength: size,
                extraHeaders: ["X-Say2-Engine": rendered.engine.rawValue]
            ),
            to: descriptor
        )
        try writeFile(rendered.url, to: descriptor)
    }

    private func modelsResponse() throws -> Data {
        struct Model: Encodable {
            let id: String
            let object = "model"
            let ownedBy = "local-macos"

            enum CodingKeys: String, CodingKey {
                case id, object
                case ownedBy = "owned_by"
            }
        }
        struct Models: Encodable {
            let object = "list"
            let data: [Model]
        }
        let voices: [VoiceInfo]
        switch options.engine {
        case .siri: voices = try coordinator.siri.voices()
        case .av: voices = coordinator.av.voices()
        case .auto:
            voices = (try? coordinator.siri.voices()).flatMap { $0.isEmpty ? nil : $0 }
                ?? coordinator.av.voices()
        }
        return response(
            status: "200 OK",
            contentType: "application/json",
            body: encodedJSON(Models(data: voices.map { Model(id: $0.name) }))
        )
    }

    private func readRequest(from descriptor: Int32) throws -> HTTPRequest {
        let headerSeparator = Data("\r\n\r\n".utf8)
        var data = Data()
        var expectedSize: Int?
        let maximumHeaderBytes = 65_536
        while true {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw CLIError("Socket read failed: \(posixMessage())", code: .internalFailure)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if expectedSize == nil, let range = data.range(of: headerSeparator) {
                let header = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                var contentLength = 0
                var sawContentLength = false
                for line in header.components(separatedBy: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        guard !sawContentLength else {
                            throw CLIError("Duplicate Content-Length", code: .usage)
                        }
                        sawContentLength = true
                        guard let colon = line.firstIndex(of: ":") else {
                            throw CLIError("Malformed Content-Length", code: .usage)
                        }
                        let raw = line[line.index(after: colon)...]
                            .trimmingCharacters(in: .whitespaces)
                        contentLength = Int(raw) ?? -1
                    }
                }
                guard contentLength >= 0,
                      range.upperBound <= Int.max - contentLength else {
                    throw CLIError("Invalid Content-Length", code: .usage)
                }
                expectedSize = range.upperBound + contentLength
            }
            if let expectedSize, data.count >= expectedSize { break }
            if expectedSize == nil, data.count > maximumHeaderBytes {
                throw CLIError("HTTP request headers are too large", code: .usage)
            }
        }
        return try HTTPParser.parse(data)
    }

    private func response(
        status: String,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        var result = responseHeader(
            status: status,
            contentType: contentType,
            contentLength: body.count,
            extraHeaders: extraHeaders
        )
        result.append(body)
        return result
    }

    private func responseHeader(
        status: String,
        contentType: String,
        contentLength: Int,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        var headerLines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)",
            "Connection: close",
        ]
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            headerLines.append("\(name): \(value)")
        }
        let header = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        return Data(header.utf8)
    }

    func errorResponse(_ error: Error) -> Data {
        let message = error.localizedDescription
        let status: String
        if let failure = error as? HTTPFailure {
            status = failure.status
        } else if let cliError = error as? CLIError {
            switch cliError.code {
            case .usage, .voiceNotFound, .voiceNotInstalled:
                status = "400 Bad Request"
            case .noCompatibleEngine, .daemonUnreachable, .frameworkUnavailable, .operationTimedOut:
                status = "503 Service Unavailable"
            case .cancelled:
                status = "499 Client Closed Request"
            default:
                status = "500 Internal Server Error"
            }
        } else {
            status = "500 Internal Server Error"
        }
        // Only well-formed client-facing failures (HTTPFailure, and the CLIError
        // codes mapped above) are meant to be read by the caller. Anything that
        // falls through to 500 is an unexpected internal failure whose raw
        // message (POSIX errors, decoder internals, etc.) should not leave the
        // machine, even though it's always worth logging locally.
        let isInternal = status == "500 Internal Server Error"
        if options.verbose || isInternal { writeStderr("request failed: \(message)\n") }
        let clientMessage = isInternal ? "Internal server error" : message
        return response(
            status: status,
            contentType: "application/json",
            body: encodedJSON(["error": ["message": clientMessage]])
        )
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = Darwin.send(
                    descriptor,
                    raw.baseAddress!.advanced(by: written),
                    raw.count - written,
                    0
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CLIError("Socket write failed: \(posixMessage())", code: .internalFailure)
                }
                written += count
            }
        }
    }

    private func writeFile(_ url: URL, to descriptor: Int32) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        while true {
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { return }
            try writeAll(data, to: descriptor)
        }
    }

    private func configureClientSocket(_ descriptor: Int32) {
        var noPipe: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noPipe,
            socklen_t(MemoryLayout.size(ofValue: noPipe))
        )
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
    }
}

private func posixMessage() -> String {
    String(cString: strerror(errno))
}
