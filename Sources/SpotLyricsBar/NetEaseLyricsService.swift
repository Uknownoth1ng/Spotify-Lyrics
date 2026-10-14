import Foundation

final class NetEaseLyricsService: LyricsSearching, @unchecked Sendable {
    private struct SearchResponse: Decodable {
        let result: SearchResult?
    }

    private struct SearchResult: Decodable {
        let songs: [Song]?
    }

    private struct Song: Decodable {
        let id: Int
        let name: String
        let duration: Int?
        let artists: [Artist]?
        let album: Album?
    }

    private struct Artist: Decodable {
        let name: String
    }

    private struct Album: Decodable {
        let name: String?
    }

    private struct LyricResponse: Decodable {
        let lrc: LyricPayload?
        let tlyric: LyricPayload?
        let klyric: LyricPayload?
    }

    private struct LyricPayload: Decodable {
        let lyric: String?
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func bestLyrics(for track: PlaybackTrack) async throws -> LyricsCandidate {
        var allSongs: [Song] = []
        var seenIDs = Set<Int>()
        var sawNetworkError = false

        for query in searchQueries(for: track) {
            do {
                for song in try await searchSongs(query: query) where seenIDs.insert(song.id).inserted {
                    allSongs.append(song)
                }
                if !allSongs.isEmpty, songsLookSufficient(allSongs, for: track) { break }
            } catch LyricsSearchError.network, LyricsSearchError.timedOut {
                sawNetworkError = true
            } catch {
                continue
            }
        }

        if allSongs.isEmpty {
            if sawNetworkError { throw LyricsSearchError.network }
            throw LyricsSearchError.notFound
        }

        let scored = allSongs
            .map { song in (song, score(song: song, track: track)) }
            .sorted { $0.1 > $1.1 }

        guard let best = scored.first else { throw LyricsSearchError.notFound }

        let isCJK = TextNormalizer.containsCJK(track.title) || TextNormalizer.containsCJK(track.artist)
        let syncedThreshold = isCJK ? 0.78 : 0.84
        let plainThreshold = isCJK ? 0.74 : 0.80
        let lowThreshold = isCJK ? 0.60 : 0.70

        guard best.1 >= lowThreshold else { throw LyricsSearchError.lowConfidence(best.1) }

        let lyrics = try await fetchLyrics(songID: best.0.id)
        let synced = lyrics.synced
        let plain = lyrics.plain

        let candidate = LyricsCandidate(
            trackName: best.0.name,
            artistName: best.0.artists?.map(\.name).joined(separator: ", ") ?? "",
            albumName: best.0.album?.name,
            durationMs: best.0.duration,
            syncedLyrics: synced.isEmpty ? nil : synced,
            plainLyrics: plain.isEmpty ? nil : plain,
            source: "NetEase",
            confidence: best.1
        )

        if let synced = candidate.syncedLyrics, !synced.isEmpty, best.1 >= syncedThreshold {
            return candidate
        }
        if let plain = candidate.plainLyrics, !plain.isEmpty, best.1 >= plainThreshold {
            throw LyricsSearchError.plainOnly(candidate)
        }
        if best.1 >= lowThreshold {
            throw LyricsSearchError.lowConfidence(best.1)
        }
        throw LyricsSearchError.notFound
    }

    private func searchQueries(for track: PlaybackTrack) -> [String] {
        let title = TextNormalizer.conservativeSearchTitle(track.title)
        let strippedTitle = TextNormalizer.stripBrackets(title)
        let firstArtist = TextNormalizer.splitArtists(track.artist).first ?? track.artist

        var queries: [String] = []
        var seen = Set<String>()
        func add(_ q: String) {
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            queries.append(trimmed)
        }

        let titleVariants = [title, strippedTitle,
                             TextNormalizer.toSimplified(title), TextNormalizer.toTraditional(title),
                             TextNormalizer.toSimplified(strippedTitle), TextNormalizer.toTraditional(strippedTitle)]
        let artistVariants = [track.artist, firstArtist,
                              TextNormalizer.toSimplified(track.artist), TextNormalizer.toTraditional(track.artist),
                              TextNormalizer.toSimplified(firstArtist), TextNormalizer.toTraditional(firstArtist)]

        for t in titleVariants {
            for a in artistVariants {
                add("\(t) \(a)")
            }
            add(t)
        }
        return queries
    }

    private func songsLookSufficient(_ songs: [Song], for track: PlaybackTrack) -> Bool {
        guard !songs.isEmpty else { return false }
        let top = songs.prefix(5).map { score(song: $0, track: track) }.max() ?? 0
        return top >= 0.85
    }

    private func searchSongs(query: String) async throws -> [Song] {
        var components = URLComponents(string: "https://music.163.com/api/search/get/web")!
        components.queryItems = [
            URLQueryItem(name: "csrf_token", value: ""),
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: "true"),
            URLQueryItem(name: "limit", value: "15")
        ]
        guard let url = components.url else { throw LyricsSearchError.network }
        var request = URLRequest(url: url)
        applyHeaders(to: &request)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LyricsSearchError.network }
            return try JSONDecoder().decode(SearchResponse.self, from: data).result?.songs ?? []
        } catch is CancellationError {
            throw LyricsSearchError.timedOut
        } catch let error as LyricsSearchError {
            throw error
        } catch {
            throw LyricsSearchError.network
        }
    }

    private struct LyricBundle {
        let synced: String
        let plain: String
    }

    private func fetchLyrics(songID: Int) async throws -> LyricBundle {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(songID)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1")
        ]
        guard let url = components.url else { throw LyricsSearchError.network }
        var request = URLRequest(url: url)
        applyHeaders(to: &request)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LyricsSearchError.network }
            let decoded = try JSONDecoder().decode(LyricResponse.self, from: data)
            let synced = decoded.lrc?.lyric ?? ""
            let plain = stripTimestamps(synced)
            return LyricBundle(synced: synced, plain: plain)
        } catch is CancellationError {
            throw LyricsSearchError.timedOut
        } catch let error as LyricsSearchError {
            throw error
        } catch {
            throw LyricsSearchError.network
        }
    }

    private func stripTimestamps(_ lrc: String) -> String {
        let pattern = #"\[\d{1,2}:\d{2}(?:\.\d{1,3})?\]"#
        let stripped = lrc.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return stripped
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func score(song: Song, track: PlaybackTrack) -> Double {
        let artist = song.artists?.map(\.name).joined(separator: " ") ?? ""
        let titleScore = TextNormalizer.similarity(song.name, track.title)
        let artistScore = bestArtistScore(artist, track.artist)
        let albumScore = albumSimilarity(song.album?.name, track.album)
        let durationScore = durationSimilarity(song.duration, track.durationMs)
        let weighted = titleScore * 0.45 + artistScore * 0.30 + albumScore * 0.10 + durationScore * 0.15

        // Cross-language artist names (e.g. "Kit Chan" vs "陈洁仪") tank artistScore
        // even when this is unambiguously the same recording. Trust title + duration
        // when both are essentially exact and the album does not contradict.
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

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) SpotLyricsBar/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
    }
}
