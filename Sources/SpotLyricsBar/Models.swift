import Foundation

enum PlaybackSource: String, Codable, Hashable {
    case spotify
    case unknown
}

enum PlaybackContentKind: String, Codable, Hashable {
    case music
    case episode
    case localFile
    case unknown

    var supportsLyrics: Bool {
        switch self {
        case .music, .episode, .unknown:
            return true
        case .localFile:
            return false
        }
    }

    var usesSongLyricsProviders: Bool {
        self == .music || self == .unknown
    }

    var label: String {
        switch self {
        case .music: "Song"
        case .episode: "Podcast Episode"
        case .localFile: "Local File"
        case .unknown: "Spotify"
        }
    }
}

struct PlaybackTrack: Codable, Equatable, Hashable {
    let title: String
    let artist: String
    let album: String?
    let durationMs: Int?
    let source: PlaybackSource
    let spotifyURI: String?
    let contentKind: PlaybackContentKind
    let artworkURL: String?

    init(
        title: String,
        artist: String,
        album: String?,
        durationMs: Int?,
        source: PlaybackSource,
        spotifyURI: String? = nil,
        contentKind: PlaybackContentKind = .music,
        artworkURL: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.source = source
        self.spotifyURI = spotifyURI
        self.contentKind = contentKind
        self.artworkURL = artworkURL
    }

    var stableKey: String {
        if contentKind == .episode, let spotifyURI, !spotifyURI.isEmpty {
            return "episode|\(spotifyURI)"
        }
        let bucket = (durationMs ?? 0) / 5_000
        return "\(TextNormalizer.cacheKey(title))|\(TextNormalizer.cacheKey(artist))|\(bucket)"
    }

    var displaySubtitle: String {
        switch contentKind {
        case .episode:
            return podcastShowName
        default:
            return artist
        }
    }

    var podcastShowName: String {
        let candidates = [artist, album ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return candidates.first ?? "Podcast"
    }

    var spotifyEpisodeID: String? {
        guard let uri = spotifyURI else { return nil }
        if uri.hasPrefix("spotify:episode:") {
            return String(uri.dropFirst("spotify:episode:".count))
        }
        if uri.contains("/episode/") {
            return uri.components(separatedBy: "/episode/").last?.components(separatedBy: "?").first
        }
        return nil
    }
}

enum PlaybackError: String, Codable, Error, Equatable {
    case spotifyNotRunning
    case unsupportedContent
    case scriptFailed
    case emptyTrack
}

struct PlaybackState: Equatable {
    let track: PlaybackTrack?
    let positionMs: Int
    let isPlaying: Bool
    let updatedAt: Date
    let error: PlaybackError?

    static let idle = PlaybackState(
        track: nil,
        positionMs: 0,
        isPlaying: false,
        updatedAt: Date(),
        error: .spotifyNotRunning
    )
}

struct LyricsCandidate: Codable, Equatable {
    let trackName: String
    let artistName: String
    let albumName: String?
    let durationMs: Int?
    let syncedLyrics: String?
    let plainLyrics: String?
    let source: String
    let confidence: Double
}

struct LyricLine: Identifiable, Codable, Equatable {
    let id: String
    let timeMs: Int
    let text: String

    init(id: String? = nil, timeMs: Int, text: String) {
        self.id = id
            ?? "\(timeMs)-\(TextNormalizer.stableTextHash(text))"
        self.timeMs = timeMs
        self.text = text
    }
}

struct SyncedLyricsSnapshot: Equatable {
    let previous: [LyricLine]
    let current: LyricLine?
    let next: [LyricLine]
    let effectivePositionMs: Int
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case menuBar
    case floatingPanel
    case notchCard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .menuBar: "Menu Bar"
        case .floatingPanel: "Floating Panel"
        case .notchCard: "Notch Card (Experimental)"
        }
    }
}

enum PanelRoute: Hashable {
    case lyrics
    case settings
    case aiSettings
}

enum WireAPI: String, Codable, CaseIterable, Identifiable {
    case responses
    case chatCompletions
    case anthropicMessages

    var id: String { rawValue }

    var label: String {
        switch self {
        case .responses: "OpenAI Responses"
        case .chatCompletions: "OpenAI Chat Completions"
        case .anthropicMessages: "Anthropic Messages"
        }
    }
}

struct LLMProviderConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var baseURL: URL
    var model: String
    var wireAPI: WireAPI
    var reasoningEffort: String?
    var disableResponseStorage: Bool
}

struct LyricLearningNote: Codable, Equatable {
    let line: String
    let meaningInContext: String
    let naturalChinese: String
    let slangOrIdiom: [String]
    let cultureNote: String?
    let examples: [String]
    let caution: String?
}

struct CachedLyrics: Codable, Equatable {
    let trackKey: String
    let candidate: LyricsCandidate
    var offsetMs: Int
    let fetchedAt: Date
}

enum LyricsStatus: Equatable {
    case idle
    case loading
    case ready(LyricsCandidate)
    case notFound(String)
    case plainOnly(LyricsCandidate)
    case lowConfidence(Double)
    case offlineUsingCache
}

enum LyricsSearchError: Error, Equatable {
    case notFound
    case lowConfidence(Double)
    case plainOnly(LyricsCandidate)
    case network
    case timedOut
}

protocol LyricsSearching: Sendable {
    func bestLyrics(for track: PlaybackTrack) async throws -> LyricsCandidate
}

enum LyricsLoadingState: Equatable {
    case idle
    case waitingForStableTrack
    case checkingCache
    case searchingPrimarySource
    case searchingFallbackSources
    case aiRewritingIdentity
    case aiSearchingWithHints
    case aiGeneratingLyrics
    case aiAssistedSearch
    case foundSyncedLyrics
    case foundUnsyncedLyrics
    case needsUserAction
    case failedRecoverable
    case failedFinal
    case instrumental
    case podcastEpisode
    case unsupportedContent
}

enum PlaybackPresentation {
    static func progressFraction(positionMs: Int, durationMs: Int?) -> Double {
        guard let durationMs, durationMs > 0 else { return 0 }
        return min(1, max(0, Double(positionMs) / Double(durationMs)))
    }

    static func progressText(positionMs: Int, durationMs: Int?) -> String {
        "\(formatTime(positionMs))/\(durationMs.map(formatTime) ?? "--:--")"
    }

    static func progressTitle(prefix: String, track: PlaybackTrack, positionMs: Int, maxTitleCharacters: Int) -> String {
        let title = TextNormalizer.boundedMenuText(track.title, maxCharacters: maxTitleCharacters)
        return "\(prefix) \(title) \(progressText(positionMs: positionMs, durationMs: track.durationMs))"
    }

    static func formatTime(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
