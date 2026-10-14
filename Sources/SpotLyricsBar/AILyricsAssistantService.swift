import Foundation

struct LyricsIdentityHints: Equatable {
    var altTitles: [String]
    var altArtists: [String]
}

enum AILyricsAssistantError: Error {
    case missingAPIKey
    case invalidResponse
    case requestFailed(Int)
    case network
    case empty
}

/// Calls the user-configured LLM to either:
/// 1. Translate / romanize-to-CJK the artist + title so we can re-query public sources
///    ("A-Mei Chang" → "张惠妹"; "Faye Wong" → "王菲"); or
/// 2. Generate a synced .lrc directly when all public sources fail. The LLM is told the
///    track duration so it can align timestamps to the actual playback length.
@MainActor
final class AILyricsAssistantService {
    private let settings: LLMSettingsStore
    private let session: URLSession
    private var hintsCache: [String: LyricsIdentityHints] = [:]
    private var lyricsCache: [String: LyricsCandidate] = [:]

    init(settings: LLMSettingsStore) {
        self.settings = settings
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    var isConfigured: Bool {
        if let key = settings.apiKey(), !key.isEmpty { return true }
        return false
    }

    func rewriteIdentity(for track: PlaybackTrack) async throws -> LyricsIdentityHints {
        let cacheKey = "rewrite|\(track.stableKey)"
        if let cached = hintsCache[cacheKey] { return cached }
        guard let apiKey = settings.apiKey(), !apiKey.isEmpty else {
            throw AILyricsAssistantError.missingAPIKey
        }
        let prompt = Self.rewritePrompt(track: track)
        let raw = try await call(prompt: prompt, apiKey: apiKey, maxTokens: 400)
        let hints = Self.parseHints(content: raw)
        if hints.altTitles.isEmpty, hints.altArtists.isEmpty {
            throw AILyricsAssistantError.empty
        }
        hintsCache[cacheKey] = hints
        return hints
    }

    func generateLyrics(for track: PlaybackTrack, hints: LyricsIdentityHints?) async throws -> LyricsCandidate {
        let cacheKey = "gen|\(track.stableKey)"
        if let cached = lyricsCache[cacheKey] { return cached }
        guard let apiKey = settings.apiKey(), !apiKey.isEmpty else {
            throw AILyricsAssistantError.missingAPIKey
        }
        let prompt = Self.generatePrompt(track: track, hints: hints)
        let raw = try await call(prompt: prompt, apiKey: apiKey, maxTokens: 1800)
        let payload = Self.parseLyricsPayload(content: raw)
        guard let lrc = payload?.lrc, !lrc.isEmpty else {
            throw AILyricsAssistantError.empty
        }
        let confidence = payload?.confidence ?? 0.3
        let candidate = LyricsCandidate(
            trackName: track.title,
            artistName: track.artist,
            albumName: track.album,
            durationMs: track.durationMs,
            syncedLyrics: lrc,
            plainLyrics: nil,
            source: "AI generated",
            confidence: confidence
        )
        lyricsCache[cacheKey] = candidate
        return candidate
    }

    // MARK: - Networking

    private struct RequestPlan {
        let request: URLRequest
        let wireAPI: WireAPI
    }

    private func call(prompt: String, apiKey: String, maxTokens: Int) async throws -> String {
        var apis: [WireAPI] = [settings.provider.wireAPI]
        if settings.provider.wireAPI == .responses { apis.append(.chatCompletions) }
        if settings.provider.wireAPI == .chatCompletions { apis.append(.responses) }

        var lastError: AILyricsAssistantError = .network
        for api in apis {
            var providerCopy = settings.provider
            providerCopy.wireAPI = api
            guard let request = try? makeRequest(provider: providerCopy, apiKey: apiKey, prompt: prompt, maxTokens: maxTokens) else { continue }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    lastError = .requestFailed(status)
                    if status == 400 || status == 404 { continue }
                    throw lastError
                }
                let text = try Self.extractText(data: data, wireAPI: api)
                if !text.isEmpty { return text }
                lastError = .invalidResponse
            } catch let error as AILyricsAssistantError {
                lastError = error
                continue
            } catch is CancellationError {
                throw AILyricsAssistantError.network
            } catch {
                lastError = .network
                continue
            }
        }
        throw lastError
    }

    private func makeRequest(provider: LLMProviderConfig, apiKey: String, prompt: String, maxTokens: Int) throws -> URLRequest {
        let requestURL: URL
        var body: [String: Any]
        switch provider.wireAPI {
        case .responses:
            requestURL = makeEndpoint(baseURL: provider.baseURL, path: "responses")
            body = [
                "model": provider.model,
                "input": prompt
            ]
            if provider.disableResponseStorage { body["store"] = false }
            if let effort = provider.reasoningEffort, !effort.isEmpty {
                body["reasoning"] = ["effort": effort]
            }
        case .chatCompletions:
            requestURL = makeEndpoint(baseURL: provider.baseURL, path: "chat/completions")
            body = [
                "model": provider.model,
                "messages": [
                    ["role": "system", "content": "You assist with finding accurate, public-domain song lyrics for a desktop player. Respond with strict JSON only."],
                    ["role": "user", "content": prompt]
                ],
                "temperature": 0.2
            ]
        case .anthropicMessages:
            requestURL = makeEndpoint(baseURL: provider.baseURL, path: "messages")
            body = [
                "model": provider.model,
                "max_tokens": maxTokens,
                "messages": [
                    ["role": "user", "content": prompt]
                ]
            ]
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider.wireAPI == .anthropicMessages {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func makeEndpoint(baseURL: URL, path: String) -> URL {
        let absolute = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if absolute.hasSuffix("/\(path)") {
            return URL(string: absolute)!
        }
        return URL(string: absolute + "/" + path)!
    }

    private static func extractText(data: Data, wireAPI: WireAPI) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AILyricsAssistantError.invalidResponse
        }
        switch wireAPI {
        case .responses:
            if let text = json["output_text"] as? String { return text }
            if let output = json["output"] as? [[String: Any]] {
                return output
                    .compactMap { $0["content"] as? [[String: Any]] }
                    .flatMap { $0 }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
            }
        case .chatCompletions:
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        case .anthropicMessages:
            if let content = json["content"] as? [[String: Any]] {
                return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
        }
        throw AILyricsAssistantError.invalidResponse
    }

    // MARK: - Prompts

    static func rewritePrompt(track: PlaybackTrack) -> String {
        let duration = track.durationMs.map { "\($0 / 1000)s" } ?? "unknown"
        return """
        A music app could not find lyrics for this song using the title and artist exactly as
        provided. The artist name may be a romanization or stage name, and the title may be in
        the wrong script (Simplified vs Traditional Chinese, etc.).

        Song title (as Spotify shows it): \(track.title)
        Artist (as Spotify shows it): \(track.artist)
        Album: \(track.album ?? "(unknown)")
        Duration: \(duration)

        Identify this song. Return strict JSON ONLY (no prose, no code fences):
        {
          "altTitles":  [up to 4 alternative titles, including Simplified Chinese, Traditional
                         Chinese, the same title without bracketed suffixes, and the most
                         widely-indexed form on Chinese music databases like NetEase],
          "altArtists": [up to 4 alternative artist names — include the official Chinese name
                         (Simplified and Traditional), the romanized stage name, and any
                         common alias. For "A-Mei Chang" return "张惠妹","張惠妹","A-Mei".
                         For "Faye Wong" return "王菲","Faye Wong"]
        }

        Strings must be plain text. No commentary. If you are unsure, still provide your best guess.
        """
    }

    static func generatePrompt(track: PlaybackTrack, hints: LyricsIdentityHints?) -> String {
        let duration = track.durationMs.map { "\($0 / 1000) seconds" } ?? "unknown duration"
        let durationMs = track.durationMs.map { String($0) } ?? "unknown"
        let altTitles = hints?.altTitles.joined(separator: ", ") ?? ""
        let altArtists = hints?.altArtists.joined(separator: ", ") ?? ""
        return """
        Produce a synced .lrc file for the following song. The audio player will display these
        timestamps live, so timing realism matters more than perfect line breaks.

        Song title: \(track.title)
        Artist: \(track.artist)
        Album: \(track.album ?? "(unknown)")
        Duration: \(duration) (\(durationMs) ms)
        Possible alternative titles: \(altTitles.isEmpty ? "(none)" : altTitles)
        Possible alternative artist names: \(altArtists.isEmpty ? "(none)" : altArtists)

        Rules:
        - Output strict JSON only with this exact shape:
          {"lrc":"<full LRC text with [mm:ss.xx] timestamps, one line per [..] tag>",
           "confidence": <0.0-1.0 number reflecting how sure you are these are the actual lyrics>}
        - Use only widely-known, publicly-released lyrics. If you do not know this song's lyrics
          with reasonable confidence, return {"lrc":"","confidence":0}.
        - Do NOT invent or paraphrase. Do NOT translate the lyrics — keep them in the original
          language they were sung in.
        - CRITICAL — Original script only:
          • Mandopop / Cantopop / C-pop / Taiwanese / Cantonese songs MUST be returned in
            Traditional or Simplified Chinese characters as originally released.
            Example: Rainie Yang's 曖昧 must be "何時該前進", NOT "He shi gai qian jin".
            Example: 王菲's 執迷不悔 must be "我不曾後悔", NOT "Wo bu ceng hou hui".
          • J-pop must be in Japanese (kana + kanji), not romaji.
          • K-pop must be in Hangul, not romanization.
          • An English-spelled artist name (e.g. "Rainie Yang", "Faye Wong", "A-Mei Chang")
            does NOT mean the lyrics are in English; map the name to the actual artist
            and use the script their songs were released in.
          • NEVER output Pinyin, Romaji, or any Latin transliteration of CJK lyrics.
            If you cannot recall the original script with confidence, return
            {"lrc":"","confidence":0} instead of romanizing.
        - Cover the entire duration. The first lyric line should appear after the intro (~10-25s
          for typical Mandopop / Cantopop), and the last lyric line should be before the song
          ends. Distribute lines evenly enough that lines do not pile up at the start.
        - Use [mm:ss.xx] format. No leading "lrc:" prefix inside the field.
        - No code fences. No Markdown. JSON only.
        """
    }

    // MARK: - Parsing

    private struct LyricsPayload {
        let lrc: String
        let confidence: Double
    }

    private static func parseHints(content: String) -> LyricsIdentityHints {
        let json = extractJSONObject(from: content) ?? content
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return LyricsIdentityHints(altTitles: [], altArtists: [])
        }
        let titles = (object["altTitles"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let artists = (object["altArtists"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return LyricsIdentityHints(altTitles: dedupe(titles), altArtists: dedupe(artists))
    }

    private static func parseLyricsPayload(content: String) -> LyricsPayload? {
        let json = extractJSONObject(from: content) ?? content
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let lrcRaw = (object["lrc"] as? String) ?? ""
        let lrc = lrcRaw
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence: Double
        if let n = object["confidence"] as? Double {
            confidence = n
        } else if let s = object["confidence"] as? String, let n = Double(s) {
            confidence = n
        } else {
            // Missing confidence almost always means the LLM hallucinated past the
            // schema. Default low so the gate in AppState rejects it unless the LLM
            // *explicitly* claims confidence.
            confidence = 0.3
        }
        return LyricsPayload(lrc: lrc, confidence: max(0, min(1, confidence)))
    }

    private static func extractJSONObject(from content: String) -> String? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaping = false
        var endIndex: String.Index?
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if escaping { escaping = false }
            else if char == "\\" { escaping = true }
            else if char == "\"" { inString.toggle() }
            else if !inString {
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = text.index(after: index)
                        break
                    }
                }
            }
            index = text.index(after: index)
        }
        guard let endIndex else { return nil }
        return String(text[start..<endIndex])
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for v in values where seen.insert(v).inserted {
            out.append(v)
        }
        return out
    }

    static func humanReadable(_ error: Error) -> String {
        switch error {
        case AILyricsAssistantError.missingAPIKey:
            return "Add an API Key in AI Settings first."
        case AILyricsAssistantError.requestFailed(let status):
            return "AI provider returned HTTP \(status)."
        case AILyricsAssistantError.invalidResponse:
            return "AI provider replied in an unexpected format."
        case AILyricsAssistantError.empty:
            return "AI did not provide a usable answer."
        default:
            return "AI request failed (network)."
        }
    }
}
