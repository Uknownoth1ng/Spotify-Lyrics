import Foundation

protocol PlaybackServicing: Sendable {
    func fetchState() async -> PlaybackState
}

final class SpotifyPlaybackService: PlaybackServicing, @unchecked Sendable {
    func fetchState() async -> PlaybackState {
        await Task.detached(priority: .utility) {
            self.fetchStateBlocking()
        }.value
    }

    private func fetchStateBlocking() -> PlaybackState {
        let startedAt = Date()
        let script = """
        tell application "System Events"
            set spotifyRunning to (name of processes) contains "Spotify"
        end tell
        if spotifyRunning is false then
            return "NOT_RUNNING"
        end if
        tell application "Spotify"
            try
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                set trackDuration to duration of current track
                set playerPosition to player position
                set playerStateText to player state as string
                set spotifyURLText to spotify url of current track
                set artworkURLText to ""
                try
                    set artworkURLText to artwork url of current track
                end try
                return trackName & "||SPOTLYRICS||" & artistName & "||SPOTLYRICS||" & albumName & "||SPOTLYRICS||" & trackDuration & "||SPOTLYRICS||" & playerPosition & "||SPOTLYRICS||" & playerStateText & "||SPOTLYRICS||" & spotifyURLText & "||SPOTLYRICS||" & artworkURLText
            on error
                return "SCRIPT_ERROR"
            end try
        end tell
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return failure(.scriptFailed)
        }
        let output = appleScript.executeAndReturnError(&error).stringValue ?? ""
        if output == "NOT_RUNNING" {
            return failure(.spotifyNotRunning)
        }
        if output == "SCRIPT_ERROR" || error != nil {
            return failure(.scriptFailed)
        }

        return SpotifyPlaybackParser.state(from: output, startedAt: startedAt, receivedAt: Date())
    }

    private func failure(_ error: PlaybackError) -> PlaybackState {
        PlaybackState(track: nil, positionMs: 0, isPlaying: false, updatedAt: Date(), error: error)
    }

}
