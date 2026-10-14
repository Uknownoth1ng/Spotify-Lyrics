import Foundation

actor LyricsCacheService {
    private let fileURL: URL
    private let explainFileURL: URL
    private var store: [String: CachedLyrics] = [:]
    private var explainStore: [String: LyricLearningNote] = [:]
    private var loaded = false
    private var explainLoaded = false

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SpotLyricsBar", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("lyrics-cache.json")
        self.explainFileURL = base.appendingPathComponent("explain-cache.json")
    }

    func cachedLyrics(for track: PlaybackTrack) async -> CachedLyrics? {
        await loadIfNeeded()
        return store[track.stableKey]
    }

    func save(candidate: LyricsCandidate, for track: PlaybackTrack) async {
        await loadIfNeeded()
        let existingOffset = store[track.stableKey]?.offsetMs ?? 0
        store[track.stableKey] = CachedLyrics(
            trackKey: track.stableKey,
            candidate: candidate,
            offsetMs: existingOffset,
            fetchedAt: Date()
        )
        await persist()
    }

    func offset(for track: PlaybackTrack) async -> Int {
        await loadIfNeeded()
        return store[track.stableKey]?.offsetMs ?? 0
    }

    func setOffset(_ offsetMs: Int, for track: PlaybackTrack) async {
        await loadIfNeeded()
        if var cached = store[track.stableKey] {
            cached.offsetMs = offsetMs
            store[track.stableKey] = cached
        } else {
            let empty = LyricsCandidate(
                trackName: track.title,
                artistName: track.artist,
                albumName: track.album,
                durationMs: track.durationMs,
                syncedLyrics: nil,
                plainLyrics: nil,
                source: "manual-offset",
                confidence: 0
            )
            store[track.stableKey] = CachedLyrics(
                trackKey: track.stableKey,
                candidate: empty,
                offsetMs: offsetMs,
                fetchedAt: Date()
            )
        }
        await persist()
    }

    func clear() async {
        store = [:]
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    func cachedExplain(trackKey: String, line: String) async -> LyricLearningNote? {
        await loadExplainIfNeeded()
        return explainStore[explainKey(trackKey: trackKey, line: line)]
    }

    func saveExplain(_ note: LyricLearningNote, trackKey: String, line: String) async {
        await loadExplainIfNeeded()
        explainStore[explainKey(trackKey: trackKey, line: line)] = note
        await persistExplain()
    }

    private func explainKey(trackKey: String, line: String) -> String {
        "\(trackKey)|\(TextNormalizer.stableTextHash(line))"
    }

    private func loadExplainIfNeeded() async {
        guard !explainLoaded else { return }
        explainLoaded = true
        guard let data = try? Data(contentsOf: explainFileURL) else { return }
        if let decoded = try? JSONDecoder.spotLyrics.decode([String: LyricLearningNote].self, from: data) {
            explainStore = decoded
        }
    }

    private func persistExplain() async {
        guard let data = try? JSONEncoder.spotLyrics.encode(explainStore) else { return }
        try? data.write(to: explainFileURL, options: [.atomic])
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder.spotLyrics.decode([String: CachedLyrics].self, from: data) {
            store = decoded
        }
    }

    private func persist() async {
        guard let data = try? JSONEncoder.spotLyrics.encode(store) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

extension JSONEncoder {
    static var spotLyrics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var spotLyrics: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
