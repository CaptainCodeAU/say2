import CoreAudioTypes
import Foundation

public let say2Version = "1.2.1"
public let say2SchemaVersion = 1

public enum ExitCode: Int32, Sendable {
    case success = 0
    case usage = 2
    case noCompatibleEngine = 3
    case voiceNotFound = 4
    case daemonUnreachable = 5
    case noAudio = 6
    case operationTimedOut = 7
    /// The requested voice exists in Apple's catalog but is not installed on
    /// this Mac -- distinct from `voiceNotFound`, which means the name did
    /// not resolve to any known voice at all. A caller can recover from this
    /// one with `say2 voices --install`; it cannot recover from the other.
    case voiceNotInstalled = 8
    case cancelled = 130
    case internalFailure = 70
    /// The private Siri TTS framework is permanently unavailable on this
    /// system (e.g. an Apple update removed or renamed it) -- distinct from
    /// `daemonUnreachable`, which is a transient, retry-worthy failure of an
    /// otherwise-present framework. A caller should stop retrying and fall
    /// back to a public engine (`--engine av`) rather than treat this like 5.
    case frameworkUnavailable = 69
    /// Audio could not be written to the requested output location (the
    /// directory for `-o`/`--output` doesn't exist, isn't writable, or isn't
    /// a normal writable path like `/dev`) -- distinct from
    /// `internalFailure`, which is an unexpected bug inside say2 itself.
    case outputWriteFailed = 73
}

public struct ExitCodeDescription: Codable, Equatable, Sendable {
    public let code: Int32
    public let name: String
    public let meaning: String
    public let remedy: String
}

/// The canonical, versioned exit-code reference. `--explain N` and
/// `--exit-codes` both read from this single source so the two surfaces
/// can't drift out of sync with each other.
public let exitCodeReference: [ExitCodeDescription] = [
    .init(
        code: ExitCode.success.rawValue, name: "success",
        meaning: "Synthesis (or the requested command) completed normally.",
        remedy: "Nothing to do."
    ),
    .init(
        code: ExitCode.usage.rawValue, name: "usage",
        meaning: "The invocation itself is invalid -- an unknown flag, a bad "
            + "value, or two options that can't be combined.",
        remedy: "Fix the command line. This will never succeed by retrying "
            + "unchanged; check `say2 <command> --help`."
    ),
    .init(
        code: ExitCode.noCompatibleEngine.rawValue, name: "no compatible engine",
        meaning: "No engine could handle the request -- for example, no "
            + "AVSpeechSynthesizer voice is available for the requested "
            + "language, or --engine auto exhausted both Siri and AV.",
        remedy: "Try a different --language, install a matching voice, or "
            + "check `say2 doctor` for engine availability."
    ),
    .init(
        code: ExitCode.voiceNotFound.rawValue, name: "voice not found",
        meaning: "The requested voice name or asset key does not match any "
            + "voice say2 knows about, installed or not.",
        remedy: "Run `say2 voices` (or `--available`) to see valid names."
    ),
    .init(
        code: ExitCode.daemonUnreachable.rawValue, name: "daemon unreachable",
        meaning: "The private Siri TTS framework is present but its resident "
            + "daemon did not respond in time. This is usually transient.",
        remedy: "Retry. If it keeps happening, run `say2 doctor` -- if the "
            + "framework itself is missing you'll get exit 69 instead, not this."
    ),
    .init(
        code: ExitCode.noAudio.rawValue, name: "no audio",
        meaning: "Synthesis produced empty, silent, malformed, or "
            + "implausibly short audio -- the render happened but the "
            + "result failed validation.",
        remedy: "Retry, or try a different voice/engine. If it's consistent "
            + "for specific text, that text may be the trigger."
    ),
    .init(
        code: ExitCode.operationTimedOut.rawValue, name: "operation timed out",
        meaning: "A bounded operation (a synthesis render, or a `voices "
            + "--install --wait` poll) did not complete before its timeout.",
        remedy: "Increase --timeout, or retry -- this does not mean the "
            + "framework is broken, just that this one operation was slow."
    ),
    .init(
        code: ExitCode.voiceNotInstalled.rawValue, name: "voice not installed",
        meaning: "The requested voice exists in Apple's catalog but is not "
            + "installed on this Mac.",
        remedy: "Run `say2 voices --install \"<name>\"`, then retry."
    ),
    .init(
        code: ExitCode.frameworkUnavailable.rawValue, name: "framework unavailable",
        meaning: "The private Siri TTS framework itself is not present on "
            + "this system -- most likely an Apple macOS update removed or "
            + "renamed it. This is permanent, not a hiccup.",
        remedy: "Do not retry with the same engine. Switch to `--engine av` "
            + "(or `auto`, which does this automatically), and check for a "
            + "say2 update that supports the new framework shape."
    ),
    .init(
        code: ExitCode.internalFailure.rawValue, name: "internal failure",
        meaning: "An unexpected failure inside say2 itself -- not a usage "
            + "error, not a known engine/output condition.",
        remedy: "This is a say2 bug. Please report it with the full error "
            + "message and, if possible, `say2 doctor --json` output."
    ),
    .init(
        code: ExitCode.outputWriteFailed.rawValue, name: "output write failed",
        meaning: "Audio could not be written to the requested -o location "
            + "-- the directory doesn't exist, isn't writable, or (like "
            + "/dev) isn't a normal writable directory.",
        remedy: "Check the output path and its parent directory's "
            + "permissions. For benchmarking or measuring without writing "
            + "a file, use --no-output instead of -o /dev/null, which will "
            + "also fail this way."
    ),
    .init(
        code: ExitCode.cancelled.rawValue, name: "cancelled",
        meaning: "The operation was interrupted (SIGINT/SIGTERM) before it "
            + "completed.",
        remedy: "Expected when the caller cancels intentionally. No action "
            + "needed unless the cancellation was unintended."
    ),
]

public struct CLIError: LocalizedError, Sendable {
    public let message: String
    public let code: ExitCode

    public init(_ message: String, code: ExitCode) {
        self.message = message
        self.code = code
    }

    public var errorDescription: String? { message }
}

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case siri
    case av
    case auto
}

public enum AudioFormat: String, Codable, CaseIterable, Sendable {
    case wav
    case pcm
    case caf
}

public struct VoiceInfo: Codable, Equatable, Sendable {
    public let name: String
    public let language: String
    public let assetKey: String
    public let version: Int
    public let engine: String
    public var installed: Bool

    public init(
        name: String,
        language: String,
        assetKey: String,
        version: Int,
        engine: String,
        installed: Bool = true
    ) {
        self.name = name
        self.language = language
        self.assetKey = assetKey
        self.version = version
        self.engine = engine
        self.installed = installed
    }
}

public enum VoiceSubscriptionStatus: String, Codable, Equatable, Sendable {
    case requested
}

/// Confirms that macOS accepted a subscription request. It does not mean that
/// the asset has finished downloading; poll `refreshInstalledVoices()` for that.
public struct VoiceSubscriptionAcknowledgement: Codable, Equatable, Sendable {
    public let assetKey: String
    public let status: VoiceSubscriptionStatus

    public init(assetKey: String, status: VoiceSubscriptionStatus = .requested) {
        self.assetKey = assetKey
        self.status = status
    }
}

/// The locally observed result of asking macOS to purge one exact TTS asset.
/// Purging local bytes does not alter daemon subscriptions, so macOS may
/// download the asset again while a client still requests it.
public enum VoicePurgeStatus: String, Codable, Equatable, Sendable {
    case purgedLocalAsset = "purged-local-asset"
    case localAssetStillAvailable = "local-asset-still-available"
}

public struct VoicePurgeResult: Codable, Equatable, Sendable {
    public let assetKey: String
    public let nativeAssetKey: String
    public let name: String
    public let language: String
    public let status: VoicePurgeStatus
    public let localAssetAvailableAfterPurge: Bool

    public init(
        assetKey: String,
        nativeAssetKey: String,
        name: String,
        language: String,
        status: VoicePurgeStatus,
        localAssetAvailableAfterPurge: Bool
    ) {
        self.assetKey = assetKey
        self.nativeAssetKey = nativeAssetKey
        self.name = name
        self.language = language
        self.status = status
        self.localAssetAvailableAfterPurge = localAssetAvailableAfterPurge
    }
}

public enum VoiceInstallationState: String, Codable, Equatable, Sendable {
    case notInstalled = "not-installed"
    case waiting
    case installed
    case timedOut = "timed-out"
}

/// A daemon-observed installation state. Say2Core deliberately does not
/// expose percentage progress because the subscription API does not provide it.
public struct VoiceInstallationResult: Codable, Equatable, Sendable {
    public let identifier: String
    public let assetKey: String?
    public let state: VoiceInstallationState
    public let voice: VoiceInfo?
    public let elapsedSeconds: Double

    public init(
        identifier: String,
        assetKey: String?,
        state: VoiceInstallationState,
        voice: VoiceInfo? = nil,
        elapsedSeconds: Double = 0
    ) {
        self.identifier = identifier
        self.assetKey = assetKey
        self.state = state
        self.voice = voice
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct AudioSpec: Codable, Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let bitsPerChannel: Int
    public let bytesPerFrame: Int

    public init(sampleRate: Double, channels: Int, bitsPerChannel: Int, bytesPerFrame: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel
        self.bytesPerFrame = bytesPerFrame
    }

    public static let siriPCM = AudioSpec(
        sampleRate: 48_000,
        channels: 1,
        bitsPerChannel: 16,
        bytesPerFrame: 2
    )

    public var asbd: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bitsPerChannel),
            mReserved: 0
        )
    }
}

public struct RawWordTiming: Equatable, Sendable {
    public let start: Double
    public let range: NSRange

    public init(start: Double, range: NSRange) {
        self.start = start
        self.range = range
    }
}

/// A frame-aligned chunk that has already been decoded, resampled, and
/// downmixed to `AudioSpec.siriPCM`.
public struct NormalizedPCMChunk: Equatable, Sendable {
    public let pcm: Data
    public let spec: AudioSpec
    public let startFrame: Int
    public let frameCount: Int

    public init(pcm: Data, spec: AudioSpec, startFrame: Int, frameCount: Int) {
        self.pcm = pcm
        self.spec = spec
        self.startFrame = startFrame
        self.frameCount = frameCount
    }

    public var durationSeconds: Double {
        Double(frameCount) / spec.sampleRate
    }
}

public struct SynthesisStreamCompletion: Equatable, Sendable {
    public let frameCount: Int
    public let durationSeconds: Double
    public let timingsSupported: Bool

    public init(frameCount: Int, durationSeconds: Double, timingsSupported: Bool) {
        self.frameCount = frameCount
        self.durationSeconds = durationSeconds
        self.timingsSupported = timingsSupported
    }
}

/// Incremental events are request-scoped and ordered. Audio events contain only
/// validated 48 kHz mono Int16 PCM; encoded daemon packets are never exposed.
public enum SynthesisStreamEvent: Equatable, Sendable {
    case audio(NormalizedPCMChunk)
    case timings([RawWordTiming])
    case completed(SynthesisStreamCompletion)
    case cancelled
}

public struct WordTiming: Codable, Equatable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public let utf16Location: Int
    public let utf16Length: Int
    public let endDerived: Bool
}

public struct SynthesisOptions: Sendable {
    public var text = ""
    public var inputFile: String?
    public var voice: String?
    public var language: String?
    public var output: String?
    public var format: AudioFormat = .wav
    public var engine: EngineKind = .siri
    public var rate: Float = 1
    public var pitch: Float = 1
    public var volume: Float = 1
    public var json = false
    public var progress = false
    public var timingsPath: String?
    public var requestTimings = false
    public var prewarm = true
    public var timeout: TimeInterval = 120
    public var noOutput = false

    public init() {}
}

public struct VoicesOptions: Sendable {
    public var json = false
    public var available = false
    public var install: String?
    public var purge: String?
    public var status: String?
    public var wait = false
    public var timeout: TimeInterval?
    public var manage = false
    public var includeAV = false

    public init() {}
}

public struct DoctorOptions: Sendable {
    public var json = false
    public var skipProbe = false

    public init() {}
}

public struct ServeOptions: Sendable {
    public var host = "127.0.0.1"
    public var port: UInt16 = 8080
    public var engine: EngineKind = .siri
    public var verbose = false
    public var allowRemote = false

    public init() {}
}

public enum ParsedCommand: Sendable {
    case help
    case version
    case voices(VoicesOptions)
    case synthesize(SynthesisOptions)
    case doctor(DoctorOptions)
    case serve(ServeOptions)
    case explain(Int32)
    case exitCodes(json: Bool)
}

public struct SynthesisResult: Codable, Sendable {
    public let schemaVersion: Int
    public let engine: String
    public let fallbackFrom: String?
    public let voice: VoiceInfo
    public let audio: AudioResult
    public let timings: [WordTiming]
    public let timingsSupported: Bool
    public let elapsedSeconds: Double
    public let timeToFirstAudioSeconds: Double?
    /// Options that were accepted (didn't fail validation) but had no
    /// effect on this render, e.g. --pitch/--volume on the siri engine.
    /// Always present, empty when nothing was ignored, so a caller can
    /// assert on it without a nil check. A durable contract, not specific
    /// to any one flag: anything say2 accepts but cannot honor belongs here.
    public let ignoredOptions: [String]

    public init(
        engine: String,
        fallbackFrom: String?,
        voice: VoiceInfo,
        audio: AudioResult,
        timings: [WordTiming],
        timingsSupported: Bool,
        elapsedSeconds: Double,
        timeToFirstAudioSeconds: Double?,
        ignoredOptions: [String] = []
    ) {
        self.schemaVersion = say2SchemaVersion
        self.engine = engine
        self.fallbackFrom = fallbackFrom
        self.voice = voice
        self.audio = audio
        self.timings = timings
        self.timingsSupported = timingsSupported
        self.elapsedSeconds = elapsedSeconds
        self.timeToFirstAudioSeconds = timeToFirstAudioSeconds
        self.ignoredOptions = ignoredOptions
    }
}

public struct AudioResult: Codable, Sendable {
    public let format: String
    public let output: String
    public let sampleRate: Double
    public let channels: Int
    public let bitsPerChannel: Int
    public let bytes: Int
    public let sampleCount: Int
    public let durationSeconds: Double
    public let nonSilent: Bool
}

public struct RenderedAudio: Sendable {
    public let pcm: Data
    public let spec: AudioSpec
    public let voice: VoiceInfo
    public let timings: [RawWordTiming]
    public let timingsSupported: Bool
    public let engine: EngineKind
    public let elapsed: Double
    public let timeToFirstAudio: Double?
}
