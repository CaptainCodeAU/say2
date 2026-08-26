import Foundation

enum VoiceInstallationMonitor {
    static func poll(
        identifier: String,
        assetKey: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        isCancelled: () -> Bool = { false },
        onUpdate: ((VoiceInstallationResult) -> Void)? = nil,
        fetchInstalled: () throws -> [VoiceInfo]
    ) throws -> VoiceInstallationResult {
        precondition(timeout >= 0)
        precondition(pollInterval > 0)
        let started = now()

        while true {
            if isCancelled() {
                throw CLIError("Voice installation wait cancelled", code: .cancelled)
            }
            if let voice = try fetchInstalled().first(where: { $0.assetKey == assetKey }) {
                let result = VoiceInstallationResult(
                    identifier: identifier,
                    assetKey: assetKey,
                    state: .installed,
                    voice: voice,
                    elapsedSeconds: max(0, now() - started)
                )
                onUpdate?(result)
                return result
            }

            let elapsed = max(0, now() - started)
            let remaining = timeout - elapsed
            guard remaining > 0 else {
                let result = VoiceInstallationResult(
                    identifier: identifier,
                    assetKey: assetKey,
                    state: .timedOut,
                    elapsedSeconds: elapsed
                )
                onUpdate?(result)
                return result
            }
            onUpdate?(VoiceInstallationResult(
                identifier: identifier,
                assetKey: assetKey,
                state: .waiting,
                elapsedSeconds: elapsed
            ))
            if isCancelled() {
                throw CLIError("Voice installation wait cancelled", code: .cancelled)
            }
            sleep(min(pollInterval, remaining))
        }
    }
}
