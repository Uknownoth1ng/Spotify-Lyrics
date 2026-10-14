import Foundation

final class LRCLibService: LyricsSearching, @unchecked Sendable {
    private struct LRCLibResponse: Decodable {
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // LRCLib cold-start can take 8-9s; cutting it short means the song with synced
        // lyrics never lands. Keep this generous; the AppState pipeline still has its
        // own outer cap.
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func bestLyrics(for track: PlaybackTrack) async throws -> LyricsCandidate {
        let candidates = try await search(track: track)
        guard !candidates.isEmpty else { throw LyricsSearchError.notFound }
        let scored = candidates
            .map { candidate -> LyricsCandidate in
                LyricsCandidate(
                    trackName: candidate.trackName,
                    artistName: candidate.artistName,
                    albumName: candidate.albumName,
                    durationMs: candidate.durationMs,
                    syncedLyrics: candidate.syncedLyrics,
                    plainLyrics: candidate.plainLyrics,
                    source: candidate.source,
                    confidence: score(candidate: candidate, track: track)
                )
            }
            .sorted { $0.confidence > $1.confidence }

        guard let best = scored.first else { throw LyricsSearchError.notFound }

        let isCJK = TextNormalizer.containsCJK(track.title) || TextNormalizer.containsCJK(track.artist)
        let syncedThreshold = isCJK ? 0.78 : 0.82
        let plainThreshold = isCJK ? 0.80 : 0.86
        let lowThreshold = isCJK ? 0.62 : 0.70

        if best.confidence >= syncedThreshold, best.syncedLyrics?.isEmpty == false {
            return best
        }
        if best.confidence >= plainThreshold, best.plainLyrics?.isEmpty == false {
            throw LyricsSearchError.plainOnly(best)
        }
        if best.confidence >= lowThreshold {
            throw LyricsSearchError.lowConfidence(best.confidence)
        }
        throw LyricsSearchError.notFound
    }

    private func search(track: PlaybackTrack) async throws -> [LyricsCandidate] {
        if let exact = try await fetchExactCandidate(track: track) {
            return [exact]
        }
        let title = TextNormalizer.conservativeSearchTitle(track.title)
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album ?? "")
        ]
        var candidates = try await fetchCandidates(components: components)

        // CJK Traditional/Simplified retries — LRCLIB indexes both forms inconsistently.
        if candidates.isEmpty, TextNormalizer.containsCJK(title) {
            for variantTitle in cjkTitleVariants(title) where !variantTitle.isEmpty {
                for variantArtist in cjkArtistVariants(track.artist) {
                    var attempt = URLComponents(string: "https://lrclib.net/api/search")!
                    attempt.queryItems = [
                        URLQueryItem(name: "track_name", value: variantTitle),
                        URLQueryItem(name: "artist_name", value: variantArtist)
                    ]
                    let result = try await fetchCandidates(components: attempt)
                    if !result.isEmpty {
                        candidates.append(contentsOf: result)
                        break
                    }
                }
                if !candidates.isEmpty { break }
            }
        }

        if candidates.isEmpty {
            var fallback = URLComponents(string: "https://lrclib.net/api/search")!
            fallback.queryItems = [
                URLQueryItem(name: "q", value: "\(title) \(track.artist)")
            ]
            candidates = try await fetchCandidates(components: fallback)
        }

        if candidates.isEmpty, TextNormalizer.containsCJK(title) {
            for variantTitle in cjkTitleVariants(title) where !variantTitle.isEmpty {
                var attempt = URLComponents(string: "https://lrclib.net/api/search")!
                attempt.queryItems = [URLQueryItem(name: "q", value: variantTitle)]
                let result = try await fetchCandidates(components: attempt)
                if !result.isEmpty {
                    candidates.append(contentsOf: result)
                    break
                }
            }
        }

        return unique(candidates)
    }

    private func cjkTitleVariants(_ title: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let baseForms = [title, TextNormalizer.toSimplified(title), TextNormalizer.toTraditional(title)]
        for base in baseForms {
            let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
            let stripped = TextNormalizer.stripBrackets(base)
            if !stripped.isEmpty, seen.insert(stripped).inserted {
                out.append(stripped)
            }
        }
        return out
    }

    private func cjkArtistVariants(_ artist: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let pieces = TextNormalizer.splitArtists(artist)
        let candidates: [String] = pieces.isEmpty ? [artist] : ([artist] + pieces)
        for candidate in candidates {
            for variant in [candidate, TextNormalizer.toSimplified(candidate), TextNormalizer.toTraditional(candidate)] {
                let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                    out.append(trimmed)
                }
            }
        }
        return out
    }

    private func fetchExactCandidate(track: PlaybackTrack) async throws -> LyricsCandidate? {
        let title = TextNormalizer.conservativeSearchTitle(track.title)
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album ?? ""),
            URLQueryItem(name: "duration", value: track.durationMs.map { String(Int(round(Double($0) / 1000))) } ?? "")
        ]
        guard let url = components.url else { throw LyricsSearchError.network }
        var request = URLRequest(url: url)
        request.setValue("SpotLyricsBar/0.1 (local macOS menu bar lyrics tool)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return nil }
            guard status == 200 else { throw LyricsSearchError.network }
            let decoded = try JSONDecoder().decode(LRCLibResponse.self, from: data)
            return LyricsCandidate(
                trackName: decoded.trackName ?? track.title,
                artistName: decoded.artistName ?? track.artist,
                albumName: decoded.albumName,
                durationMs: decoded.duration.map { Int($0 * 1000) },
                syncedLyrics: decoded.syncedLyrics,
                plainLyrics: decoded.plainLyrics,
                source: "LRCLIB Exact",
                confidence: 0
            )
        } catch is CancellationError {
            throw LyricsSearchError.timedOut
        } catch let error as LyricsSearchError {
            throw error
        } catch {
            return nil
        }
    }

    private func fetchCandidates(components: URLComponents) async throws -> [LyricsCandidate] {
        guard let url = components.url else { throw LyricsSearchError.network }
        var request = URLRequest(url: url)
        request.setValue("SpotLyricsBar/0.1 (local macOS menu bar lyrics tool)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw LyricsSearchError.network
            }
            let decoded = try JSONDecoder().decode([LRCLibResponse].self, from: data)
            return decoded.map {
                LyricsCandidate(
                    trackName: $0.trackName ?? "",
                    artistName: $0.artistName ?? "",
                    albumName: $0.albumName,
                    durationMs: $0.duration.map { Int($0 * 1000) },
                    syncedLyrics: $0.syncedLyrics,
                    plainLyrics: $0.plainLyrics,
                    source: "LRCLIB",
                    confidence: 0
                )
            }
        } catch is CancellationError {
            throw LyricsSearchError.timedOut
        } catch {
            throw LyricsSearchError.network
        }
    }

    private func unique(_ candidates: [LyricsCandidate]) -> [LyricsCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = "\(TextNormalizer.cacheKey(candidate.trackName))|\(TextNormalizer.cacheKey(candidate.artistName))|\(candidate.durationMs ?? 0)"
            return seen.insert(key).inserted
        }
    }

    private func score(candidate: LyricsCandidate, track: PlaybackTrack) -> Double {
        let titleScore = TextNormalizer.similarity(candidate.trackName, track.title)
        let artistScore = bestArtistScore(candidate.artistName, track.artist)
        let albumScore = albumSimilarity(candidate.albumName, track.album)
        let durationScore = durationSimilarity(candidate.durationMs, track.durationMs)
        let weighted = titleScore * 0.45 + artistScore * 0.30 + albumScore * 0.10 + durationScore * 0.15

        // Same cross-language rescue as NetEase: identical title + matching duration
        // is enough confidence even when the romanized vs CJK artist names diverge.
        if titleScore >= 0.97, durationScore >= 0.99 {
            if albumScore >= 0.85 { return max(weighted, 0.92) }
            return max(weighted, 0.86)
        }
        if titleScore >= 0.95, durationScore >= 0.85, albumScore >= 0.80 {
            return max(weighted, 0.84)
        }
        return weighted
    }

    private func bestArtistScore(_ candidateArtist: String, _ trackArtist: String) -> Double {
        let candidates = TextNormalizer.splitArtists(candidateArtist).isEmpty
            ? [candidateArtist]
            : TextNormalizer.splitArtists(candidateArtist)
        let targets = TextNormalizer.splitArtists(trackArtist).isEmpty
            ? [trackArtist]
            : TextNormalizer.splitArtists(trackArtist)
        var best = TextNormalizer.similarity(candidateArtist, trackArtist)
        for candidate in candidates {
            for target in targets {
                best = max(best, TextNormalizer.similarity(candidate, target))
            }
        }
        return best
    }

    private func albumSimilarity(_ lhs: String?, _ rhs: String?) -> Double {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return 0.6 }
        return TextNormalizer.similarity(lhs, rhs)
    }

    private func durationSimilarity(_ lhs: Int?, _ rhs: Int?) -> Double {
        guard let lhs, let rhs, lhs > 0, rhs > 0 else { return 0.5 }
        let diff = abs(lhs - rhs)
        if diff <= 2_000 { return 1 }
        if diff <= 8_000 { return 0.90 }
        if diff <= 20_000 { return 0.75 }
        if diff <= 35_000 { return 0.55 }
        return 0.2
    }
}
