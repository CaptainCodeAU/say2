import Darwin
import Foundation
import ObjectiveC.runtime
internal import SiriTTSService

/// A premium Siri voice advertised by the platform's local TTS asset catalog.
/// `catalogAssetKey` is deliberately version-independent: UAF catalog rows use
/// version zero until downloaded, while the daemon reports the installed content
/// version. Apple's TTS identifier remains stable across that transition.
struct SiriDownloadableVoice: Equatable, Sendable {
    let catalogAssetKey: String
    let name: String
    let language: String
    let technology: String
    let gender: Int
    let version: Int
    let relativeDesirability: Int
    let locallyAvailable: Bool
    let downloadSize: Int
    let matchingNativeIdentityPrefixes: [String]

    var nativeAssetKey: String {
        "\(nativeIdentityPrefix)\(version)"
    }

    private var nativeIdentityPrefix: String {
        "\(language):\(technology):\(genderName):\(name):premium:"
    }

    func matchesInstalled(_ voice: SynthesisVoice) -> Bool {
        matchingNativeIdentityPrefixes.contains { voice.assetKey.hasPrefix($0) }
    }

    func matchesInstalled(_ voice: VoiceInfo) -> Bool {
        matchingNativeIdentityPrefixes.contains { voice.assetKey.hasPrefix($0) }
    }

    func makeSynthesisVoice() throws -> SynthesisVoice {
        guard let type = Self.voiceType(for: technology) else {
            throw CLIError(
                "The Siri catalog advertised unsupported voice technology '\(technology)'",
                code: .noCompatibleEngine
            )
        }
        let voice = SynthesisVoice(language: language, name: name)
        guard voice.responds(to: NSSelectorFromString("setType:")),
              voice.responds(to: NSSelectorFromString("setGender:")),
              voice.responds(to: NSSelectorFromString("setFootprint:")) else {
            throw CLIError(
                "This macOS build cannot construct a Siri subscription identity safely",
                code: .noCompatibleEngine
            )
        }
        voice.setValue(type, forKey: "type")
        voice.setValue(gender, forKey: "gender")
        voice.setValue(2, forKey: "footprint") // premium
        voice.version = version
        guard voice.assetKey == nativeAssetKey else {
            throw CLIError(
                "The Siri catalog identity for '\(name)' could not be reconstructed safely",
                code: .noCompatibleEngine
            )
        }
        return voice
    }

    func info(installed: Bool) -> VoiceInfo {
        VoiceInfo(
            name: name,
            language: language,
            assetKey: catalogAssetKey,
            version: version,
            engine: EngineKind.siri.rawValue,
            installed: installed
        )
    }

    private var genderName: String {
        switch gender {
        case 1: "male"
        case 2: "female"
        case 3: "neutral"
        default: "undefined"
        }
    }

    fileprivate static func voiceType(for technology: String) -> Int? {
        switch technology {
        case "vocalizer": 1
        case "custom": 2
        case "gryphon": 3
        case "neural": 4
        case "neuralAX": 5
        case "natural": 6
        default: nil
        }
    }
}

struct SiriCatalogAssetMetadata: Equatable, Sendable {
    let identifier: String
    let name: String
    let language: String
    let technology: String
    let gender: Int
    let quality: String
    let version: Int
    let relativeDesirability: Int
    let locallyAvailable: Bool
    let downloadSize: Int

    var nativeAssetKey: String {
        "\(nativeIdentityPrefix)\(version)"
    }

    var nativeIdentityPrefix: String {
        let genderName: String
        switch gender {
        case 1: genderName = "male"
        case 2: genderName = "female"
        case 3: genderName = "neutral"
        default: genderName = "undefined"
        }
        return "\(language):\(technology):\(genderName):\(name):\(quality):"
    }
}

struct SiriTTSAssetPurgeOutcome: Equatable, Sendable {
    let localAssetAvailableAfterPurge: Bool
}

struct SiriUAFLocalAssetState: Equatable, Sendable {
    let contentVersion: Int
    let assetDataPath: String
}

enum SiriDownloadableVoiceCatalog {
    private static let siriFramework =
        "/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService"
    private static let textToSpeechFramework =
        "/System/Library/PrivateFrameworks/TextToSpeech.framework/TextToSpeech"
    private static let mobileAssetFramework =
        "/System/Library/PrivateFrameworks/MobileAsset.framework/MobileAsset"
    private static let uafSiriAssetType =
        "com.apple.MobileAsset.UAF.Siri.TextToSpeech"
    private static let uafSiriAssetRoot =
        "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto/"

    /// Reads only the local system catalog. This does not invoke TTSAsset download,
    /// cancellation, purge, or any voice/settings mutation API.
    static func voices() throws -> [SiriDownloadableVoice] {
        try withAssets { assets in
            let localStates = localAssetStates()
            let metadata = assets.compactMap(readMetadata).map {
                applyingLocalState(to: $0, states: localStates)
            }
            let catalog = preferredVoices(from: metadata)
            guard !catalog.isEmpty else {
                throw unavailable("the TTS asset catalog contained no compatible premium Siri voices")
            }
            return catalog
        }
    }

    /// Removes stale daemon rows only when the downloadable catalog can match
    /// them conclusively to content that is absent on disk. Unmatched rows are
    /// retained so a newer macOS catalog schema does not hide usable voices.
    static func filterLocallyInstalled(
        _ installed: [SynthesisVoice],
        against catalog: [SiriDownloadableVoice]
    ) -> [SynthesisVoice] {
        installed.filter { native in
            let matches = catalog.filter { $0.matchesInstalled(native) }
            return matches.isEmpty || matches.contains(where: \.locallyAvailable)
        }
    }

    /// Requests physical deletion of exactly one locally available UAF asset.
    /// This deliberately does not mutate any client's subscription.
    static func purge(
        catalogAssetKey: String,
        installedNativeAssetKey: String,
        timeout: TimeInterval
    ) throws -> SiriTTSAssetPurgeOutcome {
        let target = try withAssets { assets in
            let localStates = localAssetStates()
            let records = assets.compactMap { asset in
                readMetadata(asset).map {
                    (asset, applyingLocalState(to: $0, states: localStates))
                }
            }
            let matchIndex = try exactPurgeCandidateIndex(
                catalogAssetKey: catalogAssetKey,
                installedNativeAssetKey: installedNativeAssetKey,
                metadata: records.map(\.1)
            )
            let match = records[matchIndex]
            guard match.1.locallyAvailable else {
                throw CLIError(
                    "Refusing to purge '\(catalogAssetKey)': the exact installed asset is not locally available",
                    code: .noCompatibleEngine
                )
            }
            guard boolValue(match.0, selector: "purgeable") == true else {
                throw CLIError(
                    "Refusing to purge '\(catalogAssetKey)': the exact installed asset is not purgeable",
                    code: .noCompatibleEngine
                )
            }
            let specifier = uafAssetSpecifier(for: match.1)
            let provenPath = localStates?[specifier]?.assetDataPath ?? localBundlePath(match.0)
            guard let path = provenPath,
                  path.hasPrefix(uafSiriAssetRoot),
                  path.hasSuffix("/AssetData") else {
                throw CLIError(
                    "Refusing to purge '\(catalogAssetKey)': its local UAF asset path could not be proven",
                    code: .noCompatibleEngine
                )
            }
            return (
                assetSpecifier: specifier,
                localPath: path
            )
        }

        try requestMobileAssetElimination(assetSpecifier: target.assetSpecifier)

        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            // TTSAsset's proxy can retain a stale in-process `locallyAvailable`
            // value after mobileassetd has removed the bytes. The exact path was
            // proven above from the exact installed generation, so its absence is
            // the authoritative physical-deletion result.
            if !FileManager.default.fileExists(atPath: target.localPath) {
                return SiriTTSAssetPurgeOutcome(localAssetAvailableAfterPurge: false)
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return SiriTTSAssetPurgeOutcome(
            localAssetAvailableAfterPurge: FileManager.default.fileExists(
                atPath: target.localPath
            )
        )
    }

    /// Validates the private selector ABI without invoking a purge.
    static func validatePurgeABI() throws {
        guard let handle = dlopen(mobileAssetFramework, RTLD_LAZY | RTLD_LOCAL) else {
            throw unavailable("MobileAsset could not be loaded")
        }
        defer { dlclose(handle) }
        guard let selectorClass = NSClassFromString("MAAutoAssetSelector"),
              let autoAssetClass = NSClassFromString("MAAutoAsset") else {
            throw unavailable("the MobileAsset elimination classes are absent")
        }
        let initializer = NSSelectorFromString("initForAssetType:withAssetSpecifier:")
        let eliminate = NSSelectorFromString("eliminateAllForSelectorSync:")
        guard methodEncoding(selectorClass, initializer) == "@32@0:8@16@24",
              classMethodEncoding(autoAssetClass, eliminate) == "@24@0:8@16" else {
            throw unavailable("the MobileAsset elimination ABI is incompatible")
        }
    }

    static func uafAssetSpecifier(for metadata: SiriCatalogAssetMetadata) -> String {
        let language = metadata.language.replacingOccurrences(of: "-", with: "_")
        let name = metadata.name.lowercased(with: Locale(identifier: "en_US_POSIX"))
        return "com.apple.siri.tts.voice.\(language).\(name).\(metadata.technology).\(metadata.quality)"
    }

    static func exactPurgeCandidateIndex(
        catalogAssetKey: String,
        installedNativeAssetKey: String,
        metadata: [SiriCatalogAssetMetadata]
    ) throws -> Int {
        let matches = metadata.indices.filter { index in
            let row = metadata[index]
            return row.identifier.caseInsensitiveCompare(catalogAssetKey) == .orderedSame &&
                row.nativeAssetKey == installedNativeAssetKey
        }
        guard matches.count == 1, let match = matches.first else {
            let detail = matches.isEmpty
                ? "no TTS asset matched the exact installed generation"
                : "more than one TTS asset matched the installed generation"
            throw CLIError(
                "Refusing to purge '\(catalogAssetKey)': \(detail)",
                code: .noCompatibleEngine
            )
        }
        return match
    }

    private static func withAssets<T>(
        _ body: ([NSObject]) throws -> T
    ) throws -> T {
        guard let siriHandle = dlopen(siriFramework, RTLD_LAZY | RTLD_LOCAL) else {
            throw unavailable("SiriTTSService could not be loaded")
        }
        defer { dlclose(siriHandle) }
        guard let textHandle = dlopen(textToSpeechFramework, RTLD_LAZY | RTLD_LOCAL) else {
            throw unavailable("TextToSpeech could not be loaded")
        }
        defer { dlclose(textHandle) }

        guard let assetClass = NSClassFromString("SiriTTSService.TTSAsset"),
              let typeClass = NSClassFromString("TTSAssetType") else {
            throw unavailable("the TTS asset catalog classes are absent")
        }
        let gryphonSelector = NSSelectorFromString("gryphonVoice")
        let listSelector = NSSelectorFromString("listAssetsOfTypes:matching:")
        guard class_getClassMethod(typeClass, gryphonSelector) != nil,
              class_getClassMethod(assetClass, listSelector) != nil else {
            throw unavailable("the TTS asset catalog selectors are absent")
        }
        let getters = [
            "identifier", "name", "primaryLanguage", "technology", "gender",
            "quality", "versionNumber", "attributes", "locallyAvailable",
            "downloadSize",
        ]
        guard getters.allSatisfy({
            class_getInstanceMethod(assetClass, NSSelectorFromString($0)) != nil
        }) else {
            throw unavailable("the TTS asset catalog schema is incompatible")
        }
        guard let gryphonType = (typeClass as AnyObject)
            .perform(gryphonSelector)?.takeUnretainedValue() else {
            throw unavailable("the Gryphon voice asset type is unavailable")
        }
        guard let result = (assetClass as AnyObject).perform(
            listSelector,
            with: NSArray(object: gryphonType),
            with: NSDictionary()
        )?.takeUnretainedValue(), let assets = result as? [NSObject] else {
            throw unavailable("the TTS asset catalog returned an incompatible result")
        }

        return try body(assets)
    }

    private static func requestMobileAssetElimination(assetSpecifier: String) throws {
        try validatePurgeABI()
        guard let handle = dlopen(mobileAssetFramework, RTLD_LAZY | RTLD_LOCAL) else {
            throw unavailable("MobileAsset could not be loaded")
        }
        defer { dlclose(handle) }
        guard let selectorClass = NSClassFromString("MAAutoAssetSelector"),
              let autoAssetClass = NSClassFromString("MAAutoAsset") else {
            throw unavailable("the MobileAsset elimination classes are absent")
        }
        let initializer = NSSelectorFromString("initForAssetType:withAssetSpecifier:")
        let eliminate = NSSelectorFromString("eliminateAllForSelectorSync:")
        guard let allocated = (selectorClass as AnyObject)
            .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let selector = allocated.perform(
                initializer,
                with: uafSiriAssetType as NSString,
                with: assetSpecifier as NSString
              )?.takeRetainedValue() else {
            throw unavailable("the MobileAsset selector could not be constructed")
        }

        // On macOS 26.6 the synchronous client receives an entitlement error before
        // mobileassetd completes the already-routed elimination request. The return
        // object is therefore advisory; the fresh catalog and filesystem checks in
        // `purge` are the authoritative result.
        _ = (autoAssetClass as AnyObject).perform(eliminate, with: selector)
    }

    private static func boolValue(_ object: NSObject, selector name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: object), selector),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding) == "B16@0:8" else {
            return nil
        }
        typealias Getter = @convention(c) (UnsafeRawPointer, Selector) -> Bool
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(Unmanaged.passUnretained(object).toOpaque(), selector)
    }

    private static func localBundlePath(_ asset: NSObject) -> String? {
        let selector = NSSelectorFromString("bundle")
        guard asset.responds(to: selector) else { return nil }
        guard let bundle = asset.perform(selector)?.takeUnretainedValue() else { return nil }
        if let bundle = bundle as? Bundle { return bundle.bundlePath }
        if let url = bundle as? URL { return url.path }
        return nil
    }

    static func effectiveLocalAvailability(
        reported: Bool,
        localBundlePath: String?
    ) -> Bool {
        guard reported, let localBundlePath else { return reported }
        return FileManager.default.fileExists(atPath: localBundlePath)
    }

    static func applyingLocalState(
        to metadata: SiriCatalogAssetMetadata,
        states: [String: SiriUAFLocalAssetState]?
    ) -> SiriCatalogAssetMetadata {
        guard let states else { return metadata }
        let state = states[uafAssetSpecifier(for: metadata)]
        return SiriCatalogAssetMetadata(
            identifier: metadata.identifier,
            name: metadata.name,
            language: metadata.language,
            technology: metadata.technology,
            gender: metadata.gender,
            quality: metadata.quality,
            version: state?.contentVersion ?? 0,
            relativeDesirability: metadata.relativeDesirability,
            locallyAvailable: state != nil,
            downloadSize: metadata.downloadSize
        )
    }

    /// MobileAsset elimination invalidates the current UAF atomic-set lock, so
    /// TTSAsset can temporarily call every voice remote even though unrelated
    /// asset bundles remain. The per-asset manifests are the byte-level source
    /// of truth and retain the exact specifier and content version.
    private static func localAssetStates() -> [String: SiriUAFLocalAssetState]? {
        let root = URL(fileURLWithPath: uafSiriAssetRoot, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var states: [String: SiriUAFLocalAssetState] = [:]
        for child in children where child.pathExtension == "asset" {
            let assetData = child.appendingPathComponent("AssetData", isDirectory: true)
            guard FileManager.default.fileExists(atPath: assetData.path),
                  let data = try? Data(contentsOf: child.appendingPathComponent("Info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any],
                  let properties = plist["MobileAssetProperties"] as? [String: Any],
                  let specifier = properties["AssetSpecifier"] as? String,
                  specifier.hasPrefix("com.apple.siri.tts.voice."),
                  let contentVersion = integer(properties["ttsContentVersion"]) else {
                continue
            }
            let state = SiriUAFLocalAssetState(
                contentVersion: contentVersion,
                assetDataPath: assetData.path
            )
            if let existing = states[specifier], existing.contentVersion > contentVersion {
                continue
            }
            states[specifier] = state
        }
        return states
    }

    /// TTSAsset may expose multiple generations for the same downloadable
    /// identifier. Apple publishes `VoiceRelativeDesirability`; choosing the
    /// highest value produces one platform-preferred premium row per identifier.
    static func preferredVoices(
        from metadata: [SiriCatalogAssetMetadata]
    ) -> [SiriDownloadableVoice] {
        let compatible = metadata.filter {
            $0.quality == "premium" &&
            !$0.identifier.isEmpty &&
            !$0.name.isEmpty &&
            !$0.language.isEmpty &&
            $0.version >= 0 &&
            $0.downloadSize > 0 &&
            (1...3).contains($0.gender) &&
            SiriDownloadableVoice.voiceType(for: $0.technology) != nil
        }
        let groups = Dictionary(grouping: compatible, by: \.identifier)
        return groups.values.compactMap { candidates in
            candidates.max(by: isLessPreferred).map {
                let matchingPrefixes = Set(candidates.map(nativeIdentityPrefix))
                return SiriDownloadableVoice(
                    catalogAssetKey: $0.identifier,
                    name: $0.name,
                    language: $0.language,
                    technology: $0.technology,
                    gender: $0.gender,
                    version: $0.version,
                    relativeDesirability: $0.relativeDesirability,
                    locallyAvailable: $0.locallyAvailable,
                    downloadSize: $0.downloadSize,
                    matchingNativeIdentityPrefixes: matchingPrefixes.sorted()
                )
            }
        }.sorted {
            ($0.language, $0.name, $0.catalogAssetKey) <
            ($1.language, $1.name, $1.catalogAssetKey)
        }
    }

    /// Resolves Apple's stable catalog identifier or the daemon-native identity
    /// before considering the human-readable name. Names must be unique so a
    /// future catalog cannot silently install a different language's voice.
    static func resolve(
        _ identifier: String,
        in voices: [SiriDownloadableVoice],
        allowDisplayName: Bool = true
    ) throws -> SiriDownloadableVoice? {
        if let exact = voices.first(where: {
            $0.catalogAssetKey.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.nativeAssetKey.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return exact
        }
        guard allowDisplayName else { return nil }

        let named = voices.filter {
            $0.name.caseInsensitiveCompare(identifier) == .orderedSame
        }
        guard named.count <= 1 else {
            throw CLIError(
                "Available Siri voice name '\(identifier)' is ambiguous; " +
                "use its asset key from `siri-tts voices --available`",
                code: .voiceNotFound
            )
        }
        return named.first
    }

    private static func isLessPreferred(
        _ lhs: SiriCatalogAssetMetadata,
        _ rhs: SiriCatalogAssetMetadata
    ) -> Bool {
        let left = (
            lhs.relativeDesirability,
            lhs.locallyAvailable ? 1 : 0,
            lhs.version,
            lhs.technology
        )
        let right = (
            rhs.relativeDesirability,
            rhs.locallyAvailable ? 1 : 0,
            rhs.version,
            rhs.technology
        )
        return left < right
    }

    private static func nativeIdentityPrefix(_ metadata: SiriCatalogAssetMetadata) -> String {
        metadata.nativeIdentityPrefix
    }

    private static func methodEncoding(_ cls: AnyClass, _ selector: Selector) -> String? {
        guard let method = class_getInstanceMethod(cls, selector),
              let encoding = method_getTypeEncoding(method) else {
            return nil
        }
        return String(cString: encoding)
    }

    private static func classMethodEncoding(_ cls: AnyClass, _ selector: Selector) -> String? {
        guard let method = class_getClassMethod(cls, selector),
              let encoding = method_getTypeEncoding(method) else { return nil }
        return String(cString: encoding)
    }

    private static func readMetadata(_ asset: NSObject) -> SiriCatalogAssetMetadata? {
        guard let identifier = string(asset.value(forKey: "identifier")),
              let name = string(asset.value(forKey: "name")),
              let language = string(asset.value(forKey: "primaryLanguage")),
              let technology = string(asset.value(forKey: "technology")),
              let quality = string(asset.value(forKey: "quality")),
              let gender = integer(asset.value(forKey: "gender")),
              let version = integer(asset.value(forKey: "versionNumber")),
              let downloadSize = integer(asset.value(forKey: "downloadSize")) else {
            return nil
        }
        let attributes = asset.value(forKey: "attributes") as? NSDictionary
        let desirability = integer(attributes?["VoiceRelativeDesirability"]) ?? 0
        let reportedLocalAvailability =
            asset.value(forKey: "locallyAvailable") as? Bool ?? false
        let locallyAvailable = effectiveLocalAvailability(
            reported: reportedLocalAvailability,
            localBundlePath: localBundlePath(asset)
        )
        return SiriCatalogAssetMetadata(
            identifier: identifier,
            name: name,
            language: language,
            technology: technology,
            gender: gender,
            quality: quality,
            version: version,
            relativeDesirability: desirability,
            locallyAvailable: locallyAvailable,
            downloadSize: downloadSize
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return (value as? NSNumber)?.intValue
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let value = value as? String { return value }
        let description = String(describing: value)
        return description.isEmpty ? nil : description
    }

    private static func unavailable(_ detail: String) -> CLIError {
        CLIError(
            "This macOS build did not expose a compatible downloadable Siri voice catalog: \(detail)",
            code: .daemonUnreachable
        )
    }
}
