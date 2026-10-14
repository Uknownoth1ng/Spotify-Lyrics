import Foundation

enum SpotifyPlaybackParser {
    static let separator = "||SPOTLYRICS||"

    static func state(from output: String, startedAt: Date, receivedAt: Date = Date()) -> PlaybackState {
        let fields = output.components(separatedBy: separator)
        guard fields.count >= 7 else {
            return failure(.unsupportedContent, at: receivedAt)
        }

        let title = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var artist = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let durationMs = Int(fields[3].trimmingCharacters(in: .whitespacesAndNewlines))
        let positionSeconds = Double(fields[4].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let playerState = fields[5].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let uri = fields[6].trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkURL = fields.count >= 8 ? fields[7].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let kind = contentKind(uri: uri, title: title, artist: artist, album: album, durationMs: durationMs)

        if artist.isEmpty, kind == .episode {
            artist = album.isEmpty ? "Podcast" : album
        }

        guard !title.isEmpty, !artist.isEmpty else {
            return failure(.emptyTrack, at: receivedAt)
        }

        let isPlaying = playerState == "playing"
        let scriptLatencyMs = Int(receivedAt.timeIntervalSince(startedAt) * 1000)
        let compensatedPositionMs = max(0, Int(positionSeconds * 1000) + (isPlaying ? min(250, scriptLatencyMs / 2) : 0))
        let track = PlaybackTrack(
            title: title,
            artist: artist,
            album: album.isEmpty ? nil : album,
            durationMs: durationMs,
            source: .spotify,
            spotifyURI: uri.isEmpty ? nil : uri,
            contentKind: kind,
            artworkURL: artworkURL.isEmpty ? nil : artworkURL
        )

        return PlaybackState(
            track: track,
            positionMs: compensatedPositionMs,
            isPlaying: isPlaying,
            updatedAt: receivedAt,
            error: nil
        )
    }

    static func contentKind(uri: String, title: String = "", artist: String = "", album: String = "", durationMs: Int? = nil) -> PlaybackContentKind {
        let value = uri.lowercased()
        if value.contains("spotify:episode") || value.contains("/episode/") { return .episode }
        if value.contains("spotify:local") { return .localFile }
        if value.contains("spotify:track") || value.contains("/track/") { return .music }

        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedArtist.isEmpty, !trimmedAlbum.isEmpty, (durationMs ?? 0) >= 10 * 60_000 {
            return .episode
        }
        return .unknown
    }

    private static func failure(_ error: PlaybackError, at date: Date) -> PlaybackState {
        PlaybackState(track: nil, positionMs: 0, isPlaying: false, updatedAt: date, error: error)
    }
}
