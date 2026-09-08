@preconcurrency import AVFoundation
import Foundation

/// AVAudioConverter's input block is `@Sendable` even though conversion is
/// synchronous. This box protects its one-shot state and contains the
/// non-Sendable framework buffer behind an audited boundary.
final class OneShotAudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioBuffer?

    init(_ buffer: AVAudioBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}
