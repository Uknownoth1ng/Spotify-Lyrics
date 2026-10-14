import Foundation

@MainActor
final class SpotifyTranscriptService {
    private let session: URLSession
    private var cachedToken: (token: String, expiresAt: Date)?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    func fetchTranscript(episodeID: String, spDcCookie: String) async -> String? {
        guard let token = await getAccessToken(spDcCookie: spDcCookie) else {
            NSLog("SpotLyrics Spotify Transcript: failed to get access token")
            return nil
        }

        guard let transcriptJSON = await fetchTranscriptJSON(episodeID: episodeID, token: token) else {
            NSLog("SpotLyrics Spotify Transcript: no transcript for %@", episodeID)
            return nil
        }

        guard let lrc = parseTranscriptJSON(transcriptJSON) else {
            NSLog("SpotLyrics Spotify Transcript: failed to parse transcript JSON")
            return nil
        }

        NSLog("SpotLyrics Spotify Transcript: got %d lines", lrc.components(separatedBy: "\n").count)
        return lrc
    }

    private func getAccessToken(spDcCookie: String) async -> String? {
        if let cached = cachedToken, Date() < cached.expiresAt {
            return cached.token
        }

        let token = await fetchTokenViaCurl(spDcCookie: spDcCookie)
        if let token {
            cachedToken = (token: token, expiresAt: Date().addingTimeInterval(3500))
        }
        return token
    }

    private func fetchTokenViaCurl(spDcCookie: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                process.arguments = [
                    "-s", "--max-time", "8",
                    "-H", "Cookie: sp_dc=\(spDcCookie)",
                    "-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
                    "-H", "Accept: application/json",
                    "-H", "Accept-Language: en-US,en;q=0.9",
                    "-H", "Referer: https://open.spotify.com/",
                    "-H", "Origin: https://open.spotify.com",
                    "https://open.spotify.com/get_access_token?reason=transport&productType=web_player"
                ]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = json["accessToken"] as? String,
                      json["isAnonymous"] as? Bool == false else {
                    let str = String(data: data, encoding: .utf8) ?? ""
                    NSLog("SpotLyrics Spotify Transcript: token response: %@", String(str.prefix(100)))
                    continuation.resume(returning: nil)
                    return
                }

                NSLog("SpotLyrics Spotify Transcript: got access token")
                continuation.resume(returning: token)
            }
        }
    }

    private func fetchTranscriptJSON(episodeID: String, token: String) async -> [String: Any]? {
        guard let url = URL(string: "https://spclient.wg.spotify.com/transcript-read-along/v2/episode/\(episodeID)?format=json") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("WebPlayer", forHTTPHeaderField: "App-Platform")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func parseTranscriptJSON(_ json: [String: Any]) -> String? {
        // Try format: { "section": [...], "language": "en" }
        // Each section has "startMs", "duration", "text" or "words"
        if let sections = json["section"] as? [[String: Any]] {
            return parseSections(sections)
        }

        // Try format similar to lyrics: { "transcript": { "lines": [...] } }
        if let transcript = json["transcript"] as? [String: Any],
           let lines = transcript["lines"] as? [[String: Any]] {
            return parseLines(lines)
        }

        // Try flat lines array
        if let lines = json["lines"] as? [[String: Any]] {
            return parseLines(lines)
        }

        // Try "body" wrapper
        if let body = json["body"] as? [String: Any] {
            return parseTranscriptJSON(body)
        }

        return nil
    }

    private func parseSections(_ sections: [[String: Any]]) -> String? {
        var lrcLines: [String] = []

        for (index, section) in sections.enumerated() {
            // Skip untimed sections rather than defaulting to 0. A JSON shape
            // with a missing field would otherwise stamp every untimed line at
            // 00:00.00 — synced playback then locks to the first line for the
            // entire episode. The first section is allowed to have no timestamp
            // (treated as 0) since transcripts conventionally start at 0.
            let parsedStart = intValue(section["startMs"])
                ?? intValue(section["start_ms"])
                ?? intValue(section["startTimeMs"])
            guard let startMs = parsedStart ?? (index == 0 ? 0 : nil) else { continue }
            let text: String
            if let words = section["text"] as? [[String: Any]] {
                text = words.compactMap { $0["word"] as? String ?? $0["text"] as? String }
                    .joined(separator: " ")
            } else if let str = section["text"] as? String {
                text = str
            } else if let words = section["words"] as? [[String: Any]] {
                text = words.compactMap { $0["word"] as? String ?? $0["text"] as? String }
                    .joined(separator: " ")
            } else {
                continue
            }

            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            let min = startMs / 60000
            let sec = (startMs % 60000) / 1000
            let hundredths = (startMs % 1000) / 10
            lrcLines.append("[\(String(format: "%02d:%02d.%02d", min, sec, hundredths))]\(cleaned)")
        }

        guard lrcLines.count >= 3 else { return nil }
        return lrcLines.joined(separator: "\n")
    }

    private func parseLines(_ lines: [[String: Any]]) -> String? {
        var lrcLines: [String] = []

        for (index, line) in lines.enumerated() {
            let parsedStart = intValue(line["startTimeMs"])
                ?? intValue(line["startMs"])
                ?? intValue(line["start"])
            guard let startMs = parsedStart ?? (index == 0 ? 0 : nil) else { continue }
            let text = (line["words"] as? String)
                ?? (line["text"] as? String)
                ?? (line["sentence"] as? String)
                ?? ""
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            let min = startMs / 60000
            let sec = (startMs % 60000) / 1000
            let hundredths = (startMs % 1000) / 10
            lrcLines.append("[\(String(format: "%02d:%02d.%02d", min, sec, hundredths))]\(cleaned)")
        }

        guard lrcLines.count >= 3 else { return nil }
        return lrcLines.joined(separator: "\n")
    }

    private func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let s = value as? String, let i = Int(s) { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }
}
