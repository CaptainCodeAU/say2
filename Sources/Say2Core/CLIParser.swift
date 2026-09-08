import Foundation

public enum CLIParser {
    public static func parse(_ rawArguments: [String]) throws -> ParsedCommand {
        guard let first = rawArguments.first else { return .help }
        if first == "--version" || first == "-V" { return .version }
        if first == "--help" || first == "-h" || first == "help" { return .help }
        if first == "--explain" {
            guard rawArguments.count == 2, let code = Int32(rawArguments[1]) else {
                throw CLIError(
                    "--explain requires a numeric exit code, for example: say2 --explain 69",
                    code: .usage
                )
            }
            return .explain(code)
        }
        if first == "--exit-codes" {
            switch rawArguments.count {
            case 1:
                return .exitCodes(json: false)
            case 2 where rawArguments[1] == "--json":
                return .exitCodes(json: true)
            default:
                throw CLIError("--exit-codes accepts only --json", code: .usage)
            }
        }

        switch first {
        case "voices":
            return .voices(try parseVoices(Array(rawArguments.dropFirst())))
        case "synthesize":
            return .synthesize(try parseSynthesis(Array(rawArguments.dropFirst())))
        case "doctor":
            return .doctor(try parseDoctor(Array(rawArguments.dropFirst())))
        case "serve":
            return .serve(try parseServe(Array(rawArguments.dropFirst())))
        default:
            if rawArguments.count == 2, rawArguments[0] == "-v", rawArguments[1] == "?" {
                return .voices(VoicesOptions())
            }
            return .synthesize(try parseSynthesis(rawArguments))
        }
    }

    public static func parseSynthesis(_ arguments: [String]) throws -> SynthesisOptions {
        var result = SynthesisOptions()
        let arguments = expandLongOptions(arguments)
        var text: [String] = []
        var index = 0
        var optionsEnded = false

        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw CLIError("Missing value for \(flag)", code: .usage)
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnded {
                text.append(argument)
                index += 1
                continue
            }
            switch argument {
            case "--":
                optionsEnded = true
            case "-h", "--help":
                throw CLIError(synthesisHelp, code: .success)
            case "-v", "--voice":
                result.voice = try value(after: argument)
            case "--language", "-l":
                result.language = try value(after: argument)
            case "-o", "--output":
                result.output = try value(after: argument)
            case "-f", "--input-file":
                result.inputFile = try value(after: argument)
            case "-r":
                let raw = try value(after: argument)
                guard let wpm = Float(raw), wpm > 0, wpm <= 700 else {
                    throw CLIError("-r expects words per minute between 0 and 700", code: .usage)
                }
                result.rate = wpm / 175
            case "--rate":
                let raw = try value(after: argument)
                guard let rate = Float(raw), rate > 0, rate <= 4 else {
                    throw CLIError("--rate expects a multiplier between 0 and 4", code: .usage)
                }
                result.rate = rate
            case "--pitch":
                let raw = try value(after: argument)
                guard let pitch = Float(raw), (0.5...2).contains(pitch) else {
                    throw CLIError("--pitch expects a multiplier from 0.5 through 2.0", code: .usage)
                }
                result.pitch = pitch
            case "--volume":
                let raw = try value(after: argument)
                guard let volume = Float(raw), (0...1).contains(volume) else {
                    throw CLIError("--volume expects a value from 0 through 1", code: .usage)
                }
                result.volume = volume
            case "--engine":
                result.engine = try parseEngine(try value(after: argument))
            case "--format":
                result.format = try parseAudioFormat(try value(after: argument))
            case "--file-format":
                let format = try value(after: argument).lowercased()
                switch format {
                case "wave", "wav": result.format = .wav
                case "caff", "caf": result.format = .caf
                default:
                    throw CLIError(
                        "--file-format supports WAVE and CAF only; use --format pcm for raw PCM",
                        code: .usage
                    )
                }
            case "--data-format":
                let format = try value(after: argument).uppercased()
                guard ["LEI16@48000", "LEI16", "S16LE"].contains(format) else {
                    throw CLIError(
                        "--data-format currently supports LEI16@48000 only",
                        code: .usage
                    )
                }
            case "--quality":
                let raw = try value(after: argument)
                guard let quality = Int(raw), (0...127).contains(quality) else {
                    throw CLIError("--quality expects an integer from 0 through 127", code: .usage)
                }
                // Accepted for `say` compatibility. Lossless PCM has no encoder quality setting.
            case "--progress":
                result.progress = true
            case "--json":
                result.json = true
            case "--timings":
                result.timingsPath = try value(after: argument)
            case "--no-prewarm":
                result.prewarm = false
            case "--prewarm":
                result.prewarm = true
            case "--timeout":
                let raw = try value(after: argument)
                guard let timeout = Double(raw), (1...3_600).contains(timeout) else {
                    throw CLIError("--timeout expects seconds from 1 through 3600", code: .usage)
                }
                result.timeout = timeout
            case "--no-output":
                result.noOutput = true
            default:
                if argument.hasPrefix("-") {
                    throw CLIError("Unsupported option '\(argument)'", code: .usage)
                }
                text.append(argument)
            }
            index += 1
        }
        result.text = text.joined(separator: " ")
        if result.output == "-", result.format != .pcm {
            throw CLIError("Streaming to stdout requires `--format pcm`", code: .usage)
        }
        if result.output == "-", result.engine == .auto {
            throw CLIError(
                "Streaming to stdout requires an explicit siri or av engine; auto fallback could mix partial streams",
                code: .usage
            )
        }
        if result.inputFile != nil, !result.text.isEmpty {
            throw CLIError("Pass either text or -f/--input-file, not both", code: .usage)
        }
        if result.noOutput, result.output != nil {
            throw CLIError("--no-output cannot be combined with -o/--output", code: .usage)
        }
        result.requestTimings = result.json || result.timingsPath != nil
        return result
    }

    private static func parseVoices(_ arguments: [String]) throws -> VoicesOptions {
        var result = VoicesOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json": result.json = true
            case "--available": result.available = true
            case "--include-av": result.includeAV = true
            case "--install":
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing voice name for --install", code: .usage)
                }
                index += 1
                result.install = arguments[index]
            case "--purge":
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing voice name or asset key for --purge", code: .usage)
                }
                index += 1
                result.purge = arguments[index]
            case "--status":
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing voice name for --status", code: .usage)
                }
                index += 1
                result.status = arguments[index]
            case "--wait": result.wait = true
            case "--timeout":
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing seconds for --timeout", code: .usage)
                }
                index += 1
                guard let timeout = Double(arguments[index]), (1...3_600).contains(timeout) else {
                    throw CLIError("--timeout expects seconds from 1 through 3600", code: .usage)
                }
                result.timeout = timeout
            case "--manage": result.manage = true
            case "-h", "--help":
                throw CLIError(voicesHelp, code: .success)
            default:
                throw CLIError("Unsupported voices option '\(arguments[index])'", code: .usage)
            }
            index += 1
        }
        let actions = [
            result.install != nil,
            result.purge != nil,
            result.status != nil,
            result.manage,
        ].filter { $0 }.count
        if actions > 1 {
            throw CLIError(
                "Choose only one of --install, --purge, --status, or --manage",
                code: .usage
            )
        }
        if actions > 0, result.includeAV || result.available {
            throw CLIError(
                "Voice actions cannot be combined with --available or --include-av",
                code: .usage
            )
        }
        if result.wait, result.install == nil {
            throw CLIError("--wait requires --install", code: .usage)
        }
        if result.timeout != nil,
           result.install == nil,
           result.purge == nil,
           result.status == nil {
            throw CLIError("--timeout requires --install, --purge, or --status", code: .usage)
        }
        if result.timeout != nil, result.install != nil, !result.wait {
            throw CLIError("--timeout with --install requires --wait", code: .usage)
        }
        if let timeout = result.timeout, result.purge != nil, timeout > 300 {
            throw CLIError("--timeout with --purge must not exceed 300 seconds", code: .usage)
        }
        return result
    }

    private static func parseDoctor(_ arguments: [String]) throws -> DoctorOptions {
        var result = DoctorOptions()
        for argument in arguments {
            switch argument {
            case "--json": result.json = true
            case "--skip-probe": result.skipProbe = true
            case "-h", "--help":
                throw CLIError(doctorHelp, code: .success)
            default:
                throw CLIError("Unsupported doctor option '\(argument)'", code: .usage)
            }
        }
        return result
    }

    private static func parseServe(_ arguments: [String]) throws -> ServeOptions {
        var result = ServeOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func next() throws -> String {
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing value for \(argument)", code: .usage)
                }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--host": result.host = try next()
            case "--port":
                let raw = try next()
                guard let port = UInt16(raw), port > 0 else {
                    throw CLIError("--port expects a number from 1 through 65535", code: .usage)
                }
                result.port = port
            case "--engine": result.engine = try parseEngine(try next())
            case "--verbose": result.verbose = true
            case "--allow-remote": result.allowRemote = true
            case "-h", "--help":
                throw CLIError(serveHelp, code: .success)
            default:
                throw CLIError("Unsupported serve option '\(argument)'", code: .usage)
            }
            index += 1
        }
        return result
    }

    private static func parseEngine(_ raw: String) throws -> EngineKind {
        guard let engine = EngineKind(rawValue: raw.lowercased()) else {
            throw CLIError("--engine expects siri, av, or auto", code: .usage)
        }
        return engine
    }

    private static func parseAudioFormat(_ raw: String) throws -> AudioFormat {
        guard let format = AudioFormat(rawValue: raw.lowercased()) else {
            throw CLIError("--format expects wav, pcm, or caf", code: .usage)
        }
        return format
    }

    private static func expandLongOptions(_ arguments: [String]) -> [String] {
        arguments.flatMap { argument -> [String] in
            guard argument.hasPrefix("--"),
                  let equals = argument.firstIndex(of: "="),
                  equals > argument.index(argument.startIndex, offsetBy: 2) else {
                return [argument]
            }
            return [
                String(argument[..<equals]),
                String(argument[argument.index(after: equals)...]),
            ]
        }
    }
}

public let mainHelp = """
say2 \(say2Version) — neural Siri voices from the command line

USAGE
  say2 synthesize [options] TEXT
  say2 [say-compatible options] TEXT
  say2 voices [--json | --available | --install NAME | --purge NAME | --status NAME | --manage]
  say2 doctor [--json]
  say2 serve [--port 8080]
  say2 --explain CODE
  say2 --exit-codes [--json]

COMMANDS
  synthesize   Render text to a file, stdout, or the default audio output
  voices       List installed Siri voices and their real asset metadata
  doctor       Probe this Mac and produce a compatibility report
  serve        Run the OpenAI-compatible local HTTP API

Run `say2 COMMAND --help` for command-specific options.

EXIT CODES
  0    success
  2    invalid invocation
  3    no compatible engine
  4    voice not found
  5    daemon unreachable (present, not responding) -- transient, retry is reasonable
  6    empty, silent, malformed, or implausibly short audio
  7    timed out waiting for an operation, including a bounded synthesis render
  8    voice known but not installed; `say2 voices --install` fixes it
  69   Siri TTS framework not present on this system -- permanent, do not retry; use --engine av
  70   unexpected internal failure
  73   could not write audio to the requested output location
  130  cancelled

Run `say2 --explain CODE` for what a specific code means and what to do about it.
"""

public let synthesisHelp = """
USAGE
  say2 synthesize [options] TEXT
  echo TEXT | say2 synthesize [options]

OPTIONS
  -v, --voice NAME       Voice display name or asset identifier
  --language TAG         Restrict voice matching (for example en-US)
  -o, --output PATH      Output file; use - for raw PCM on stdout
  --no-output            Synthesize and discard the audio; measure without writing anything
  -f, --input-file PATH  Read UTF-8 input from a file
  -r WPM                 `say`-compatible words per minute (175 = 1.0x)
  --rate MULTIPLIER      Native speaking-rate multiplier
  --pitch MULTIPLIER     Pitch from 0.5 through 2.0
  --volume NUMBER        Volume from 0 through 1
  --engine KIND          siri (default), av, or auto
  --format FORMAT        wav (default), pcm, or caf
  --timings PATH         Write versioned word timings as JSON
  --json                 Emit a versioned result object
  --progress             Report synthesis progress on stderr
  --no-prewarm           Skip Siri model prewarming
"""

public let voicesHelp = """
USAGE
  say2 voices [--json] [--available] [--include-av]
  say2 voices --install NAME [--wait] [--timeout SECONDS] [--json]
  say2 voices --purge NAME [--timeout SECONDS] [--json]
  say2 voices --status NAME [--json]
  say2 voices --manage [--json]

`--available` asks macOS for the full Siri catalog. `--install` explicitly asks
macOS to subscribe to one catalog voice; it never runs implicitly. `--wait`
polls for both local content and a usable daemon voice but cannot show a percentage.
`--purge` physically deletes the exact local voice asset and fails unless its
proven `AssetData` path disappears. `--manage` opens Apple's voice settings.
"""

public let doctorHelp = """
USAGE
  say2 doctor [--json] [--skip-probe]

The default report performs a short real synthesis probe. Use --skip-probe only
when a non-speaking diagnostic is required.
"""

public let serveHelp = """
USAGE
  say2 serve [--host 127.0.0.1] [--port 8080] [--engine siri|av|auto] [--allow-remote]

Implements GET /v1/models and POST /v1/audio/speech. Loopback is the safe default.
The server has no authentication, so binding a non-loopback address requires
--allow-remote; without it, say2 refuses to start rather than silently exposing
speech synthesis to the network.
"""
