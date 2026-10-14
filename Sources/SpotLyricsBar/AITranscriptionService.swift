import AVFoundation
import Foundation

enum AITranscriptionError: Error {
    case missingAPIKey
    case unsupportedProvider
    case invalidResponse
    case requestFailed(Int)
    case network
    case audioPreparationFailed
    case audioFileTooLarge(Int)
}

@MainActor
final class AITranscriptionService {
    private static let maxUploadBytes = 24 * 1024 * 1024
    private static let preferredChunkSeconds: TimeInterval = 2 * 60
    private static let minimumChunkSeconds: TimeInterval = 45

    private let settings: LLMSettingsStore
    private let session: URLSession

    init(settings: LLMSettingsStore) {
        self.settings = settings
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 1_800
        self.session = URLSession(configuration: configuration)
    }

    var isConfigured: Bool {
        if let key = settings.apiKey(), !key.isEmpty { return true }
        return false
    }

    func transcribe(fileURL: URL, track: PlaybackTrack) async throws -> LyricsCandidate {
        try await transcribe(
            localFileURL: fileURL,
            preferredFilename: fileURL.lastPathComponent,
            track: track,
            source: "AI transcribed podcast"
        )
    }

    func transcribe(audioURL: URL, track: PlaybackTrack) async throws -> LyricsCandidate {
        let downloaded = try await downloadAudio(from: audioURL, track: track)
        defer { try? FileManager.default.removeItem(at: downloaded.fileURL) }
        return try await transcribe(
            localFileURL: downloaded.fileURL,
            preferredFilename: downloaded.filename,
            track: track,
            source: "AI transcribed RSS audio"
        )
    }

    private func transcribe(
        localFileURL: URL,
        preferredFilename: String,
        track: PlaybackTrack,
        source: String
    ) async throws -> LyricsCandidate {
        guard let apiKey = settings.apiKey(), !apiKey.isEmpty else {
            throw AITranscriptionError.missingAPIKey
        }
        guard settings.provider.wireAPI != .anthropicMessages else {
            throw AITranscriptionError.unsupportedProvider
        }

        let chunks = try await uploadChunks(for: localFileURL, preferredFilename: preferredFilename)
        defer {
            for chunk in chunks where chunk.shouldDelete {
                try? FileManager.default.removeItem(at: chunk.fileURL)
            }
        }

        var lrcPieces: [String] = []
        for chunk in chunks {
            let data = try Data(contentsOf: chunk.fileURL)
            guard data.count <= Self.maxUploadBytes else {
                throw AITranscriptionError.audioFileTooLarge(data.count)
            }
            let piece = try await transcribeChunk(
                data: data,
                filename: chunk.filename,
                track: track,
                apiKey: apiKey,
                offsetMs: chunk.offsetMs,
                chunkDurationMs: chunk.durationMs
            )
            lrcPieces.append(piece)
        }

        let lrc = Self.mergeLRCPieces(lrcPieces)
        guard LRCParser.parse(lrc).count >= 2 else {
            throw AITranscriptionError.invalidResponse
        }
        return LyricsCandidate(
            trackName: track.title,
            artistName: track.podcastShowName,
            albumName: track.album,
            durationMs: track.durationMs,
            syncedLyrics: lrc,
            plainLyrics: lrc,
            source: source,
            confidence: 0.86
        )
    }

    private func transcribeChunk(
        data: Data,
        filename: String,
        track: PlaybackTrack,
        apiKey: String,
        offsetMs: Int,
        chunkDurationMs: Int?
    ) async throws -> String {
        var lastError: Error?
        for plan in transcriptionPlans() {
            do {
                return try await transcribeChunk(
                    data: data,
                    filename: filename,
                    track: track,
                    apiKey: apiKey,
                    offsetMs: offsetMs,
                    chunkDurationMs: chunkDurationMs,
                    plan: plan
                )
            } catch AITranscriptionError.requestFailed(let status) where [400, 404, 422].contains(status) {
                lastError = AITranscriptionError.requestFailed(status)
                continue
            } catch AITranscriptionError.invalidResponse {
                lastError = AITranscriptionError.invalidResponse
                continue
            } catch {
                throw error
            }
        }
        throw lastError ?? AITranscriptionError.invalidResponse
    }

    private func transcribeChunk(
        data: Data,
        filename: String,
        track: PlaybackTrack,
        apiKey: String,
        offsetMs: Int,
        chunkDurationMs: Int?,
        plan: TranscriptionPlan
    ) async throws -> String {
        let endpoint = makeEndpoint(baseURL: settings.provider.baseURL, path: "audio/transcriptions")
        let boundary = "SpotLyricsBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary,
            filename: filename,
            fileData: data,
            track: track,
            plan: plan
        )

        do {
            let (responseData, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw AITranscriptionError.requestFailed(status)
            }
            return try Self.extractLRC(
                data: responseData,
                track: track,
                chunkOffsetMs: offsetMs,
                chunkDurationMs: chunkDurationMs
            )
        } catch let error as AITranscriptionError {
            throw error
        } catch {
            throw AITranscriptionError.network
        }
    }

    private func multipartBody(
        boundary: String,
        filename: String,
        fileData: Data,
        track: PlaybackTrack,
        plan: TranscriptionPlan
    ) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(plan.model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("\(plan.responseFormat)\r\n")

        if let timestampGranularity = plan.timestampGranularity {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n")
            append("\(timestampGranularity)\r\n")
        }

        if let chunkingStrategy = plan.chunkingStrategy {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"chunking_strategy\"\r\n\r\n")
            append("\(chunkingStrategy)\r\n")
        }

        if plan.supportsPrompt {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append("Podcast episode: \(track.title). Show: \(track.podcastShowName). Return accurate English transcript segments.\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType(forFilename: filename))\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private func transcriptionPlans() -> [TranscriptionPlan] {
        let configured = settings.provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = configured.lowercased()

        func appendUnique(_ plan: TranscriptionPlan, to plans: inout [TranscriptionPlan]) {
            let key = "\(plan.model)|\(plan.responseFormat)|\(plan.timestampGranularity ?? "")|\(plan.chunkingStrategy ?? "")"
            let exists = plans.contains {
                "\($0.model)|\($0.responseFormat)|\($0.timestampGranularity ?? "")|\($0.chunkingStrategy ?? "")" == key
            }
            if !exists {
                plans.append(plan)
            }
        }

        if lower.contains("diarize") {
            return [TranscriptionPlan(
                model: configured.isEmpty ? "gpt-4o-transcribe-diarize" : configured,
                responseFormat: "diarized_json",
                timestampGranularity: nil,
                chunkingStrategy: "auto",
                supportsPrompt: false
            )]
        }

        var plans: [TranscriptionPlan] = []

        if !configured.isEmpty {
            appendUnique(
                TranscriptionPlan(
                    model: configured,
                    responseFormat: "json",
                    timestampGranularity: nil,
                    chunkingStrategy: nil,
                    supportsPrompt: true
                ),
                to: &plans
            )
        }

        if lower.contains("whisper") {
            plans.removeAll()
            appendUnique(
                TranscriptionPlan(
                    model: configured,
                    responseFormat: "verbose_json",
                    timestampGranularity: "segment",
                    chunkingStrategy: nil,
                    supportsPrompt: true
                ),
                to: &plans
            )
            return plans
        }

        if lower.contains("transcribe") {
            if !lower.contains("diarize") {
                appendUnique(
                    TranscriptionPlan(
                        model: "gpt-4o-transcribe-diarize",
                        responseFormat: "diarized_json",
                        timestampGranularity: nil,
                        chunkingStrategy: "auto",
                        supportsPrompt: false
                    ),
                    to: &plans
                )
            }
            appendUnique(
                TranscriptionPlan(
                    model: "whisper-1",
                    responseFormat: "verbose_json",
                    timestampGranularity: "segment",
                    chunkingStrategy: nil,
                    supportsPrompt: true
                ),
                to: &plans
            )
            return plans
        }

        // Prefer OpenAI's higher-accuracy GPT-4o transcription family. The diarize
        // variant returns timed segments, which is exactly what the lyric bar needs.
        // If the user configured a GPT-5.x style model through a relay, try it first
        // with chunk-based timing. If the relay rejects that model on the audio
        // endpoint, fall back to known transcription models automatically.
        appendUnique(
            TranscriptionPlan(
                model: "gpt-4o-transcribe-diarize",
                responseFormat: "diarized_json",
                timestampGranularity: nil,
                chunkingStrategy: "auto",
                supportsPrompt: false
            ),
            to: &plans
        )
        appendUnique(
            TranscriptionPlan(
                model: "gpt-4o-transcribe",
                responseFormat: "json",
                timestampGranularity: nil,
                chunkingStrategy: nil,
                supportsPrompt: true
            ),
            to: &plans
        )
        appendUnique(
            TranscriptionPlan(
                model: "whisper-1",
                responseFormat: "verbose_json",
                timestampGranularity: "segment",
                chunkingStrategy: nil,
                supportsPrompt: true
            ),
            to: &plans
        )
        return plans
    }

    private func makeEndpoint(baseURL: URL, path: String) -> URL {
        let absolute = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if absolute.hasSuffix("/\(path)") {
            return URL(string: absolute)!
        }
        return URL(string: absolute + "/" + path)!
    }

    private func mimeType(forFilename filename: String) -> String {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }

    private func downloadAudio(from audioURL: URL, track: PlaybackTrack) async throws -> DownloadedAudio {
        do {
            let (temporaryURL, response) = try await session.download(from: audioURL)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                throw AITranscriptionError.network
            }
            let filename = sanitizedFilename(
                response.suggestedFilename
                    ?? (audioURL.lastPathComponent.isEmpty ? "\(TextNormalizer.stableTextHash(track.title)).mp3" : audioURL.lastPathComponent)
            )
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("SpotLyrics-\(UUID().uuidString)-\(filename)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return DownloadedAudio(fileURL: destination, filename: filename)
        } catch let error as AITranscriptionError {
            throw error
        } catch {
            throw AITranscriptionError.network
        }
    }

    private func uploadChunks(for fileURL: URL, preferredFilename: String) async throws -> [AudioChunk] {
        let originalSize = try fileSize(of: fileURL)
        let sanitizedOriginal = sanitizedFilename(preferredFilename.isEmpty ? fileURL.lastPathComponent : preferredFilename)
        let asset = AVURLAsset(url: fileURL)
        let durationSeconds: TimeInterval?
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            durationSeconds = seconds.isFinite && seconds > 0 ? seconds : nil
        } catch {
            durationSeconds = nil
        }

        if originalSize <= Self.maxUploadBytes,
           (durationSeconds ?? 0) <= Self.preferredChunkSeconds {
            return [
                AudioChunk(
                    fileURL: fileURL,
                    filename: sanitizedOriginal,
                    offsetMs: 0,
                    durationMs: durationSeconds.map { Int($0 * 1000) },
                    shouldDelete: false
                )
            ]
        }

        guard let durationSeconds else {
            throw AITranscriptionError.audioPreparationFailed
        }

        let estimatedSecondsBySize = durationSeconds * Double(Self.maxUploadBytes) / Double(max(1, originalSize)) * 0.70
        let baseChunkSeconds = min(
            Self.preferredChunkSeconds,
            max(Self.minimumChunkSeconds, estimatedSecondsBySize)
        )

        var chunks: [AudioChunk] = []
        var start: TimeInterval = 0
        var index = 0

        while start < durationSeconds - 0.5 {
            var chunkSeconds = min(baseChunkSeconds, durationSeconds - start)
            var exportedURL: URL?
            while chunkSeconds >= Self.minimumChunkSeconds {
                let candidateURL = try await exportChunk(
                    asset: asset,
                    start: start,
                    duration: chunkSeconds,
                    index: index
                )
                let candidateSize = try fileSize(of: candidateURL)
                if candidateSize <= Self.maxUploadBytes {
                    exportedURL = candidateURL
                    break
                }
                try? FileManager.default.removeItem(at: candidateURL)
                chunkSeconds = chunkSeconds / 2
            }

            guard let exportedURL else {
                throw AITranscriptionError.audioPreparationFailed
            }

            chunks.append(
                AudioChunk(
                    fileURL: exportedURL,
                    filename: "spotlyrics-podcast-\(index + 1).m4a",
                    offsetMs: Int(start * 1000),
                    durationMs: Int(chunkSeconds * 1000),
                    shouldDelete: true
                )
            )
            start += chunkSeconds
            index += 1
        }

        guard !chunks.isEmpty else { throw AITranscriptionError.audioPreparationFailed }
        return chunks
    }

    private func exportChunk(asset: AVURLAsset, start: TimeInterval, duration: TimeInterval, index: Int) async throws -> URL {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AITranscriptionError.audioPreparationFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotLyrics-chunk-\(UUID().uuidString)-\(index).m4a")
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        exporter.shouldOptimizeForNetworkUse = true

        if #available(macOS 15.0, *) {
            try await exporter.export(to: outputURL, as: .m4a)
        } else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed:
                        continuation.resume()
                    case .failed, .cancelled:
                        continuation.resume(throwing: exporter.error ?? AITranscriptionError.audioPreparationFailed)
                    default:
                        continuation.resume(throwing: AITranscriptionError.audioPreparationFailed)
                    }
                }
            }
        }
        return outputURL
    }

    private func fileSize(of url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "podcast-audio.mp3" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = fallback
            .components(separatedBy: invalid)
            .joined(separator: "-")
        return cleaned.isEmpty ? "podcast-audio.mp3" : cleaned
    }

    nonisolated static func extractLRC(
        data: Data,
        track: PlaybackTrack,
        chunkOffsetMs: Int = 0,
        chunkDurationMs: Int? = nil
    ) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8),
               let estimated = estimatedLRC(from: text, track: track, chunkOffsetMs: chunkOffsetMs, chunkDurationMs: chunkDurationMs) {
                return estimated
            }
            throw AITranscriptionError.invalidResponse
        }
        if let segments = object["diarized_segments"] as? [[String: Any]], !segments.isEmpty,
           let diarized = lrcFromSegments(segments, chunkOffsetMs: chunkOffsetMs) {
            return diarized
        }
        if let segments = object["transcript_segments"] as? [[String: Any]], !segments.isEmpty,
           let diarized = lrcFromSegments(segments, chunkOffsetMs: chunkOffsetMs) {
            return diarized
        }
        if let words = object["words"] as? [[String: Any]], !words.isEmpty,
           let wordLRC = lrcFromWords(words, chunkOffsetMs: chunkOffsetMs) {
            return wordLRC
        }
        if let segments = object["segments"] as? [[String: Any]], !segments.isEmpty,
           let segmented = lrcFromSegments(segments, chunkOffsetMs: chunkOffsetMs) {
            return segmented
        }
        if let text = object["text"] as? String,
           let estimated = estimatedLRC(from: text, track: track, chunkOffsetMs: chunkOffsetMs, chunkDurationMs: chunkDurationMs) {
            return estimated
        }
        throw AITranscriptionError.invalidResponse
    }

    nonisolated private static func lrcFromSegments(_ segments: [[String: Any]], chunkOffsetMs: Int) -> String? {
        let lines = segments.compactMap { segment -> String? in
            let text = (segment["text"] as? String)
                ?? (segment["transcript"] as? String)
                ?? (segment["content"] as? String)
            guard let text else { return nil }
            let start = doubleValue(segment["start"])
                ?? doubleValue(segment["start_time"])
                ?? doubleValue(segment["startTime"])
                ?? doubleValue(segment["timestamp"])
            guard let start else { return nil }
            let cleaned = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return "[\(formatLRCTime(chunkOffsetMs + Int(start * 1000)))]\(cleaned)"
        }
        guard lines.count >= 2 else { return nil }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func lrcFromWords(_ words: [[String: Any]], chunkOffsetMs: Int) -> String? {
        var lines: [String] = []
        var currentWords: [String] = []
        var currentStart: Double?
        var lastEnd: Double?

        func flush() {
            guard let start = currentStart, !currentWords.isEmpty else { return }
            let text = currentWords.joined(separator: " ")
            lines.append("[\(formatLRCTime(chunkOffsetMs + Int(start * 1000)))]\(text)")
            currentWords = []
            currentStart = nil
            lastEnd = nil
        }

        for word in words {
            let text = (word["word"] as? String)
                ?? (word["text"] as? String)
                ?? (word["content"] as? String)
            guard let text else { continue }
            let start = doubleValue(word["start"]) ?? doubleValue(word["start_time"]) ?? doubleValue(word["startTime"])
            let end = doubleValue(word["end"]) ?? doubleValue(word["end_time"]) ?? doubleValue(word["endTime"])
            guard let start else { continue }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            if currentStart == nil {
                currentStart = start
            }
            if currentWords.count >= 12 || (lastEnd.map { start - $0 > 1.2 } ?? false) {
                flush()
                currentStart = start
            }
            currentWords.append(cleaned)
            lastEnd = end ?? start
        }
        flush()
        guard lines.count >= 2 else { return nil }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    nonisolated private static func estimatedLRC(
        from text: String,
        track: PlaybackTrack,
        chunkOffsetMs: Int,
        chunkDurationMs: Int?
    ) -> String? {
        guard let estimated = TranscriptParser.lrcFromPlainText(
            text,
            durationMs: chunkDurationMs ?? track.durationMs
        ) else { return nil }
        return shiftLRC(estimated, by: chunkOffsetMs)
    }

    nonisolated private static func mergeLRCPieces(_ pieces: [String]) -> String {
        pieces
            .flatMap(LRCParser.parse)
            .sorted { lhs, rhs in
                if lhs.timeMs == rhs.timeMs { return lhs.text < rhs.text }
                return lhs.timeMs < rhs.timeMs
            }
            .map { "[\(formatLRCTime($0.timeMs))]\($0.text)" }
            .joined(separator: "\n")
    }

    nonisolated private static func shiftLRC(_ lrc: String, by offsetMs: Int) -> String {
        LRCParser.parse(lrc)
            .map { "[\(formatLRCTime($0.timeMs + offsetMs))]\($0.text)" }
            .joined(separator: "\n")
    }

    nonisolated private static func formatLRCTime(_ ms: Int) -> String {
        let clamped = max(0, ms)
        let minutes = clamped / 60_000
        let seconds = (clamped % 60_000) / 1_000
        let hundredths = (clamped % 1_000) / 10
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }

    static func humanReadable(_ error: Error) -> String {
        switch error {
        case AITranscriptionError.missingAPIKey:
            return "Add an API Key in AI Settings first."
        case AITranscriptionError.unsupportedProvider:
            return "AI transcription needs an OpenAI-compatible audio provider."
        case AITranscriptionError.requestFailed(let status):
            if status == 404 || status == 400 {
                return "The current AI provider rejected audio transcription (HTTP \(status)). Use an OpenAI-compatible audio endpoint."
            }
            return "Transcription request failed with HTTP \(status)."
        case AITranscriptionError.invalidResponse:
            return "The transcription provider did not return usable timed text."
        case AITranscriptionError.audioPreparationFailed:
            return "Could not prepare this podcast audio for transcription."
        case AITranscriptionError.audioFileTooLarge(let bytes):
            return "Audio chunk is still too large to upload (\(bytes / 1_000_000) MB)."
        default:
            return "Transcription failed. Check the file, API URL, and network."
        }
    }

    private struct TranscriptionPlan {
        let model: String
        let responseFormat: String
        let timestampGranularity: String?
        let chunkingStrategy: String?
        let supportsPrompt: Bool
    }

    private struct DownloadedAudio {
        let fileURL: URL
        let filename: String
    }

    private struct AudioChunk {
        let fileURL: URL
        let filename: String
        let offsetMs: Int
        let durationMs: Int?
        let shouldDelete: Bool
    }
}
