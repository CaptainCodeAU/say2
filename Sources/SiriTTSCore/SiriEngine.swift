import CoreAudioTypes
import Darwin
import Foundation
internal import SiriTTSService

public final class SiriEngine: @unchecked Sendable {
    private let initialKeepActive: Bool
    private let sessionLock = NSLock()
    private var sessionStorage: DaemonSession?
    private let inventory = VoiceInventoryCache<[SynthesisVoice]>()
    private let downloadableCatalogLock = NSLock()
    private var downloadableCatalogStorage: [SiriDownloadableVoice]?
    private let lifecycle = SynthesisLifecycle<SynthesisRequest>()
    private let installationWaitLock = NSLock()
    private var installationWaits: [UUID: Bool] = [:]

    public init(keepActive: Bool = false) {
        initialKeepActive = keepActive
    }

    public var isFrameworkPresent: Bool {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService",
            RTLD_LAZY | RTLD_LOCAL
        ) else { return false }
        dlclose(handle)
        return true
    }

    public func connect() throws {
        guard isFrameworkPresent else {
            throw CLIError(
                "The private Siri TTS framework or resident daemon is unavailable",
                code: .daemonUnreachable
            )
        }
        guard session.invokeDaemon() else {
            throw CLIError(
                "The private Siri TTS framework or resident daemon is unavailable",
                code: .daemonUnreachable
            )
        }
    }

    public func enableKeepActive() {
        guard isFrameworkPresent else { return }
        session.keepActive = true
    }

    public func voices(timeout: TimeInterval = 10) throws -> [VoiceInfo] {
        try connect()
        return try fetchNativeVoices(timeout: timeout, refresh: false).map(Self.describe)
    }

    /// Performs an authoritative `downloadedVoices` query and replaces the
    /// cached installed inventory only after a successful response.
    public func refreshInstalledVoices(timeout: TimeInterval = 10) throws -> [VoiceInfo] {
        try connect()
        return try fetchNativeVoices(timeout: timeout, refresh: true).map(Self.describe)
    }

    /// Invalidates only SiriTTSCore's in-memory snapshot. It does not contact
    /// macOS or change installed assets.
    public func invalidateVoiceCache() {
        inventory.invalidate()
    }

    public func availableVoices(timeout: TimeInterval = 15) throws -> [VoiceInfo] {
        try connect()
        let installed = try fetchNativeVoices(timeout: timeout, refresh: true)
        do {
            let catalog = try downloadableVoices(refresh: true)
            var matchedInstalledKeys = Set<String>()
            var available = catalog.map { voice in
                let matches = installed.filter(voice.matchesInstalled)
                matchedInstalledKeys.formUnion(matches.map(\.assetKey))
                // sirittsd can retain a stale row after MobileAsset has physically
                // deleted the voice, while an unowned bundle can remain after
                // unsubscription. Installed means both usable and present.
                return voice.info(installed: voice.locallyAvailable && !matches.isEmpty)
            }
            // Never hide a daemon-installed voice merely because a future catalog
            // schema no longer contains it.
            available.append(contentsOf: installed
                .filter { !matchedInstalledKeys.contains($0.assetKey) }
                .map(Self.describe))
            return available
        } catch {
            return try availableNativeVoices(timeout: timeout).map { voice in
                var info = Self.describe(voice)
                info.installed = installed.contains { $0.assetKey == voice.assetKey }
                return info
            }
        }
    }

    /// Returns Apple's installed preview audio in place without copying it.
    public func previewURL(for voice: VoiceInfo) throws -> URL {
        try previewURL(assetKey: voice.assetKey)
    }

    public func previewURL(assetKey: String) throws -> URL {
        guard let voice = try SiriDownloadableVoiceCatalog.resolve(
            assetKey,
            in: downloadableVoices()
        ) else {
            throw CLIError(
                "Available Siri voice '\(assetKey)' was not found",
                code: .voiceNotFound
            )
        }
        return try SiriVoicePreview.url(for: voice)
    }

    /// Requests physical deletion of the exact locally installed TTS asset.
    /// No daemon or client subscription is changed by this operation.
    public func purgeVoice(
        identifier: String,
        timeout: TimeInterval = 30
    ) throws -> VoicePurgeResult {
        guard (1...300).contains(timeout) else {
            throw CLIError("Purge timeout must be from 1 through 300 seconds", code: .usage)
        }
        try connect()
        let catalog = try downloadableVoices(refresh: true)
        guard let catalogVoice = try SiriDownloadableVoiceCatalog.resolve(
            identifier,
            in: catalog
        ) else {
            throw CLIError(
                "Available Siri voice '\(identifier)' was not found",
                code: .voiceNotFound
            )
        }
        guard catalogVoice.locallyAvailable else {
            throw CLIError(
                "Siri voice '\(catalogVoice.name)' is not locally installed",
                code: .voiceNotFound
            )
        }
        let outcome = try SiriDownloadableVoiceCatalog.purge(
            catalogAssetKey: catalogVoice.catalogAssetKey,
            installedNativeAssetKey: catalogVoice.nativeAssetKey,
            timeout: timeout
        )
        inventory.invalidate()
        downloadableCatalogLock.withLock { downloadableCatalogStorage = nil }
        return VoicePurgeResult(
            assetKey: catalogVoice.catalogAssetKey,
            nativeAssetKey: catalogVoice.nativeAssetKey,
            name: catalogVoice.name,
            language: catalogVoice.language,
            status: outcome.localAssetAvailableAfterPurge
                ? .localAssetStillAvailable
                : .purgedLocalAsset,
            localAssetAvailableAfterPurge: outcome.localAssetAvailableAfterPurge
        )
    }

    @discardableResult
    public func installVoice(
        named name: String,
        timeout: TimeInterval = 30
    ) throws -> VoiceSubscriptionAcknowledgement {
        try connect()
        if let catalog = try? downloadableVoices() {
            guard let catalogVoice = try SiriDownloadableVoiceCatalog.resolve(
                name,
                in: catalog
            ) else {
                throw CLIError("Available Siri voice '\(name)' was not found", code: .voiceNotFound)
            }
            try subscribe(catalogVoice.makeSynthesisVoice(), timeout: timeout)
            invalidateVoiceCache()
            return VoiceSubscriptionAcknowledgement(assetKey: catalogVoice.catalogAssetKey)
        }
        // Preserve compatibility on builds where predefinedVoices works but the
        // newer TTS asset catalog surface is unavailable.
        let available: [SynthesisVoice]
        do {
            available = try availableNativeVoices(timeout: timeout)
        } catch {
            throw CLIError(
                "This macOS build did not expose an installable Siri voice catalog: \(error.localizedDescription)",
                code: .daemonUnreachable
            )
        }
        guard let voice = available.first(where: {
            $0.name?.caseInsensitiveCompare(name) == .orderedSame ||
            $0.assetKey.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw CLIError("Available Siri voice '\(name)' was not found", code: .voiceNotFound)
        }
        try subscribe(voice, timeout: timeout)
        invalidateVoiceCache()
        return VoiceSubscriptionAcknowledgement(assetKey: voice.assetKey)
    }

    /// Requests a catalog subscription by Apple's stable asset identity.
    /// Success means the request was acknowledged, not that installation has
    /// completed. Poll `refreshInstalledVoices()` for completion.
    @discardableResult
    public func subscribeVoice(
        assetKey: String,
        timeout: TimeInterval = 30
    ) throws -> VoiceSubscriptionAcknowledgement {
        try connect()
        if let catalog = try? downloadableVoices() {
            guard let catalogVoice = try SiriDownloadableVoiceCatalog.resolve(
                assetKey,
                in: catalog,
                allowDisplayName: false
            ) else {
                throw CLIError(
                    "Available Siri voice asset '\(assetKey)' was not found",
                    code: .voiceNotFound
                )
            }
            try subscribe(catalogVoice.makeSynthesisVoice(), timeout: timeout)
            invalidateVoiceCache()
            return VoiceSubscriptionAcknowledgement(assetKey: catalogVoice.catalogAssetKey)
        }
        // Preserve the reconstructed predefinedVoices path as a fallback for
        // other compatible macOS builds.
        let available: [SynthesisVoice]
        do {
            available = try availableNativeVoices(timeout: timeout)
        } catch {
            throw CLIError(
                "This macOS build did not expose an installable Siri voice catalog: \(error.localizedDescription)",
                code: .daemonUnreachable
            )
        }
        guard let voice = available.first(where: { $0.assetKey == assetKey }) else {
            throw CLIError(
                "Available Siri voice asset '\(assetKey)' was not found",
                code: .voiceNotFound
            )
        }
        try subscribe(voice, timeout: timeout)
        invalidateVoiceCache()
        return VoiceSubscriptionAcknowledgement(assetKey: voice.assetKey)
    }

    /// Reports installed only when Apple's downloadable catalog proves local
    /// content and the daemon exposes the matching generation.
    public func installationStatus(
        for identifier: String,
        timeout: TimeInterval = 10
    ) throws -> VoiceInstallationResult {
        let installed = try refreshInstalledVoices(timeout: timeout)
        if let catalog = try? downloadableVoices(refresh: true),
           let catalogVoice = try SiriDownloadableVoiceCatalog.resolve(identifier, in: catalog) {
            if catalogVoice.locallyAvailable,
               installed.contains(where: catalogVoice.matchesInstalled) {
                let stableVoice = catalogVoice.info(installed: true)
                return VoiceInstallationResult(
                    identifier: identifier,
                    assetKey: catalogVoice.catalogAssetKey,
                    state: .installed,
                    voice: stableVoice
                )
            }
            return VoiceInstallationResult(
                identifier: identifier,
                assetKey: catalogVoice.catalogAssetKey,
                state: .notInstalled
            )
        }
        if let voice = installed.first(where: {
            $0.assetKey.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.name.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return VoiceInstallationResult(
                identifier: identifier,
                assetKey: voice.assetKey,
                state: .installed,
                voice: voice
            )
        }
        return VoiceInstallationResult(
            identifier: identifier,
            assetKey: nil,
            state: .notInstalled
        )
    }

    /// Polls for both byte-level local availability and a usable daemon voice
    /// after a subscription request. A timeout does not cancel the request.
    public func waitForVoiceInstallation(
        assetKey: String,
        identifier: String? = nil,
        timeout: TimeInterval = 300,
        pollInterval: TimeInterval = 2,
        onUpdate: (@Sendable (VoiceInstallationResult) -> Void)? = nil
    ) throws -> VoiceInstallationResult {
        guard timeout >= 1, timeout <= 3_600 else {
            throw CLIError("Installation timeout must be from 1 through 3600 seconds", code: .usage)
        }
        guard pollInterval > 0 else {
            throw CLIError("Installation polling interval must be positive", code: .usage)
        }
        let waitID = UUID()
        installationWaitLock.withLock { installationWaits[waitID] = false }
        defer { _ = installationWaitLock.withLock { installationWaits.removeValue(forKey: waitID) } }
        return try VoiceInstallationMonitor.poll(
            identifier: identifier ?? assetKey,
            assetKey: assetKey,
            timeout: timeout,
            pollInterval: pollInterval,
            isCancelled: { [self] in
                installationWaitLock.withLock { installationWaits[waitID] ?? true }
            },
            onUpdate: onUpdate,
            fetchInstalled: { [self] in
                try availableVoices(timeout: min(10, timeout)).filter(\.installed)
            }
        )
    }

    /// Loads the selected Siri voice into the resident service without
    /// producing audio. This call shares the synthesis lane, so it cannot race
    /// an active render.
    @discardableResult
    public func prewarm(
        voice: String? = nil,
        language: String? = nil,
        timeout: TimeInterval = 30
    ) throws -> VoiceInfo {
        let token = lifecycle.acquire()
        defer { lifecycle.finish(token) }
        try connect()
        try throwIfCancelled(token)
        let nativeVoices = try fetchNativeVoices()
        var options = SynthesisOptions()
        options.text = "Siri TTS prewarm"
        options.voice = voice
        options.language = language
        let selected = try selectVoice(options, from: nativeVoices)
        let request = SynthesisRequest(text: options.text, voice: selected)
        guard lifecycle.attach(request, to: token) else {
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }
        let result = performPrewarm(request, token: token, timeout: timeout)
        try throwIfCancelled(token)
        guard let result else {
            session.cancel(request: request)
            throw CLIError("Timed out while prewarming Siri", code: .daemonUnreachable)
        }
        do {
            try result.get()
        } catch {
            throw CLIError(
                "Siri prewarm failed: \(error.localizedDescription)",
                code: .daemonUnreachable
            )
        }
        guard lifecycle.claimCompletion(token) else {
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }
        return describeSelected(selected, requestedAssetKey: voice)
    }

    public func synthesize(
        _ options: SynthesisOptions,
        onPCMChunk: (@Sendable (Data) -> Void)? = nil,
        onEvent: (@Sendable (SynthesisStreamEvent) -> Void)? = nil
    ) throws -> RenderedAudio {
        let token = lifecycle.acquire()
        defer { lifecycle.finish(token) }
        let callbackQueue = DispatchQueue(
            label: "SiriTTSCore.synthesis-events.\(UUID().uuidString)"
        )
        let callbackQueueKey = DispatchSpecificKey<UInt8>()
        callbackQueue.setSpecific(key: callbackQueueKey, value: 1)
        let emitSerialized: (@Sendable (@Sendable () -> Void) -> Void) = { action in
            if DispatchQueue.getSpecific(key: callbackQueueKey) != nil {
                action()
            } else {
                callbackQueue.sync(execute: action)
            }
        }
        let emitCancellation: @Sendable () -> Void = {
            emitSerialized { onEvent?(.cancelled) }
        }

        try connect()
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        let nativeVoices = try fetchNativeVoices()
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        let voice = try selectVoice(options, from: nativeVoices)
        let request = SynthesisRequest(text: options.text, voice: voice)
        request.synthesisContext.rate = options.rate
        request.synthesisContext.pitch = options.pitch
        request.synthesisContext.volume = options.volume
        guard lifecycle.attach(request, to: token) else {
            emitCancellation()
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }

        let accumulator = SiriAccumulator(text: options.text)
        let started = Date()

        let timingsSupported = options.requestTimings ? queryTimings(for: voice) : false
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        if options.prewarm {
            _ = performPrewarm(
                request,
                token: token,
                timeout: min(30, options.timeout)
            )
        }
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        request.synthesisContext.didGenerateAudio = { chunk in
            callbackQueue.sync {
                guard self.lifecycle.acceptsCallbacks(for: token) else { return }
                let chunks = accumulator.append(chunk)
                for normalized in chunks {
                    guard self.lifecycle.acceptsCallbacks(for: token) else { return }
                    onPCMChunk?(normalized.pcm)
                    onEvent?(.audio(normalized))
                }
            }
        }
        request.synthesisContext.didGenerateWordTimings = { timings in
            callbackQueue.sync {
                guard self.lifecycle.acceptsCallbacks(for: token) else { return }
                let accepted = accumulator.append(timings)
                if !accepted.isEmpty {
                    onEvent?(.timings(accepted))
                }
            }
        }

        let done = DispatchSemaphore(value: 0)
        let completion = LockedResult<Void>()
        let synthesisStarted = Date()
        session.synthesize(request: request) { error in
            if let error {
                completion.set(.failure(error))
            } else {
                completion.set(.success(()))
            }
            done.signal()
        }

        let deadline = Date(timeIntervalSinceNow: options.timeout)
        var completed = false
        while Date() < deadline {
            try throwIfCancelled(token, notifyCancellation: emitCancellation)
            if done.wait(timeout: .now() + 0.05) == .success {
                completed = true
                break
            }
        }
        guard completed else {
            _ = lifecycle.cancelActive()
            session.cancel(request: request)
            throw CLIError("Timed out waiting for Siri synthesis", code: .daemonUnreachable)
        }
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        do {
            try completion.get().get()
        } catch {
            let nsError = error as NSError
            if nsError.code == NSUserCancelledError {
                emitCancellation()
                throw CLIError("Synthesis cancelled", code: .cancelled)
            }
            throw CLIError(
                "Siri synthesis failed: \(error.localizedDescription)",
                code: .daemonUnreachable
            )
        }

        let snapshot = callbackQueue.sync {
            let tail = accumulator.finish()
            for normalized in tail {
                guard lifecycle.acceptsCallbacks(for: token) else { break }
                onPCMChunk?(normalized.pcm)
                onEvent?(.audio(normalized))
            }
            return accumulator.snapshot()
        }
        if let error = snapshot.error { throw error }
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        let spec = AudioSpec.siriPCM
        let acceptance = try AudioIO.validatePCM(snapshot.data, spec: spec, text: options.text)
        let validTimings = WordTimingMapper.sanitize(
            snapshot.timings,
            in: options.text,
            duration: acceptance.durationSeconds
        )
        let elapsed = Date().timeIntervalSince(started)
        let rendered = RenderedAudio(
            pcm: snapshot.data,
            spec: spec,
            voice: describeSelected(voice, requestedAssetKey: options.voice),
            timings: validTimings,
            timingsSupported: timingsSupported,
            engine: .siri,
            elapsed: elapsed,
            timeToFirstAudio: snapshot.firstAudioAt.map { $0.timeIntervalSince(synthesisStarted) }
        )
        guard lifecycle.claimCompletion(token) else {
            emitCancellation()
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }
        emitSerialized {
            onEvent?(.completed(SynthesisStreamCompletion(
                frameCount: acceptance.sampleCount,
                durationSeconds: acceptance.durationSeconds,
                timingsSupported: timingsSupported
            )))
        }
        return rendered
    }

    public func cancel() {
        installationWaitLock.withLock {
            for waitID in Array(installationWaits.keys) {
                installationWaits[waitID] = true
            }
        }
        let request = lifecycle.cancelActive()
        if let request { session.cancel(request: request) }
    }

    public func isANECompiled(voiceName: String, timeout: TimeInterval = 5) -> Bool? {
        guard (try? connect()) != nil,
              let voices = try? fetchNativeVoices(timeout: timeout),
              let voice = voices.first(where: {
                  $0.name?.caseInsensitiveCompare(voiceName) == .orderedSame
              }) else { return nil }
        let done = DispatchSemaphore(value: 0)
        let state = LockedResult<Bool>()
        session.isANEModelCompiled(matching: voice) { compiled, error in
            if let error { state.set(.failure(error)) }
            else { state.set(.success(compiled)) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return try? state.get().get()
    }

    private func performPrewarm(
        _ request: SynthesisRequest,
        token: SynthesisLifecycle<SynthesisRequest>.Token,
        timeout: TimeInterval
    ) -> Result<Void, Error>? {
        let done = DispatchSemaphore(value: 0)
        let state = LockedResult<Void>()
        session.prewarm(request: request) { error in
            if let error {
                state.set(.failure(error))
            } else {
                state.set(.success(()))
            }
            done.signal()
        }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if lifecycle.isCancelled(token) { return nil }
            if done.wait(timeout: .now() + 0.05) == .success {
                return state.get()
            }
        }
        return nil
    }

    private func queryTimings(for voice: SynthesisVoice, timeout: TimeInterval = 5) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let state = LockedResult<Bool>()
        session.queryWordTimingSupport(voice: voice) {
            state.set(.success($0))
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return false }
        return (try? state.get().get()) ?? false
    }

    private func fetchNativeVoices(
        timeout: TimeInterval = 10,
        refresh: Bool = false
    ) throws -> [SynthesisVoice] {
        let native = try inventory.value(refresh: refresh) {
            let done = DispatchSemaphore(value: 0)
            let state = LockedResult<[SynthesisVoice]>()
            session.downloadedVoices(matching: nil) {
                state.set(.success($0))
                done.signal()
            }
            guard done.wait(timeout: .now() + timeout) == .success else {
                throw CLIError(
                    "Timed out while asking sirittsd for installed voices",
                    code: .daemonUnreachable
                )
            }
            let voices = try state.get().get()
            return voices
        }
        // sirittsd can retain a downloaded-voice row after MobileAsset removes
        // that generation. Keep unknown future rows for compatibility, but do
        // not expose a catalog-matched row whose exact local content is absent.
        guard let catalog = try? downloadableVoices(refresh: refresh) else {
            return native
        }
        return SiriDownloadableVoiceCatalog.filterLocallyInstalled(
            native,
            against: catalog
        )
    }

    private func availableNativeVoices(timeout: TimeInterval) throws -> [SynthesisVoice] {
        try connect()
        let done = DispatchSemaphore(value: 0)
        let state = LockedResult<[SynthesisVoice]>()
        Task {
            do { state.set(.success(try await session.predefinedVoices())) }
            catch { state.set(.failure(error)) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw CLIError("Timed out while reading available Siri voices", code: .daemonUnreachable)
        }
        return try state.get().get()
    }

    private func selectVoice(
        _ options: SynthesisOptions,
        from voices: [SynthesisVoice]
    ) throws -> SynthesisVoice {
        let candidates = voices.filter {
            options.language == nil ||
            $0.language.caseInsensitiveCompare(options.language!) == .orderedSame
        }
        if let wanted = options.voice {
            if let match = candidates.first(where: {
                $0.name?.caseInsensitiveCompare(wanted) == .orderedSame ||
                $0.assetKey.caseInsensitiveCompare(wanted) == .orderedSame
            }) {
                return match
            }
            if let catalogVoice = try? downloadableVoices().first(where: {
                $0.catalogAssetKey.caseInsensitiveCompare(wanted) == .orderedSame
            }), let match = candidates.first(where: catalogVoice.matchesInstalled) {
                return match
            }
            throw CLIError(
                "Siri voice '\(wanted)' was not found. Run `siri-tts voices`.",
                code: .voiceNotFound
            )
        }
        guard let first = candidates.first else {
            throw CLIError("No matching installed Siri voices were reported", code: .voiceNotFound)
        }
        return first
    }

    private static func describe(_ voice: SynthesisVoice) -> VoiceInfo {
        VoiceInfo(
            name: voice.name ?? "Unnamed",
            language: voice.language,
            assetKey: voice.assetKey,
            version: voice.version,
            engine: EngineKind.siri.rawValue
        )
    }

    private static func describeInstalled(_ voice: VoiceInfo, as assetKey: String) -> VoiceInfo {
        VoiceInfo(
            name: voice.name,
            language: voice.language,
            assetKey: assetKey,
            version: voice.version,
            engine: voice.engine,
            installed: true
        )
    }

    /// Strict clients require the terminal response to preserve the catalog
    /// identifier they requested, even though sirittsd itself uses a versioned
    /// synthesis key internally.
    private func describeSelected(
        _ voice: SynthesisVoice,
        requestedAssetKey: String?
    ) -> VoiceInfo {
        let native = Self.describe(voice)
        guard let requestedAssetKey,
              let catalogVoice = try? downloadableVoices().first(where: {
                  $0.catalogAssetKey.caseInsensitiveCompare(requestedAssetKey) == .orderedSame
              }), catalogVoice.matchesInstalled(voice) else {
            return native
        }
        return Self.describeInstalled(native, as: requestedAssetKey)
    }

    private func downloadableVoices(refresh: Bool = false) throws -> [SiriDownloadableVoice] {
        if !refresh, let cached = downloadableCatalogLock.withLock({
            downloadableCatalogStorage
        }) {
            return cached
        }
        let loaded = try SiriDownloadableVoiceCatalog.voices()
        downloadableCatalogLock.withLock { downloadableCatalogStorage = loaded }
        return loaded
    }

    private func subscribe(_ voice: SynthesisVoice, timeout: TimeInterval) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let state = LockedResult<Void>()
        session.subscribe(voices: [voice]) { error in
            if let error {
                state.set(.failure(error))
            } else {
                state.set(.success(()))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw CLIError(
                "Timed out while asking macOS to install the voice",
                code: .daemonUnreachable
            )
        }
        do {
            try state.get().get()
        } catch {
            if let error = error as? CLIError { throw error }
            throw CLIError(
                "macOS rejected the voice installation request: \(error.localizedDescription)",
                code: .daemonUnreachable
            )
        }
    }

    private func throwIfCancelled(
        _ token: SynthesisLifecycle<SynthesisRequest>.Token,
        notifyCancellation: () -> Void = {}
    ) throws {
        if lifecycle.isCancelled(token) {
            notifyCancellation()
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }
    }

    /// Private framework classes are instantiated only after a successful
    /// presence check. This preserves weak-link behavior on unsupported builds.
    private var session: DaemonSession {
        sessionLock.withLock {
            if let sessionStorage {
                return sessionStorage
            }
            let value = DaemonSession()
            value.keepActive = initialKeepActive
            sessionStorage = value
            return value
        }
    }
}

private final class SiriAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private let normalizer = SiriAudioNormalizer()
    private var data = Data()
    private var timings: [RawWordTiming] = []
    private var firstAudioAt: Date?
    private var error: Error?
    private var lastTimingStart: Double = -.infinity
    private var lastTimingRangeEnd = 0
    private var closed = false

    init(text: String) {
        self.text = text
    }

    func append(_ chunk: AudioData) -> [NormalizedPCMChunk] {
        lock.withLock {
            guard error == nil, !closed else { return [] }
            do {
                let normalized = try normalizer.append(SiriSourceAudioChunk(
                    audioData: chunk.audioData,
                    format: chunk.asbd,
                    packetDescriptions: chunk.packetDescriptions,
                    packetCount: chunk.packetCount,
                    reportedSampleCount: Int(chunk.sampleCount)
                ))
                appendNormalized(normalized)
                return normalized
            } catch let caught {
                error = caught
                return []
            }
        }
    }

    func append(_ values: [WordTimingInfo]) -> [RawWordTiming] {
        lock.withLock {
            guard error == nil, !closed else { return [] }
            let utf16Count = text.utf16.count
            var accepted: [RawWordTiming] = []
            for value in values {
                let start = value.startTime
                let range = value.textRange
                let (rangeEnd, overflow) = range.location.addingReportingOverflow(range.length)
                guard start.isFinite, start >= 0,
                      range.location >= 0, range.length >= 0,
                      !overflow, rangeEnd <= utf16Count,
                      start >= lastTimingStart,
                      range.location >= lastTimingRangeEnd else {
                    continue
                }
                let timing = RawWordTiming(start: start, range: range)
                timings.append(timing)
                accepted.append(timing)
                lastTimingStart = start
                lastTimingRangeEnd = rangeEnd
            }
            return accepted
        }
    }

    func finish() -> [NormalizedPCMChunk] {
        lock.withLock {
            guard error == nil, !closed else { return [] }
            closed = true
            do {
                let normalized = try normalizer.finish()
                appendNormalized(normalized)
                return normalized
            } catch let caught {
                error = caught
                return []
            }
        }
    }

    func snapshot() -> (
        data: Data,
        timings: [RawWordTiming],
        firstAudioAt: Date?,
        error: Error?
    ) {
        lock.withLock { (data, timings, firstAudioAt, error) }
    }

    private func appendNormalized(_ chunks: [NormalizedPCMChunk]) {
        for chunk in chunks where !chunk.pcm.isEmpty {
            if firstAudioAt == nil { firstAudioAt = Date() }
            data.append(chunk.pcm)
        }
    }
}

final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func set(_ newValue: Result<Value, Error>) {
        lock.withLock { value = newValue }
    }

    func get() -> Result<Value, Error> {
        lock.withLock {
            value ?? .failure(CLIError("Operation completed without a result", code: .internalFailure))
        }
    }
}
