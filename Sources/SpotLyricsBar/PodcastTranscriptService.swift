import Foundation

final class PodcastTranscriptService: LyricsSearching, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func bestLyrics(for track: PlaybackTrack) async throws -> LyricsCandidate {
        guard track.contentKind == .episode else { throw LyricsSearchError.notFound }
        let candidates = await transcriptSearchURLs(for: track)
        for url in candidates {
            do {
                let (data, response) = try await session.data(from: url)
                guard
                    let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode),
                    let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
                else { continue }

                if let candidate = Self.candidate(from: text, url: url, track: track) {
                    return candidate
                }
            } catch {
                continue
            }
        }
        throw LyricsSearchError.notFound
    }

    func publicAudioURL(for track: PlaybackTrack) async -> URL? {
        guard let feedURL = await directoryFeedURL(for: track),
              let feed = await fetchFeed(feedURL),
              let item = feed.bestItem(for: track)
        else { return nil }
        return item.audioURL
    }

    static func candidate(from text: String, url: URL? = nil, track: PlaybackTrack) -> LyricsCandidate? {
        // Drop transcripts whose dominant script disagrees with the show's
        // language. Translation/fan-sub sites publish bilingual or pure
        // translated transcripts that, when shown overlaid on Live captions,
        // produce visibly broken Chinese-English mash-ups.
        let titleScript = TextNormalizer.dominantScript("\(track.podcastShowName) \(track.title)")
        if titleScript == .latin {
            var cjk = 0
            var sampled = 0
            for scalar in text.unicodeScalars {
                sampled += 1
                if (0x4E00...0x9FFF).contains(scalar.value)
                    || (0x3400...0x4DBF).contains(scalar.value)
                    || (0x3040...0x30FF).contains(scalar.value)
                    || (0xAC00...0xD7AF).contains(scalar.value) { cjk += 1 }
                if sampled >= 4000 { break }
            }
            if sampled > 400 && Double(cjk) / Double(sampled) > 0.15 {
                return nil
            }
        }
        let lrc: String?
        let plainLyrics: String
        let sourceLabel: String
        let looksHTML = TranscriptTextCleaner.isLikelyHTML(text, url: url)
        if !looksHTML, !LRCParser.parse(text).isEmpty {
            lrc = text
            plainLyrics = text
            sourceLabel = "Podcast transcript LRC"
        } else if !looksHTML, let converted = TranscriptParser.lrcFromVTT(text) {
            lrc = converted
            plainLyrics = text
            sourceLabel = "Podcast transcript VTT"
        } else if !looksHTML, let converted = TranscriptParser.lrcFromSRT(text) {
            lrc = converted
            plainLyrics = text
            sourceLabel = "Podcast transcript SRT"
        } else if let cleaned = TranscriptTextCleaner.readableTranscriptText(from: text, url: url),
                  let converted = TranscriptParser.lrcFromPlainText(cleaned.text, durationMs: track.durationMs) {
            lrc = converted
            plainLyrics = cleaned.text
            sourceLabel = cleaned.sourceWasHTML ? "Podcast transcript page" : "Podcast transcript text"
        } else {
            return nil
        }

        return LyricsCandidate(
            trackName: track.title,
            artistName: track.podcastShowName,
            albumName: track.album,
            durationMs: track.durationMs,
            syncedLyrics: lrc,
            plainLyrics: plainLyrics,
            source: [sourceLabel, url?.host].compactMap { $0 }.joined(separator: " · "),
            confidence: 0.82
        )
    }

    private func transcriptSearchURLs(for track: PlaybackTrack) async -> [URL] {
        var trusted: [URL] = []
        var untrusted: [URL] = []
        if let feedURL = await directoryFeedURL(for: track),
           let feed = await fetchFeed(feedURL),
           let item = feed.bestItem(for: track) {
            // RSS <podcast:transcript> URLs are first-party metadata from the
            // show itself — never reject them by keyword. Many feeds host
            // transcripts at hashed paths (e.g. /e/abc123.json) that fail the
            // keyword filter, but they're the most reliable source we have.
            trusted.append(contentsOf: item.transcriptURLs)
            untrusted.append(contentsOf: transcriptLinks(in: item.description))
            if let link = item.link {
                untrusted.append(link)
                if let pageLinks = await transcriptLinks(fromPage: link) {
                    untrusted.append(contentsOf: pageLinks)
                }
            }
        }
        untrusted.append(contentsOf: await searchEngineTranscriptURLs(for: track))

        let filteredUntrusted = untrusted.filter { url in
            let lower = url.absoluteString.lowercased()
            return lower.contains("transcript")
                || lower.contains("caption")
                || lower.contains("listennotes.com/")
                || lower.contains("podchaser.com/")
                || lower.contains("podscan.fm/")
                || lower.contains("stt.ai/podcasts/")
                || lower.contains("transcripts.medxcribe.com/")
                || lower.contains("transcriptforest.com/")
                || lower.contains("thepodtranscripts.com/")
                || lower.contains("wisdominanutshell.academy/")
                || lower.contains("podclips.com/")
                || lower.contains("youtubetranscript")
                || lower.contains("sozai.app/transcript")
                || lower.contains("podscripts")
                || lower.contains("becurious")
                || lower.hasSuffix(".vtt")
                || lower.hasSuffix(".srt")
                || lower.hasSuffix(".lrc")
                || lower.hasSuffix(".txt")
                || lower.hasSuffix(".json")
        }
        return dedupe(trusted + filteredUntrusted)
    }

    private func searchEngineTranscriptURLs(for track: PlaybackTrack) async -> [URL] {
        let queries = [
            "\"\(track.podcastShowName)\" \"\(track.title)\" transcript",
            "\"\(track.title)\" \"transcript\" podcast",
            "\(track.podcastShowName) \(track.title) full transcript",
            "site:hubermanlab.com/episode \"\(track.title)\" transcript",
            "site:podscan.fm \"\(track.title)\" \"Episode Transcript\"",
            "site:stt.ai/podcasts \"\(track.title)\" transcript",
            "site:transcripts.medxcribe.com \"\(track.title)\" transcript",
            "site:transcriptforest.com \"\(track.title)\" transcript",
            "site:podchaser.com \"\(track.title)\" transcript",
            "site:listennotes.com \"\(track.title)\" transcript",
            "site:youtubetranscript.dev \"\(track.title)\""
        ]
        var urls: [URL] = []
        for query in queries.prefix(8) {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://duckduckgo.com/html/?q=\(encoded)")
            else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard
                    let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode),
                    let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
                else { continue }
                urls.append(contentsOf: transcriptLinks(in: html, baseURL: url).compactMap(Self.decodeDuckDuckGoRedirect))
                if urls.count >= 20 { break }
            } catch {
                continue
            }
        }
        return urls
    }

    private func directoryFeedURL(for track: PlaybackTrack) async -> URL? {
        let term = "\(track.podcastShowName) \(track.title)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? track.podcastShowName
        guard let url = URL(string: "https://itunes.apple.com/search?media=podcast&entity=podcast&limit=5&term=\(term)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let decoded = try? JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            else { return nil }
            let best = decoded.results.max { lhs, rhs in
                lhs.score(for: track) < rhs.score(for: track)
            }
            guard let feedURL = best?.feedUrl else { return nil }
            return URL(string: feedURL)
        } catch {
            return nil
        }
    }

    private func fetchFeed(_ url: URL) async -> PodcastFeed? {
        do {
            let (data, response) = try await session.data(from: url)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else { return nil }
            return PodcastFeedParser.parse(data)
        } catch {
            return nil
        }
    }

    private func transcriptLinks(fromPage url: URL) async -> [URL]? {
        do {
            let (data, response) = try await session.data(from: url)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return nil }
            return transcriptLinks(in: html, baseURL: url)
        } catch {
            return nil
        }
    }

    private func transcriptLinks(in text: String, baseURL: URL? = nil) -> [URL] {
        let decoded = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        guard let regex = try? NSRegularExpression(pattern: #"(https?://[^\s"'<>]+|href\s*=\s*["']([^"']+)["'])"#, options: [.caseInsensitive]) else {
            return []
        }
        let ns = decoded as NSString
        return regex.matches(in: decoded, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let value: String
            if match.range(at: 2).location != NSNotFound {
                value = ns.substring(with: match.range(at: 2))
            } else {
                value = ns.substring(with: match.range(at: 1))
            }
            guard let parsed = URL(string: value) else { return nil }
            if parsed.scheme != nil { return parsed }
            if let baseURL { return URL(string: value, relativeTo: baseURL)?.absoluteURL }
            return parsed
        }
    }

    static func testTranscriptLinks(in text: String, baseURL: URL? = nil) -> [URL] {
        PodcastTranscriptService().transcriptLinks(in: text, baseURL: baseURL)
            .compactMap(Self.decodeDuckDuckGoRedirect)
    }

    private func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls {
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            out.append(url)
        }
        return out
    }

    private static func decodeDuckDuckGoRedirect(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return url }
        return URL(string: uddg) ?? url
    }
}

enum TranscriptTextCleaner {
    static func isLikelyHTML(_ text: String, url: URL? = nil) -> Bool {
        if let pathExtension = url?.pathExtension.lowercased(), ["html", "htm"].contains(pathExtension) {
            return true
        }
        let lower = text.prefix(20_000).lowercased()
        return lower.contains("<html")
            || lower.contains("<body")
            || lower.contains("<script")
            || lower.contains("<style")
            || lower.range(of: #"<[a-z][a-z0-9:-]*(\s|>|/>)"#, options: .regularExpression) != nil
    }

    static func readableTranscriptText(from raw: String, url: URL?) -> (text: String, sourceWasHTML: Bool)? {
        let sourceWasHTML = isLikelyHTML(raw, url: url)
        let visibleText = sourceWasHTML ? visibleText(fromHTML: raw) : decodeHTMLEntities(raw)
        let candidateLines = cleanedStructuralLines(from: visibleText)
        let hasTranscriptMarker = sourceWasHTML && candidateLines.contains(where: isTranscriptStartMarker)
        let selectedLines = sourceWasHTML ? transcriptWindow(from: candidateLines) : candidateLines
        let transcriptLines = selectedLines
            .flatMap(splitIntoReadableLines)
            .map(cleanLine)
            .filter { isTranscriptLine($0) }

        guard isUsableTranscript(transcriptLines, sourceWasHTML: sourceWasHTML, hasExplicitMarker: hasTranscriptMarker) else { return nil }
        return (transcriptLines.joined(separator: "\n"), sourceWasHTML)
    }

    static func plainTextLines(from raw: String) -> [String] {
        cleanedStructuralLines(from: decodeHTMLEntities(raw))
            .flatMap(splitIntoReadableLines)
            .map(cleanLine)
            .filter { isTranscriptLine($0) }
    }

    private static func visibleText(fromHTML html: String) -> String {
        var content = firstCapture(in: html, pattern: #"(?is)<body\b[^>]*>([\s\S]*?)</body>"#) ?? html
        content = regexReplace(content, pattern: #"(?is)<!--[\s\S]*?-->"#, with: "\n")
        content = regexReplace(content, pattern: #"(?is)<!\[CDATA\[[\s\S]*?\]\]>"#, with: "\n")

        for tag in ["script", "style", "noscript", "svg", "canvas", "iframe", "template", "head", "nav", "header", "footer", "form", "select", "button"] {
            content = regexReplace(content, pattern: "(?is)<\(tag)\\b[\\s\\S]*?</\(tag)\\s*>", with: "\n")
        }

        content = regexReplace(content, pattern: #"(?is)<(br|hr)\b[^>]*>"#, with: "\n")
        content = regexReplace(content, pattern: #"(?is)</(p|div|section|article|main|li|ol|ul|h[1-6]|tr|td|blockquote|pre)>"#, with: "\n")
        content = regexReplace(content, pattern: #"(?is)<[^>]+>"#, with: " ")
        return decodeHTMLEntities(content)
    }

    private static func cleanedStructuralLines(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map(cleanLine)
            .filter { !$0.isEmpty && !isGarbageLine($0) }
    }

    private static func transcriptWindow(from lines: [String]) -> [String] {
        guard let markerIndex = lines.firstIndex(where: isTranscriptStartMarker) else {
            return lines
        }

        let start = min(markerIndex + 1, lines.count)
        var output: [String] = []
        for line in lines.dropFirst(start) {
            if output.count >= 4 && isTranscriptEndMarker(line) {
                break
            }
            output.append(line)
        }
        return output.isEmpty ? Array(lines.dropFirst(markerIndex)) : output
    }

    private static func splitIntoReadableLines(_ line: String) -> [String] {
        if line.count <= 240 {
            return [line]
        }

        let pattern = #"(?<=[.!?。！？])\s+"#
        let pieces = regexSplit(line, pattern: pattern)
        if pieces.count > 1 {
            return pieces
        }

        var chunks: [String] = []
        var current = ""
        for word in line.split(separator: " ") {
            if current.count + word.count + 1 > 180 {
                chunks.append(current)
                current = String(word)
            } else {
                current = current.isEmpty ? String(word) : "\(current) \(word)"
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func isTranscriptLine(_ line: String) -> Bool {
        line.count >= 12 && !isGarbageLine(line)
    }

    private static func isUsableTranscript(_ lines: [String], sourceWasHTML: Bool, hasExplicitMarker: Bool = false) -> Bool {
        guard lines.count >= 4 else { return false }
        let joined = lines.joined(separator: " ")
        let wordCount = joined.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.count
        let letterCount = joined.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let garbageCount = lines.filter(isGarbageLine).count

        // Pages with an explicit "Transcript" heading are trusted with lower thresholds.
        // Generic episode pages (show notes) need much higher thresholds.
        let minimumWords: Int
        let minimumLines: Int
        let minimumLongLineRatio: Double

        if hasExplicitMarker {
            minimumWords = 20
            minimumLines = 4
            minimumLongLineRatio = 0.0
        } else if sourceWasHTML {
            minimumWords = 150
            minimumLines = 15
            minimumLongLineRatio = 0.4
        } else {
            minimumWords = 80
            minimumLines = 6
            minimumLongLineRatio = 0.25
        }

        let longLines = lines.filter { $0.count >= 40 }
        let longLineRatio = Double(longLines.count) / Double(max(1, lines.count))

        return wordCount >= minimumWords
            && lines.count >= minimumLines
            && letterCount >= 80
            && garbageCount == 0
            && longLineRatio >= minimumLongLineRatio
    }

    private static func isTranscriptStartMarker(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower == "transcript"
            || lower == "episode transcript"
            || lower == "full transcript"
            || lower.hasPrefix("transcript ")
            || lower.contains("episode transcript")
            || lower.contains("transcript:")
    }

    private static func isTranscriptEndMarker(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower == "show notes"
            || lower == "references"
            || lower == "related episodes"
            || lower == "comments"
            || lower.contains("privacy policy")
            || lower.contains("terms of use")
            || lower.contains("subscribe to")
            || lower.contains("©")
    }

    private static func isGarbageLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let blockedFragments = [
            ".anti-flicker",
            "!important",
            "__next_data__",
            "initsapollo",
            "initapollo",
            "function ",
            "document.",
            "window.",
            "googletag",
            "datalayer",
            "webpack",
            "font-family",
            "display:",
            "visibility:",
            "margin:",
            "padding:",
            "@media",
            "<script",
            "</script",
            "<style",
            "</style",
            "apollo"
        ]
        if blockedFragments.contains(where: { lower.contains($0) }) {
            return true
        }

        if lower.range(of: #"^\s*(var|const|let)\s+[a-z0-9_$]+\s*="#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"^\s*return\s+[\{\[]?"#, options: .regularExpression) != nil && lower.contains(";") {
            return true
        }

        let punctuation = line.filter { "{};=".contains($0) }.count
        if punctuation >= 4 && punctuation * 5 > max(1, line.count) {
            return true
        }

        let noSpaces = !line.contains(" ")
        if noSpaces && line.count > 80 {
            return true
        }

        return false
    }

    private static func cleanLine(_ line: String) -> String {
        regexReplace(line, pattern: #"\s+"#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&mdash;", with: "-")
            .replacingOccurrences(of: "&ndash;", with: "-")
            .replacingOccurrences(of: "&hellip;", with: "...")

        guard let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else {
            return decoded
        }
        let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded))
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: decoded),
                  let wholeRange = Range(match.range(at: 0), in: decoded)
            else { continue }
            let rawNumber = String(decoded[range])
            let value: UInt32?
            if rawNumber.lowercased().hasPrefix("x") {
                value = UInt32(rawNumber.dropFirst(), radix: 16)
            } else {
                value = UInt32(rawNumber, radix: 10)
            }
            guard let value, let scalar = UnicodeScalar(value) else { continue }
            decoded.replaceSubrange(wholeRange, with: String(Character(scalar)))
        }
        return decoded
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func regexReplace(_ text: String, pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func regexSplit(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let ns = text as NSString
        var pieces: [String] = []
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            pieces.append(ns.substring(from: cursor))
        }
        return pieces.map(cleanLine).filter { !$0.isEmpty }
    }
}

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesPodcast]
}

private struct ITunesPodcast: Decodable {
    let collectionName: String?
    let artistName: String?
    let feedUrl: String?

    func score(for track: PlaybackTrack) -> Double {
        max(
            TextNormalizer.similarity(collectionName ?? "", track.podcastShowName),
            TextNormalizer.similarity(artistName ?? "", track.podcastShowName)
        )
    }
}

private struct PodcastFeed {
    let items: [PodcastFeedItem]

    func bestItem(for track: PlaybackTrack) -> PodcastFeedItem? {
        // Episode titles routinely carry numbering prefixes ("Ep. 142:",
        // "#142 –", "Episode 142 —") that the playback side and the RSS feed
        // disagree on. Compare the de-prefixed forms; if the raw title also
        // matches well, take that. Threshold lowered to 0.62 because podcast
        // titles are typically long, so a 0.62 word-overlap is already a
        // reliable signal — 0.72 was rejecting genuine matches.
        let target = Self.stripEpisodeNumber(track.title)
        let scored = items.map { item -> (item: PodcastFeedItem, score: Double) in
            let raw = TextNormalizer.similarity(item.title, track.title)
            let stripped = TextNormalizer.similarity(Self.stripEpisodeNumber(item.title), target)
            return (item, max(raw, stripped))
        }
        guard let best = scored.max(by: { $0.score < $1.score }) else { return nil }
        return best.score >= 0.62 ? best.item : nil
    }

    private static func stripEpisodeNumber(_ title: String) -> String {
        var value = title
        let patterns = [
            #"^\s*(?:ep(?:isode)?\.?|#)\s*\d+\s*[:\-–—|]?\s*"#,
            #"^\s*\d{1,4}\s*[:\-–—|]\s*"#,
            #"\s*[\(\[][^\)\]]{0,30}[\)\]]\s*$"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PodcastFeedItem {
    var title = ""
    var link: URL?
    var description = ""
    var transcriptURLs: [URL] = []
    var audioURL: URL?
}

private final class PodcastFeedParser: NSObject, XMLParserDelegate {
    private var items: [PodcastFeedItem] = []
    private var currentItem: PodcastFeedItem?
    private var currentElement = ""
    private var buffer = ""

    static func parse(_ data: Data) -> PodcastFeed? {
        let delegate = PodcastFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        guard parser.parse() else { return nil }
        return PodcastFeed(items: delegate.items)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = (qName ?? elementName).lowercased()
        currentElement = name
        buffer = ""
        if name == "item" {
            currentItem = PodcastFeedItem()
        } else if currentItem != nil, name.hasSuffix("transcript"), let url = attributeDict["url"] ?? attributeDict["href"], let parsed = URL(string: url) {
            currentItem?.transcriptURLs.append(parsed)
        } else if currentItem != nil, name == "enclosure", let url = attributeDict["url"], let parsed = URL(string: url) {
            currentItem?.audioURL = parsed
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).lowercased()
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if var item = currentItem {
            switch name {
            case "title":
                item.title = value
            case "link":
                item.link = URL(string: value)
            case "description", "itunes:summary", "content:encoded":
                item.description += " \(value)"
            case "item":
                items.append(item)
                currentItem = nil
            default:
                break
            }
            if currentItem != nil {
                currentItem = item
            }
        }
        buffer = ""
        currentElement = ""
    }
}

enum TranscriptParser {
    static func lrcFromVTT(_ text: String) -> String? {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        let lines = blocks.compactMap { block -> (Int, String)? in
            let rows = block.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("WEBVTT") && !$0.hasPrefix("NOTE") }
            guard let timing = rows.first(where: { $0.contains("-->") }) else { return nil }
            let textRows = rows.drop { !$0.contains("-->") }.dropFirst()
            let caption = cleanCaption(textRows.joined(separator: " "))
            guard let start = timing.components(separatedBy: "-->").first.flatMap(parseTimestamp), !caption.isEmpty else { return nil }
            return (start, caption)
        }
        return lrc(from: lines)
    }

    static func lrcFromSRT(_ text: String) -> String? {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        let lines = blocks.compactMap { block -> (Int, String)? in
            let rows = block.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && Int($0) == nil }
            guard let timing = rows.first(where: { $0.contains("-->") }) else { return nil }
            let textRows = rows.drop { !$0.contains("-->") }.dropFirst()
            let caption = cleanCaption(textRows.joined(separator: " "))
            guard let start = timing.components(separatedBy: "-->").first.flatMap(parseTimestamp), !caption.isEmpty else { return nil }
            return (start, caption)
        }
        return lrc(from: lines)
    }

    static func lrcFromPlainText(_ text: String, durationMs: Int?) -> String? {
        let lines = TranscriptTextCleaner.plainTextLines(from: text)
        guard lines.count >= 4 else { return nil }
        let duration = max(60_000, durationMs ?? max(60_000, lines.count * 5_000))
        let step = max(2_000, duration / max(1, lines.count + 1))
        return lines.prefix(400).enumerated().map { index, line in
            "[\(formatLRCTime((index + 1) * step))]\(line)"
        }.joined(separator: "\n")
    }

    private static func lrc(from lines: [(Int, String)]) -> String? {
        let unique = lines
            .filter { !$0.1.isEmpty }
            .sorted { $0.0 < $1.0 }
        guard unique.count >= 2 else { return nil }
        return unique.map { "[\(formatLRCTime($0.0))]\($0.1)" }.joined(separator: "\n")
    }

    private static func parseTimestamp(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let parts = value.components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let hours: Int
        let minutes: Int
        let secondPart: String
        if parts.count == 3 {
            hours = Int(parts[0]) ?? 0
            minutes = Int(parts[1]) ?? 0
            secondPart = parts[2]
        } else {
            hours = 0
            minutes = Int(parts[0]) ?? 0
            secondPart = parts[1]
        }

        let secondsPieces = secondPart.components(separatedBy: ".")
        guard let seconds = Int(secondsPieces[0]) else { return nil }
        let fraction = secondsPieces.count > 1 ? secondsPieces[1] : ""
        let ms: Int
        if fraction.count == 1 {
            ms = (Int(fraction) ?? 0) * 100
        } else if fraction.count == 2 {
            ms = (Int(fraction) ?? 0) * 10
        } else {
            ms = Int(fraction.prefix(3)) ?? 0
        }
        return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + ms
    }

    private static func formatLRCTime(_ ms: Int) -> String {
        let clamped = max(0, ms)
        let minutes = clamped / 60_000
        let seconds = (clamped % 60_000) / 1_000
        let hundredths = (clamped % 1_000) / 10
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }

    private static func cleanCaption(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{[^}]+\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
