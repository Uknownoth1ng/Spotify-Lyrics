import Foundation

struct LRCParser {
    static func parse(_ text: String) -> [LyricLine] {
        let timestampPattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else { return [] }
        var lines: [LyricLine] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = regex.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }

            var lyricText = rawLine
            for match in matches.reversed() {
                if let swiftRange = Range(match.range, in: lyricText) {
                    lyricText.removeSubrange(swiftRange)
                }
            }
            lyricText = lyricText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyricText.isEmpty else { continue }

            for match in matches {
                guard
                    let minutesRange = Range(match.range(at: 1), in: rawLine),
                    let secondsRange = Range(match.range(at: 2), in: rawLine),
                    let minutes = Int(rawLine[minutesRange]),
                    let seconds = Int(rawLine[secondsRange])
                else { continue }

                var milliseconds = 0
                if match.range(at: 3).location != NSNotFound,
                   let msRange = Range(match.range(at: 3), in: rawLine) {
                    let fraction = String(rawLine[msRange])
                    if fraction.count == 1 {
                        milliseconds = (Int(fraction) ?? 0) * 100
                    } else if fraction.count == 2 {
                        milliseconds = (Int(fraction) ?? 0) * 10
                    } else {
                        milliseconds = Int(fraction.prefix(3)) ?? 0
                    }
                }

                let time = minutes * 60_000 + seconds * 1_000 + milliseconds
                lines.append(LyricLine(timeMs: time, text: lyricText))
            }
        }

        return lines.sorted { $0.timeMs < $1.timeMs }
    }
}

final class LyricsSyncEngine {
    private(set) var lines: [LyricLine] = []
    var globalLatencyCompensationMs: Int = 150
    var perTrackOffsetMs: Int = 0

    /// Replace the parsed lines wholesale (used after AI auto-calibration shifts
    /// timestamps that the original LRC parser produced).
    func replaceLines(_ newLines: [LyricLine]) {
        lines = newLines.sorted { $0.timeMs < $1.timeMs }
    }

    func load(lrcText: String?, sourceDurationMs: Int? = nil, playbackDurationMs: Int? = nil) {
        guard let lrcText else {
            lines = []
            return
        }
        let parsed = LRCParser.parse(lrcText)
        guard
            let sourceDurationMs,
            let playbackDurationMs,
            sourceDurationMs > 30_000,
            playbackDurationMs > 30_000,
            abs(sourceDurationMs - playbackDurationMs) > 1_500,
            abs(sourceDurationMs - playbackDurationMs) <= 12_000
        else {
            lines = parsed
            return
        }
        let scale = Double(playbackDurationMs) / Double(sourceDurationMs)
        lines = parsed.map { line in
            LyricLine(timeMs: Int(Double(line.timeMs) * scale), text: line.text)
        }
    }

    func snapshot(positionMs: Int, contextCount: Int = 2) -> SyncedLyricsSnapshot {
        let effective = max(0, positionMs + globalLatencyCompensationMs + perTrackOffsetMs)
        guard !lines.isEmpty else {
            return SyncedLyricsSnapshot(previous: [], current: nil, next: [], effectivePositionMs: effective)
        }

        if effective < lines[0].timeMs {
            return SyncedLyricsSnapshot(
                previous: [],
                current: nil,
                next: Array(lines.prefix(contextCount)),
                effectivePositionMs: effective
            )
        }

        let index = currentIndex(for: effective)
        let previousStart = max(0, index - contextCount)
        let nextEnd = min(lines.count, index + contextCount + 1)
        let previous = index > 0 ? Array(lines[previousStart..<index]) : []
        let next = index + 1 < nextEnd ? Array(lines[(index + 1)..<nextEnd]) : []
        return SyncedLyricsSnapshot(
            previous: previous,
            current: lines[index],
            next: next,
            effectivePositionMs: effective
        )
    }

    private func currentIndex(for positionMs: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].timeMs <= positionMs {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
