import Foundation

struct TextChunk: Equatable, Sendable {
    let text: String
    let utf16Location: Int
}

enum TextChunker {
    static let defaultByteLimit = 4_000

    /// Splits text at natural boundaries without changing or dropping characters.
    /// A single extended grapheme may exceed the byte target, but it is never split.
    static func chunks(
        _ text: String,
        byteLimit: Int = defaultByteLimit
    ) -> [TextChunk] {
        precondition(byteLimit > 0)
        guard !text.isEmpty else { return [] }

        var result: [TextChunk] = []
        var start = text.startIndex
        var utf16Location = 0

        while start < text.endIndex {
            var cursor = start
            var bytes = 0
            var preferredBoundary: String.Index?

            while cursor < text.endIndex {
                let next = text.index(after: cursor)
                let character = text[cursor..<next]
                let characterBytes = character.utf8.count
                if bytes > 0, bytes + characterBytes > byteLimit { break }
                bytes += characterBytes
                cursor = next
                if character.last?.isWhitespace == true ||
                    character.last.map({ ".!?;:".contains($0) }) == true {
                    preferredBoundary = cursor
                }
                if bytes >= byteLimit { break }
            }

            let boundary: String.Index
            if cursor == text.endIndex {
                boundary = cursor
            } else if let preferredBoundary, preferredBoundary > start {
                boundary = preferredBoundary
            } else {
                boundary = cursor
            }

            let value = String(text[start..<boundary])
            result.append(TextChunk(text: value, utf16Location: utf16Location))
            utf16Location += value.utf16.count
            start = boundary
        }
        return result
    }

    /// Splits text into sentence-sized pieces without changing or dropping
    /// characters. A piece ends after `.`, `!` or `?` and the spaces after it,
    /// or after a line break. A piece with no letters or digits joins its
    /// neighbour, so no piece is only punctuation, which Siri may not voice.
    static func sentences(_ text: String) -> [TextChunk] {
        var pieces: [String] = []
        var current = ""
        var ended = false
        for character in text {
            if ended, !character.isWhitespace {
                pieces.append(current)
                current = ""
                ended = false
            }
            current.append(character)
            if character.isNewline || ".!?".contains(character) {
                ended = true
            }
        }
        if !current.isEmpty { pieces.append(current) }

        func voiced(_ piece: String) -> Bool {
            piece.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
        var merged: [String] = []
        var carried = ""
        for piece in pieces {
            if !voiced(piece), !merged.isEmpty {
                merged[merged.count - 1] += piece
            } else if !voiced(piece) {
                carried += piece
            } else {
                merged.append(carried + piece)
                carried = ""
            }
        }
        if !carried.isEmpty { merged.append(carried) }

        var result: [TextChunk] = []
        var utf16Location = 0
        for piece in merged {
            result.append(TextChunk(text: piece, utf16Location: utf16Location))
            utf16Location += piece.utf16.count
        }
        return result
    }
}

struct IncrementalSynthesisResult: Sendable {
    let spec: AudioSpec
    let voice: VoiceInfo
    let timings: [RawWordTiming]
    let timingsSupported: Bool
    let engine: EngineKind
    let fallbackFrom: EngineKind?
    let elapsed: TimeInterval
    let timeToFirstAudio: TimeInterval?
    let bytes: Int
    let sampleCount: Int
    let durationSeconds: TimeInterval
    /// Each distinct prewarm warning from the pieces, in the order first seen.
    var prewarmWarnings: [String] = []
    /// One line for each piece Siri failed and say2 recovered by retrying (#4774).
    var recoveryWarnings: [String] = []
}

/// Renders one piece of text. The default renders through an `EngineCoordinator`;
/// tests pass their own.
typealias PieceRenderer = (
    SynthesisOptions,
    (@Sendable (Data) -> Void)?
) throws -> (audio: RenderedAudio, fallbackFrom: EngineKind?)

private final class StreamedByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ bytes: Int) { lock.lock(); count += bytes; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Apple's voice sometimes fails one request mid-render (exit 5), most often
/// when the Mac is short of memory (#4774). One failure used to end the whole
/// reading. Now a failed piece is tried again once; if it fails again, it is
/// read sentence by sentence, each sentence with one retry of its own.
enum PieceRecovery {
    static let retryPause: TimeInterval = 0.5

    /// Only failures a second try can fix: Siri not answering, or no audio.
    static func isRecoverable(_ error: Error) -> Bool {
        guard let error = error as? CLIError else { return false }
        return error.code == .daemonUnreachable || error.code == .noAudio
    }

    struct Piece {
        let chunk: TextChunk
        let audio: RenderedAudio
        let acceptance: AudioResult
        let fallbackFrom: EngineKind?
    }

    /// Renders `chunk`, recovering as above. Pieces come back in text order,
    /// each with its offset inside the whole text. When audio is streamed and
    /// some of a failed attempt already went out, no retry is made, because the
    /// listener would hear that part twice.
    static func render(
        _ chunk: TextChunk,
        options: SynthesisOptions,
        renderPiece: PieceRenderer,
        onProvisionalPCMChunk: (@Sendable (Data) -> Void)?,
        pause: (TimeInterval) -> Void,
        warnings: inout [String]
    ) throws -> [Piece] {
        let firstError: Error
        do {
            return [try attempt(chunk, options, renderPiece, onProvisionalPCMChunk)]
        } catch let failure as AttemptFailure {
            guard failure.retryable else { throw failure.error }
            firstError = failure.error
        }

        pause(retryPause)
        do {
            let piece = try attempt(chunk, options, renderPiece, onProvisionalPCMChunk)
            warnings.append(
                "Siri failed a piece of the text (\(describe(firstError))); "
                    + "say2 tried it again and it worked"
            )
            return [piece]
        } catch let failure as AttemptFailure {
            guard failure.retryable else { throw failure.error }
        }

        let sentences = TextChunker.sentences(chunk.text).filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard sentences.count > 1 else {
            throw withContext(firstError, "after one retry")
        }
        var pieces: [Piece] = []
        var retried = 0
        for sentence in sentences {
            let located = TextChunk(
                text: sentence.text,
                utf16Location: chunk.utf16Location + sentence.utf16Location
            )
            do {
                pieces.append(try attempt(located, options, renderPiece, onProvisionalPCMChunk))
                continue
            } catch let failure as AttemptFailure {
                guard failure.retryable else { throw failure.error }
            }
            pause(retryPause)
            do {
                pieces.append(try attempt(located, options, renderPiece, onProvisionalPCMChunk))
                retried += 1
            } catch let failure as AttemptFailure {
                guard failure.retryable else { throw failure.error }
                throw withContext(
                    failure.error,
                    "after one retry, and again sentence by sentence"
                )
            }
        }
        warnings.append(
            "Siri failed a piece of the text twice (\(describe(firstError))); "
                + "say2 read it sentence by sentence instead ("
                + "\(sentences.count) sentences, \(retried) needed a second try)"
        )
        return pieces
    }

    private struct AttemptFailure: Error {
        let error: Error
        let retryable: Bool
    }

    private static func attempt(
        _ chunk: TextChunk,
        _ options: SynthesisOptions,
        _ renderPiece: PieceRenderer,
        _ onProvisionalPCMChunk: (@Sendable (Data) -> Void)?
    ) throws -> Piece {
        var pieceOptions = options
        pieceOptions.text = chunk.text
        let streamed = StreamedByteCounter()
        let forward: (@Sendable (Data) -> Void)? = onProvisionalPCMChunk.map { send in
            { @Sendable data in
                streamed.add(data.count)
                send(data)
            }
        }
        do {
            let rendered = try renderPiece(pieceOptions, forward)
            let acceptance = try AudioIO.validatePCM(
                rendered.audio.pcm,
                spec: rendered.audio.spec,
                text: chunk.text
            )
            return Piece(
                chunk: chunk,
                audio: rendered.audio,
                acceptance: acceptance,
                fallbackFrom: rendered.fallbackFrom
            )
        } catch {
            throw AttemptFailure(
                error: error,
                retryable: isRecoverable(error) && streamed.value == 0
            )
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? CLIError)?.message ?? error.localizedDescription
    }

    private static func withContext(_ error: Error, _ context: String) -> Error {
        guard let error = error as? CLIError else { return error }
        return CLIError("\(error.message) (\(context))", code: error.code)
    }
}

enum LongFormSynthesis {
    /// Renders bounded pieces sequentially and releases each piece after the sink
    /// accepts it. Memory use therefore follows chunk size instead of audio length.
    static func render(
        _ options: SynthesisOptions,
        coordinator: EngineCoordinator,
        chunkByteLimit: Int = TextChunker.defaultByteLimit,
        onProvisionalPCMChunk: (@Sendable (Data) -> Void)? = nil,
        sink: (Data) throws -> Void
    ) throws -> IncrementalSynthesisResult {
        try render(
            options,
            chunkByteLimit: chunkByteLimit,
            onProvisionalPCMChunk: onProvisionalPCMChunk,
            renderPiece: { try coordinator.render($0, onPCMChunk: $1) },
            pause: { Thread.sleep(forTimeInterval: $0) },
            sink: sink
        )
    }

    static func render(
        _ options: SynthesisOptions,
        chunkByteLimit: Int = TextChunker.defaultByteLimit,
        onProvisionalPCMChunk: (@Sendable (Data) -> Void)? = nil,
        renderPiece: PieceRenderer,
        pause: (TimeInterval) -> Void,
        sink: (Data) throws -> Void
    ) throws -> IncrementalSynthesisResult {
        let started = Date()
        let chunks = TextChunker.chunks(options.text, byteLimit: chunkByteLimit)
        var selectedEngine: EngineKind?
        var selectedVoice: VoiceInfo?
        var selectedSpec: AudioSpec?
        var fallbackFrom: EngineKind?
        var timings: [RawWordTiming] = []
        var timingsSupported = true
        var byteCount = 0
        var sampleCount = 0
        var duration = 0.0
        var timeToFirstAudio: TimeInterval?
        var prewarmWarnings: [String] = []
        var recoveryWarnings: [String] = []

        for chunk in chunks where !chunk.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            var chunkOptions = options
            chunkOptions.text = chunk.text
            chunkOptions.inputFile = nil
            chunkOptions.output = nil
            if options.engine == .auto, let selectedEngine {
                chunkOptions.engine = selectedEngine
            }

            let pieces = try PieceRecovery.render(
                chunk,
                options: chunkOptions,
                renderPiece: renderPiece,
                onProvisionalPCMChunk: onProvisionalPCMChunk,
                pause: pause,
                warnings: &recoveryWarnings
            )
            for piece in pieces {
                let rendered = (audio: piece.audio, fallbackFrom: piece.fallbackFrom)
                let acceptance = piece.acceptance

                if let selectedSpec, selectedSpec != rendered.audio.spec {
                    throw CLIError(
                        "Speech format changed between long-form chunks",
                        code: .noAudio
                    )
                }
                if let selectedVoice,
                   selectedVoice.assetKey != rendered.audio.voice.assetKey {
                    throw CLIError(
                        "Speech voice changed between long-form chunks",
                        code: .noAudio
                    )
                }

                if selectedEngine == nil {
                    selectedEngine = rendered.audio.engine
                    selectedVoice = rendered.audio.voice
                    selectedSpec = rendered.audio.spec
                    fallbackFrom = rendered.fallbackFrom
                    timeToFirstAudio = rendered.audio.timeToFirstAudio
                }

                timings.append(contentsOf: rendered.audio.timings.map {
                    RawWordTiming(
                        start: $0.start + duration,
                        range: NSRange(
                            location: $0.range.location + piece.chunk.utf16Location,
                            length: $0.range.length
                        )
                    )
                })
                if let warning = rendered.audio.prewarmWarning,
                   !prewarmWarnings.contains(warning) {
                    prewarmWarnings.append(warning)
                }
                timingsSupported = timingsSupported && rendered.audio.timingsSupported
                if onProvisionalPCMChunk == nil {
                    try sink(rendered.audio.pcm)
                }
                byteCount += acceptance.bytes
                sampleCount += acceptance.sampleCount
                duration += acceptance.durationSeconds
            }
        }

        guard let spec = selectedSpec,
              let voice = selectedVoice,
              let engine = selectedEngine,
              byteCount > 0 else {
            throw CLIError("Synthesis produced no spoken audio", code: .noAudio)
        }
        return IncrementalSynthesisResult(
            spec: spec,
            voice: voice,
            timings: timings,
            timingsSupported: timingsSupported,
            engine: engine,
            fallbackFrom: fallbackFrom,
            elapsed: Date().timeIntervalSince(started),
            timeToFirstAudio: timeToFirstAudio,
            bytes: byteCount,
            sampleCount: sampleCount,
            durationSeconds: duration,
            prewarmWarnings: prewarmWarnings,
            recoveryWarnings: recoveryWarnings
        )
    }
}
