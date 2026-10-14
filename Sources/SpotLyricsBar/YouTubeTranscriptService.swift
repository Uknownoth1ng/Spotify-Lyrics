import Foundation

final class YouTubeTranscriptService: @unchecked Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    func fetchTranscript(title: String, showName: String, durationMs: Int?) async -> String? {
        let query = "\(showName) \(title)"
        let expectedScript = TextNormalizer.dominantScript(query)
        guard let videoID = await searchVideoID(query: query, expectedDurationMs: durationMs, expectedScript: expectedScript) else {
            NSLog("SpotLyrics YouTube: no matching video found for \"%@\"", title)
            return nil
        }
        NSLog("SpotLyrics YouTube: found video %@", videoID)

        let raw: String?
        if let lrc = await fetchViaYtDlp(videoID: videoID) {
            raw = lrc
        } else {
            NSLog("SpotLyrics YouTube: yt-dlp unavailable or failed, trying direct fetch")
            raw = await fetchDirect(videoID: videoID)
        }
        guard let lrc = raw else { return nil }
        // Final guard: even if the video metadata passed our script check, the
        // VTT itself may be a community-contributed translation (often shipped
        // as bilingual lines that interleave the source language with a
        // translation). If we expected English but the captions are >25% CJK
        // characters, drop the result — surfacing it would overlay garbled
        // bilingual text on top of live transcription.
        guard Self.transcriptScriptMatches(lrc, expected: expectedScript) else {
            NSLog("SpotLyrics YouTube: dropping captions — script mismatch with expected %@", String(describing: expectedScript))
            return nil
        }
        return lrc
    }

    /// True when a transcript's character mix is consistent with the
    /// expected dominant script. CJK is the only direction where mismatched
    /// scripts produce visibly broken output today (Latin captions on a
    /// Mandarin show would still be useful to the user as a hint, so we
    /// only enforce the rule for podcasts whose titles are Latin-dominant).
    private static func transcriptScriptMatches(_ lrc: String, expected: TextNormalizer.DominantScript) -> Bool {
        switch expected {
        case .latin:
            var cjk = 0
            var total = 0
            for scalar in lrc.unicodeScalars {
                if (0x20...0x7E).contains(scalar.value) { total += 1; continue }
                if (0x4E00...0x9FFF).contains(scalar.value)
                    || (0x3400...0x4DBF).contains(scalar.value)
                    || (0x3040...0x30FF).contains(scalar.value)
                    || (0xAC00...0xD7AF).contains(scalar.value) {
                    cjk += 1; total += 1
                }
            }
            guard total > 200 else { return true }
            return Double(cjk) / Double(total) < 0.25
        default:
            return true
        }
    }

    // MARK: - yt-dlp approach

    private func fetchViaYtDlp(videoID: String) async -> String? {
        let ytdlpPaths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
        let ytdlp = ytdlpPaths.first { FileManager.default.fileExists(atPath: $0) }

        guard let ytdlpPath = ytdlp else {
            // Try python3 -m yt_dlp
            let pythonPaths = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            let python = pythonPaths.first { FileManager.default.fileExists(atPath: $0) }
            guard let pythonPath = python else { return nil }
            return await runYtDlp(executable: pythonPath, args: ["-m", "yt_dlp"], videoID: videoID)
        }

        return await runYtDlp(executable: ytdlpPath, args: [], videoID: videoID)
    }

    private func runYtDlp(executable: String, args: [String], videoID: String) async -> String? {
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotlyrics-yt-\(videoID)")
            .path

        let fullArgs = args + [
            "--write-auto-sub", "--sub-lang", "en",
            "--skip-download", "--sub-format", "vtt",
            "-o", outputPath,
            "https://www.youtube.com/watch?v=\(videoID)"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = fullArgs
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let vttPath = outputPath + ".en.vtt"
        defer { try? FileManager.default.removeItem(atPath: vttPath) }

        guard let vttData = FileManager.default.contents(atPath: vttPath),
              let vtt = String(data: vttData, encoding: .utf8) else {
            return nil
        }

        let lrc = convertVTTtoLRC(vtt)
        NSLog("SpotLyrics YouTube: yt-dlp got %d LRC lines", lrc?.components(separatedBy: "\n").count ?? 0)
        return lrc
    }

    // MARK: - Direct fetch (fallback, may not work due to pot token)

    private func fetchDirect(videoID: String) async -> String? {
        guard let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
        var request = URLRequest(url: watchURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        guard let (data, _) = try? await session.data(for: request),
              let html = String(data: data, encoding: .utf8),
              let playerJSON = extractPlayerResponse(from: html),
              let jsonData = playerJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let captions = root["captions"] as? [String: Any],
              let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let tracks = renderer["captionTracks"] as? [[String: Any]] else {
            return nil
        }

        let englishTracks = tracks.filter { ($0["languageCode"] as? String)?.hasPrefix("en") == true }
        let bestTrack = englishTracks.first { ($0["kind"] as? String) == "asr" } ?? englishTracks.first
        guard let baseURLStr = bestTrack?["baseUrl"] as? String,
              let captionURL = URL(string: baseURLStr) else { return nil }

        var captionReq = URLRequest(url: captionURL)
        captionReq.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (captionData, _) = try? await session.data(for: captionReq),
              let xml = String(data: captionData, encoding: .utf8), !xml.isEmpty else {
            return nil
        }

        return parseXMLCaptions(xml)
    }

    // MARK: - Search
    // PLACEHOLDER_SEARCH

    private func searchVideoID(query: String, expectedDurationMs: Int?, expectedScript: TextNormalizer.DominantScript) async -> String? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        guard let (data, _) = try? await session.data(for: request),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        guard let jsonStr = extractYTInitialData(from: html) else { return nil }
        guard let jsonData = jsonStr.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        return extractBestVideoID(from: root, expectedDurationMs: expectedDurationMs, query: query, expectedScript: expectedScript)
    }

    private func extractYTInitialData(from html: String) -> String? {
        let marker = "var ytInitialData = "
        guard let startRange = html.range(of: marker) else { return nil }
        let afterMarker = html[startRange.upperBound...]
        guard let endRange = afterMarker.range(of: ";</script>") else { return nil }
        return String(afterMarker[..<endRange.lowerBound])
    }

    private func extractBestVideoID(from root: [String: Any], expectedDurationMs: Int?, query: String, expectedScript: TextNormalizer.DominantScript) -> String? {
        guard let contents = root["contents"] as? [String: Any],
              let twoCol = contents["twoColumnSearchResultsRenderer"] as? [String: Any],
              let primary = twoCol["primaryContents"] as? [String: Any],
              let sectionList = primary["sectionListRenderer"] as? [String: Any],
              let sections = sectionList["contents"] as? [[String: Any]] else {
            return nil
        }

        struct Candidate {
            let videoId: String
            let durationSeconds: Int
            let title: String
        }

        var candidates: [Candidate] = []

        for section in sections {
            guard let itemSection = section["itemSectionRenderer"] as? [String: Any],
                  let items = itemSection["contents"] as? [[String: Any]] else { continue }
            for item in items {
                guard let video = item["videoRenderer"] as? [String: Any],
                      let videoId = video["videoId"] as? String else { continue }

                let title = (video["title"] as? [String: Any])?["runs"] as? [[String: Any]]
                let titleText = title?.compactMap { $0["text"] as? String }.joined() ?? ""

                var durationSec = 0
                if let lengthText = (video["lengthText"] as? [String: Any])?["simpleText"] as? String {
                    durationSec = parseDurationText(lengthText)
                }

                candidates.append(Candidate(videoId: videoId, durationSeconds: durationSec, title: titleText))
            }
        }

        guard !candidates.isEmpty else { return nil }

        let expectedSec = (expectedDurationMs ?? 0) / 1000

        // Score candidates by duration proximity AND title token overlap.
        // Prior versions accepted any video within ±30 % of expected duration
        // and returned the first hit — that picked completely unrelated
        // episodes (a 5727 s "Koch Inc." video was returned for a 4590 s
        // All-In episode). We now require both:
        //   * duration within ±10 %
        //   * at least 2 shared content tokens between expected title and
        //     candidate title (after dropping podcast/show boilerplate)
        if expectedSec > 60 {
            let queryTokens = Self.contentTokens(query)
            struct Scored { let videoId: String; let durationSeconds: Int; let title: String; let overlap: Int; let durationDelta: Double }
            let scored: [Scored] = candidates.compactMap { c -> Scored? in
                guard c.durationSeconds > 0 else { return nil }
                let ratio = Double(c.durationSeconds) / Double(expectedSec)
                guard ratio > 0.9 && ratio < 1.1 else { return nil }
                // Script consistency. Translation/dubbing channels reupload
                // English podcasts with Mandarin titles (e.g. "All-In 全译版
                // 中美关税战"); their captions are bilingual or pure
                // translations and they previously contaminated Live
                // transcription. Reject candidates whose title's dominant
                // script disagrees with the podcast's expected script.
                let titleScript = TextNormalizer.dominantScript(c.title)
                if expectedScript == .latin && titleScript != .latin {
                    return nil
                }
                if expectedScript != .latin && titleScript == .latin {
                    // CJK podcast picking up an English-titled clip is also
                    // suspect (likely a clip channel reuploading a snippet).
                    return nil
                }
                let titleTokens = Self.contentTokens(c.title)
                let overlap = queryTokens.intersection(titleTokens).count
                guard overlap >= 2 else { return nil }
                return Scored(videoId: c.videoId, durationSeconds: c.durationSeconds, title: c.title, overlap: overlap, durationDelta: abs(ratio - 1.0))
            }
            let best = scored.sorted { lhs, rhs in
                if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
                return lhs.durationDelta < rhs.durationDelta
            }.first
            if let best {
                NSLog("SpotLyrics YouTube: matched \"%@\" (duration %ds vs expected %ds, title overlap %d)", best.title.prefix(50) as CVarArg, best.durationSeconds, expectedSec, best.overlap)
                return best.videoId
            }
            NSLog("SpotLyrics YouTube: no acceptable match (expected %ds, %d candidates)", expectedSec, candidates.count)
        }

        // No fallback to "first result that's longer than 5 minutes" — that
        // was the source of cross-episode contamination. If we can't confirm
        // a match, let the pipeline fall through to live transcription.
        return nil
    }

    private static let stopWords: Set<String> = [
        "the","a","an","and","or","of","to","with","for","on","in","at","by",
        "is","this","that","these","those","but","not","from","as","be","it",
        "&","podcast","episode","ep","interview","official","full","video","audio",
        "part","pt","feat","featuring","featuring:","ft","ft.","with:","x","vs"
    ]

    private static func contentTokens(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        let cleaned = String(scalars)
        let words = cleaned.split(separator: " ").map(String.init)
        return Set(words.filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    private func parseDurationText(_ text: String) -> Int {
        let parts = text.components(separatedBy: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }

    // MARK: - Helpers

    private func extractPlayerResponse(from html: String) -> String? {
        let patterns = ["var ytInitialPlayerResponse = ", "ytInitialPlayerResponse = "]
        for pattern in patterns {
            guard let startRange = html.range(of: pattern) else { continue }
            let afterMarker = html[startRange.upperBound...]
            var depth = 0
            var endIndex = afterMarker.startIndex
            for (i, char) in afterMarker.enumerated() {
                if char == "{" { depth += 1 }
                else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = afterMarker.index(afterMarker.startIndex, offsetBy: i + 1)
                        break
                    }
                }
            }
            if depth == 0 {
                return String(afterMarker[..<endIndex])
            }
        }
        return nil
    }

    private func convertVTTtoLRC(_ vtt: String) -> String? {
        var lines: [(ms: Int, text: String)] = []
        let vttLines = vtt.components(separatedBy: .newlines)
        var i = 0

        while i < vttLines.count {
            let line = vttLines[i]
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                guard parts.count == 2 else { i += 1; continue }
                let startStr = parts[0].trimmingCharacters(in: .whitespaces)
                let endPart = parts[1].components(separatedBy: " ").first(where: { $0.contains(":") }) ?? parts[1].trimmingCharacters(in: .whitespaces)
                let startMs = parseVTTTimestamp(startStr)
                let endMs = parseVTTTimestamp(endPart)

                // Skip very short cues (transition frames, ~10ms)
                if let s = startMs, let e = endMs, e - s < 50 {
                    i += 1
                    continue
                }

                // Collect text lines for this cue
                i += 1
                var textLines: [String] = []
                while i < vttLines.count && !vttLines[i].isEmpty && !vttLines[i].contains("-->") {
                    let cleaned = vttLines[i]
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        textLines.append(cleaned)
                    }
                    i += 1
                }

                // For YouTube auto-captions: take only the LAST line (new content)
                // The first line is repeated from the previous cue
                let text: String
                if textLines.count >= 2 {
                    text = textLines.last!
                } else {
                    text = textLines.joined(separator: " ")
                }

                if !text.isEmpty, let ms = startMs {
                    lines.append((ms: ms, text: text))
                }
            } else {
                i += 1
            }
        }

        guard lines.count >= 5 else { return nil }

        return lines.map { entry in
            let ms = entry.ms
            let min = ms / 60000
            let sec = (ms % 60000) / 1000
            let hundredths = (ms % 1000) / 10
            return "[\(String(format: "%02d:%02d.%02d", min, sec, hundredths))]\(entry.text)"
        }.joined(separator: "\n")
    }

    private func parseVTTTimestamp(_ str: String) -> Int? {
        let clean = str.trimmingCharacters(in: .whitespaces)
        let parts = clean.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        let hours: Int
        let minutes: Int
        let secPart: String
        if parts.count == 3 {
            hours = Int(parts[0]) ?? 0
            minutes = Int(parts[1]) ?? 0
            secPart = parts[2]
        } else {
            hours = 0
            minutes = Int(parts[0]) ?? 0
            secPart = parts[1]
        }

        let secPieces = secPart.components(separatedBy: ".")
        let seconds = Int(secPieces[0]) ?? 0
        let ms: Int
        if secPieces.count > 1 {
            let frac = secPieces[1]
            if frac.count == 3 { ms = Int(frac) ?? 0 }
            else if frac.count == 2 { ms = (Int(frac) ?? 0) * 10 }
            else { ms = (Int(frac) ?? 0) * 100 }
        } else {
            ms = 0
        }

        return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + ms
    }

    private func parseXMLCaptions(_ xml: String) -> String? {
        let parser = CaptionXMLParser()
        return parser.parse(xml: xml)
    }
}

private final class CaptionXMLParser: NSObject, XMLParserDelegate {
    private var entries: [(startMs: Int, text: String)] = []
    private var currentStart: Double?
    private var buffer = ""
    private var inText = false

    func parse(xml: String) -> String? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), entries.count >= 3 else { return nil }

        return entries.map { entry in
            let ms = entry.startMs
            let min = ms / 60000
            let sec = (ms % 60000) / 1000
            let hundredths = (ms % 1000) / 10
            return "[\(String(format: "%02d:%02d.%02d", min, sec, hundredths))]\(entry.text)"
        }.joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == "text" {
            currentStart = Double(attributes["start"] ?? "0")
            buffer = ""
            inText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard elementName == "text", inText else { return }
        inText = false
        let text = decodeHTMLEntities(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let start = currentStart else { return }
        entries.append((startMs: Int(start * 1000), text: text))
    }

    private func decodeHTMLEntities(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "\n", with: " ")
        return result
    }
}
