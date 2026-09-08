import Foundation

public enum WordTimingMapper {
    /// Removes malformed native entries without turning otherwise valid audio
    /// into a synthesis failure. The remaining entries are safe to pass to
    /// `map(_:in:duration:)`.
    public static func sanitize(
        _ timings: [RawWordTiming],
        in text: String,
        duration: Double
    ) -> [RawWordTiming] {
        guard duration.isFinite, duration >= 0 else { return [] }
        let utf16Count = text.utf16.count
        var accepted: [RawWordTiming] = []
        var previousStart = -Double.infinity
        var previousRangeEnd = 0

        for timing in timings {
            let (rangeEnd, overflow) = timing.range.location.addingReportingOverflow(
                timing.range.length
            )
            guard timing.start.isFinite,
                  timing.start >= 0,
                  timing.start <= duration,
                  timing.range.location >= 0,
                  timing.range.length >= 0,
                  !overflow,
                  rangeEnd <= utf16Count,
                  timing.start >= previousStart,
                  timing.range.location >= previousRangeEnd else {
                continue
            }
            accepted.append(timing)
            previousStart = timing.start
            previousRangeEnd = rangeEnd
        }
        return accepted
    }

    public static func map(
        _ timings: [RawWordTiming],
        in text: String,
        duration: Double
    ) throws -> [WordTiming] {
        let utf16Count = text.utf16.count
        let ordered = timings
        let nsText = text as NSString

        var result: [WordTiming] = []
        for (index, timing) in ordered.enumerated() {
            guard timing.start >= 0, timing.start <= duration,
                  timing.range.location >= 0, timing.range.length >= 0,
                  timing.range.location <= utf16Count,
                  timing.range.location + timing.range.length <= utf16Count else {
                throw CLIError("Invalid word timing returned by the engine", code: .noAudio)
            }
            if index > 0 {
                let previous = ordered[index - 1]
                if previous.start > timing.start ||
                    previous.range.location + previous.range.length > timing.range.location {
                    throw CLIError(
                        "Non-monotonic or overlapping word timings returned by the engine",
                        code: .noAudio
                    )
                }
            }
            let token = nsText.substring(with: timing.range)
            let end = index + 1 < ordered.count
                ? min(duration, ordered[index + 1].start)
                : duration
            result.append(WordTiming(
                text: token,
                start: timing.start,
                end: max(timing.start, end),
                utf16Location: timing.range.location,
                utf16Length: timing.range.length,
                endDerived: true
            ))
        }
        return result
    }
}
