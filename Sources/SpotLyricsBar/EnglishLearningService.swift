import Foundation

enum EnglishLearningError: Error {
    case missingAPIKey
    case invalidResponse
    case requestFailed(Int)
    case network
}

@MainActor
final class EnglishLearningService {
    private let settings: LLMSettingsStore
    private let cacheService: LyricsCacheService
    private let session: URLSession
    private var memoryCache: [String: LyricLearningNote] = [:]

    init(settings: LLMSettingsStore, cacheService: LyricsCacheService) {
        self.settings = settings
        self.cacheService = cacheService
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 25
        self.session = URLSession(configuration: configuration)
    }

    func explain(line: String, previous: [String], next: [String], track: PlaybackTrack) async throws -> LyricLearningNote {
        let memKey = "\(track.stableKey)|\(line)"
        if let cached = memoryCache[memKey] { return cached }

        // Persistent cache survives app restarts — explain calls are slow (~5-15s) and
        // the same lyric line is often clicked across sessions.
        if let persisted = await cacheService.cachedExplain(trackKey: track.stableKey, line: line) {
            memoryCache[memKey] = persisted
            return persisted
        }

        let provider = settings.provider
        let apiKey = settings.apiKey()
        guard let apiKey, !apiKey.isEmpty else { throw EnglishLearningError.missingAPIKey }

        let prompt = Self.prompt(line: line, previous: previous, next: next, track: track)
        let requestPlans = requestPlans(provider: provider, apiKey: apiKey, prompt: prompt)
        do {
            var lastError: EnglishLearningError = .network
            for plan in requestPlans {
                do {
                    let (data, response) = try await session.data(for: plan.request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        lastError = .requestFailed(status)
                        if status == 404 || status == 400 { continue }
                        throw lastError
                    }
                    let content = Self.sanitizeText(try extractText(data: data, wireAPI: plan.wireAPI))
                    let note = parseNote(content: content, line: line)
                    memoryCache[memKey] = note
                    Task { await self.cacheService.saveExplain(note, trackKey: track.stableKey, line: line) }
                    return note
                } catch EnglishLearningError.invalidResponse {
                    lastError = .invalidResponse
                    continue
                }
            }
            throw lastError
        } catch let error as EnglishLearningError {
            throw error
        } catch {
            throw EnglishLearningError.network
        }
    }

    func testConnection() async -> String {
        let sampleTrack = PlaybackTrack(title: "Test Song", artist: "Test Artist", album: nil, durationMs: nil, source: .spotify)
        do {
            _ = try await explain(line: "I am feeling good", previous: [], next: [], track: sampleTrack)
            return "Connection works."
        } catch {
            return Self.humanReadable(error)
        }
    }

    private struct RequestPlan {
        let request: URLRequest
        let wireAPI: WireAPI
    }

    private func requestPlans(provider: LLMProviderConfig, apiKey: String, prompt: String) -> [RequestPlan] {
        var apis = [provider.wireAPI]
        if provider.wireAPI == .responses {
            apis.append(.chatCompletions)
        }
        if provider.wireAPI == .chatCompletions {
            apis.append(.responses)
        }
        return apis.compactMap { api in
            var fallbackProvider = provider
            fallbackProvider.wireAPI = api
            guard let request = try? makeRequest(provider: fallbackProvider, apiKey: apiKey, prompt: prompt) else { return nil }
            return RequestPlan(request: request, wireAPI: api)
        }
    }

    private func makeRequest(provider: LLMProviderConfig, apiKey: String, prompt: String) throws -> URLRequest {
        let requestURL: URL
        var body: [String: Any]
        switch provider.wireAPI {
        case .responses:
            requestURL = makeEndpoint(baseURL: provider.baseURL, path: "responses")
            body = [
                "model": provider.model,
                "input": prompt
            ]
            if provider.disableResponseStorage {
                body["store"] = false
            }
            if let effort = provider.reasoningEffort, !effort.isEmpty {
                body["reasoning"] = ["effort": effort]
            }
        case .chatCompletions:
            requestURL = makeEndpoint(baseURL: provider.baseURL, path: "chat/completions")
            body = [
                "model": provider.model,
                "messages": [
                    ["role": "system", "content": "You explain English lyrics in natural Chinese. Be concise, contextual, and careful with sensitive language."],
                    ["role": "user", "content": prompt]
                ],
                "temperature": 0.3
            ]
        case .anthropicMessages:
            requestURL = makeEndpoint(baseURL: provider.baseURL, path: "messages")
            body = [
                "model": provider.model,
                "max_tokens": 700,
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

    private func extractText(data: Data, wireAPI: WireAPI) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EnglishLearningError.invalidResponse
        }
        switch wireAPI {
        case .responses:
            if let text = json["output_text"] as? String { return text }
            if let output = json["output"] as? [[String: Any]] {
                return output
                    .compactMap { item in item["content"] as? [[String: Any]] }
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
        throw EnglishLearningError.invalidResponse
    }

    private func parseNote(content: String, line: String) -> LyricLearningNote {
        let extracted = extractJSONObject(from: content) ?? content
        let normalized = Self.sanitizeText(extracted)
        if let data = normalized.data(using: .utf8),
           let note = try? JSONDecoder().decode(LyricLearningNote.self, from: data) {
            return Self.sanitize(note)
        }

        // JSON parse failed — fall back to a tolerant key-by-key scan so we never
        // dump raw JSON braces/quotes into the UI.
        let lenient = Self.lenientNote(from: extracted, fallbackLine: line)
        if !lenient.meaningInContext.isEmpty || !lenient.naturalChinese.isEmpty {
            return Self.sanitize(lenient)
        }

        return LyricLearningNote(
            line: Self.sanitizeText(line),
            meaningInContext: "AI 返回了无法解析的内容,请重试或换一首。",
            naturalChinese: "AI 返回了无法解析的内容,请重试或换一首。",
            slangOrIdiom: [],
            cultureNote: nil,
            examples: [],
            caution: nil
        )
    }

    private static func lenientNote(from content: String, fallbackLine: String) -> LyricLearningNote {
        func captureString(_ key: String) -> String {
            // Match: "key" : "value" with escaped quotes inside value.
            let pattern = "\"\(key)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: content)
            else { return "" }
            return unescapeJSONLiteral(String(content[range]))
        }
        func captureArray(_ key: String) -> [String] {
            let pattern = "\"\(key)\"\\s*:\\s*\\[((?:[^\\[\\]]|\\\\.)*)\\]"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: content)
            else { return [] }
            let inner = String(content[range])
            let itemPattern = "\"((?:[^\"\\\\]|\\\\.)*)\""
            guard let itemRegex = try? NSRegularExpression(pattern: itemPattern) else { return [] }
            let nsInner = inner as NSString
            return itemRegex.matches(in: inner, range: NSRange(location: 0, length: nsInner.length))
                .compactMap { Range($0.range(at: 1), in: inner).map { unescapeJSONLiteral(String(inner[$0])) } }
                .filter { !$0.isEmpty }
        }

        let lineValue = captureString("line").isEmpty ? fallbackLine : captureString("line")
        return LyricLearningNote(
            line: lineValue,
            meaningInContext: captureString("meaningInContext"),
            naturalChinese: captureString("naturalChinese"),
            slangOrIdiom: captureArray("slangOrIdiom"),
            cultureNote: captureString("cultureNote").isEmpty ? nil : captureString("cultureNote"),
            examples: captureArray("examples"),
            caution: captureString("caution").isEmpty ? nil : captureString("caution")
        )
    }

    private static func unescapeJSONLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\/", with: "/")
    }

    private func extractJSONObject(from content: String) -> String? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
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
            if escaping {
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
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

    private static func sanitize(_ note: LyricLearningNote) -> LyricLearningNote {
        LyricLearningNote(
            line: sanitizeText(note.line),
            meaningInContext: sanitizeText(note.meaningInContext),
            naturalChinese: sanitizeText(note.naturalChinese),
            slangOrIdiom: note.slangOrIdiom.map(sanitizeText).filter { !$0.isEmpty },
            cultureNote: note.cultureNote.map(sanitizeText),
            examples: note.examples.map(sanitizeText).filter { !$0.isEmpty },
            caution: note.caution.map(sanitizeText)
        )
    }

    private static func sanitizeText(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        value = String(value.unicodeScalars.filter { scalar in
            scalar.value == 9
                || scalar.value == 10
                || scalar.value >= 32
        })
        value = value
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: #"\\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "The provider returned an empty explanation. Try again." : value
    }

    static func prompt(line: String, previous: [String], next: [String], track: PlaybackTrack) -> String {
        """
        Explain this lyric line for a Chinese speaker learning real English.

        Song: \(track.title)
        Artist: \(track.artist)
        Previous context: \(previous.joined(separator: " / "))
        Current line: \(line)
        Next context: \(next.joined(separator: " / "))

        Return compact JSON with exactly these keys:
        line, meaningInContext, naturalChinese, slangOrIdiom, cultureNote, examples, caution.
        Use Chinese for explanations, keep key English phrases, give 1-3 natural examples.
        Do not translate a whole song. Do not invent cultural references. If offensive, sexual,
        outdated, sarcastic, romantic, casual, or Gen Z-coded, say so plainly.
        """
    }

    static func humanReadable(_ error: Error) -> String {
        switch error {
        case EnglishLearningError.missingAPIKey:
            return "Please add an API Key in AI Settings first."
        case EnglishLearningError.invalidResponse:
            return "The provider replied in an unexpected format."
        case EnglishLearningError.requestFailed(let status):
            if status == 401 || status == 403 { return "API Key is invalid or not allowed." }
            if status == 404 { return "Model name or API URL was not found." }
            if status == 400 { return "Provider rejected this wire API. Try Chat Completions in AI Settings." }
            if status == 429 { return "Provider rate limit reached. Try again later." }
            return "Provider request failed with HTTP \(status)."
        default:
            return "Network error. Check the API URL and internet connection."
        }
    }
}
