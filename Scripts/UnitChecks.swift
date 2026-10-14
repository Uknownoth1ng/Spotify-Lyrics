import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct UnitChecks {
    static func main() {
        let lrc = """
        [00:01.00][00:02.50]Hello
        [00:03.123]World
        """
        let lines = LRCParser.parse(lrc)
        require(lines.count == 3, "LRC parser should parse multi timestamp lines")
        require(lines[0].timeMs == 1_000, "first timestamp should be 1000ms")
        require(lines[1].timeMs == 2_500, "second timestamp should be 2500ms")
        require(lines[2].text == "World", "text should be trimmed")

        let engine = LyricsSyncEngine()
        engine.globalLatencyCompensationMs = 150
        engine.perTrackOffsetMs = 100
        engine.load(lrcText: """
        [00:01.00]one
        [00:02.00]two
        [00:03.00]three
        """)
        let snapshot = engine.snapshot(positionMs: 1_800, contextCount: 1)
        require(snapshot.effectivePositionMs == 2_050, "effective position should include latency and per-track offset")
        require(snapshot.current?.text == "two", "sync engine should choose the current line")
        require(snapshot.previous.map(\.text) == ["one"], "sync engine should provide previous context")
        require(snapshot.next.map(\.text) == ["three"], "sync engine should provide next context")

        let scaled = LyricsSyncEngine()
        scaled.globalLatencyCompensationMs = 0
        scaled.load(lrcText: "[00:10.00]scaled", sourceDurationMs: 100_000, playbackDurationMs: 110_000)
        require(scaled.snapshot(positionMs: 10_900).current == nil || scaled.snapshot(positionMs: 10_900).current?.text != "scaled", "scaled lyrics should not arrive too early")
        require(scaled.snapshot(positionMs: 11_000).current?.text == "scaled", "scaled lyrics should align to playback duration")

        let normalized = TextNormalizer.normalize("Lavender Haze (Explicit) - Remastered")
        require(normalized == "lavender haze", "normalizer should remove common noisy suffixes")
        require(TextNormalizer.similarity("Lavender Haze", "lavender haze") == 1, "similar titles should score 1")
        require(TextNormalizer.conservativeSearchTitle("富士山下 (Live)") == "富士山下 (Live)", "CJK conservative search title should not strip meaningful bracket text")

        // CJK Traditional/Simplified should collapse for matching purposes (陳潔儀 ↔ 陈洁仪).
        require(TextNormalizer.similarity("陳潔儀", "陈洁仪") >= 0.99, "Traditional/Simplified Chinese forms should compare equal")
        require(TextNormalizer.similarity("遺憾", "遗憾") >= 0.99, "遺憾 / 遗憾 should compare equal")
        require(TextNormalizer.toSimplified("陳潔儀") == "陈洁仪", "toSimplified should produce simplified form")
        require(TextNormalizer.toTraditional("陈洁仪") == "陳潔儀", "toTraditional should produce traditional form")

        // Fullwidth-Halfwidth normalization: Spotify Mac shows fullwidth punctuation sometimes.
        require(TextNormalizer.halfWidth("Ｈｅｌｌｏ").lowercased() == "hello", "fullwidth ASCII letters should fold to halfwidth")
        require(TextNormalizer.normalize("Ｈｅｌｌｏ ｗｏｒｌｄ").contains("hello"), "normalize should halfwidth-fold fullwidth letters")

        // stripBrackets removes bracket text but conservativeSearchTitle keeps it.
        require(TextNormalizer.stripBrackets("富士山下 (Live)") == "富士山下", "stripBrackets should remove parentheses")
        require(TextNormalizer.stripBrackets("歌名【电视剧】") == "歌名", "stripBrackets should remove CJK brackets")

        // splitArtists handles CJK separators.
        let split = TextNormalizer.splitArtists("陈洁仪、张学友 / Eason")
        require(split.count == 3, "splitArtists should split on CJK + ASCII delimiters; got \(split)")
        require(LyricLine(timeMs: 1_000, text: "same").id == LyricLine(timeMs: 1_000, text: "same").id, "lyric line IDs should be stable")
        require(LyricLine(timeMs: 1_000, text: "same").id != LyricLine(timeMs: 2_000, text: "same").id, "lyric line IDs should include time")

        let podcast = PlaybackTrack(
            title: "Episode",
            artist: "Host",
            album: nil,
            durationMs: 60_000,
            source: .spotify,
            spotifyURI: "spotify:episode:abc",
            contentKind: .episode
        )
        require(podcast.contentKind.supportsLyrics, "podcasts should support transcript-backed lyrics display")
        require(!podcast.contentKind.usesSongLyricsProviders, "podcasts should not use song lyric providers")
        require(podcast.stableKey == "episode|spotify:episode:abc", "podcast stable key should prefer Spotify episode URI")
        require(PlaybackPresentation.progressText(positionMs: 61_000, durationMs: 600_000) == "1:01/10:00", "podcast progress text should be readable")

        let track = PlaybackTrack(
            title: "Song",
            artist: "Artist",
            album: nil,
            durationMs: 60_000,
            source: .spotify,
            spotifyURI: "spotify:track:abc",
            contentKind: .music
        )
        require(track.contentKind.supportsLyrics, "music tracks should support synced lyrics")
        require(track.contentKind.usesSongLyricsProviders, "music should use song lyric providers")

        let started = Date(timeIntervalSince1970: 10)
        let received = Date(timeIntervalSince1970: 10.2)
        let episodeOutput = [
            "Learning English Episode 1",
            "",
            "English Show",
            "1800000",
            "15.0",
            "playing",
            "spotify:episode:xyz",
            "https://example.com/art.jpg"
        ].joined(separator: SpotifyPlaybackParser.separator)
        let parsedEpisode = SpotifyPlaybackParser.state(from: episodeOutput, startedAt: started, receivedAt: received)
        require(parsedEpisode.track?.contentKind == .episode, "Spotify episode URI should parse as podcast episode")
        require(parsedEpisode.track?.artist == "English Show", "episode with empty artist should fall back to show/album name")
        require(parsedEpisode.positionMs >= 15_000, "episode parser should preserve playback position")

        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        Welcome to the English lesson.

        00:00:03.500 --> 00:00:06.000
        Today we talk about natural phrases.
        """
        let vttLRC = TranscriptParser.lrcFromVTT(vtt) ?? ""
        require(LRCParser.parse(vttLRC).count == 2, "VTT podcast transcript should convert to LRC lines")
        require(LRCParser.parse(vttLRC).first?.text == "Welcome to the English lesson.", "VTT transcript text should be preserved")

        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        First transcript line.

        2
        00:00:04,000 --> 00:00:06,000
        Second transcript line.
        """
        require(LRCParser.parse(TranscriptParser.lrcFromSRT(srt) ?? "").count == 2, "SRT podcast transcript should convert to LRC lines")
        let htmlTranscript = """
        <html><body><h2>Transcript</h2><p>This is a long enough podcast transcript paragraph for English learners.</p><p>It should be converted into readable synced text.</p><p>Another sentence keeps the transcript over the minimum line count.</p><p>The app can estimate timing when timestamps are unavailable.</p></body></html>
        """
        require(PodcastTranscriptService.candidate(from: htmlTranscript, track: podcast)?.syncedLyrics?.contains("[") == true, "HTML podcast transcript pages should become synced text")
        let noisyHTMLTranscript = """
        <html>
        <head>
          <style>.anti-flicker-hide { opacity: 0 !important } body { display: none !important; }</style>
          <script>function initApollo(){ window.__NEXT_DATA__ = {"props": true}; }</script>
        </head>
        <body>
          <nav>Subscribe About Privacy Policy</nav>
          <main>
            <h1>Episode Transcript</h1>
            <p>Welcome back to this English learning podcast episode with clear pronunciation practice.</p>
            <p>Today we are going to talk about useful phrases for everyday conversations.</p>
            <p>Listen carefully to the examples and repeat them after the speaker.</p>
            <p>This transcript should be clean readable text without website code or styling.</p>
          </main>
        </body>
        </html>
        """
        let noisyCandidate = PodcastTranscriptService.candidate(from: noisyHTMLTranscript, track: podcast)
        let noisyText = noisyCandidate?.plainLyrics?.lowercased() ?? ""
        require(noisyCandidate?.syncedLyrics?.contains("[") == true, "noisy HTML transcript should still produce synced text")
        require(!noisyText.contains("anti-flicker") && !noisyText.contains("display:") && !noisyText.contains("function initapollo"), "HTML cleaner must exclude CSS and JS garbage")
        let garbageHTML = """
        <html><head><style>.anti-flicker-hide{display:none!important}</style><script>function initApollo(){return window.__NEXT_DATA__}</script></head><body><div id="__NEXT_DATA__">{ "props": { "pageProps": true } }</div></body></html>
        """
        require(PodcastTranscriptService.candidate(from: garbageHTML, track: podcast) == nil, "CSS/JS-only pages must not be accepted as transcript text")
        let ddgHTML = """
        <a class="result__a" href="/l/?uddg=https%3A%2F%2Fpodscan.fm%2Fpodcasts%2Fexample%2Fepisodes%2Fepisode-transcript&amp;rut=123">Transcript</a>
        """
        require(PodcastTranscriptService.testTranscriptLinks(in: ddgHTML, baseURL: URL(string: "https://duckduckgo.com/html/")!).contains { $0.absoluteString.contains("podscan.fm") }, "DuckDuckGo relative redirect transcript links should be decoded")

        let aiJSON = """
        {"segments":[{"start":0.5,"text":"First spoken sentence."},{"start":3.0,"text":"Second spoken sentence."}]}
        """.data(using: .utf8)!
        let shiftedLRC = try! AITranscriptionService.extractLRC(data: aiJSON, track: podcast, chunkOffsetMs: 600_000, chunkDurationMs: 60_000)
        require(shiftedLRC.contains("[10:00.50]First spoken sentence."), "AI transcript chunks should be shifted by chunk offset")
        require(shiftedLRC.contains("[10:03.00]Second spoken sentence."), "AI transcript chunk timestamps should stay ordered")
        let diarizedJSON = """
        {"diarized_segments":[{"start":1.25,"end":2.5,"speaker":"A","text":"Diarized high accuracy line."},{"start":4.0,"end":6.5,"speaker":"B","text":"Another clean segment."}]}
        """.data(using: .utf8)!
        let diarizedLRC = try! AITranscriptionService.extractLRC(data: diarizedJSON, track: podcast, chunkOffsetMs: 120_000, chunkDurationMs: 60_000)
        require(diarizedLRC.contains("[02:01.25]Diarized high accuracy line."), "diarized GPT transcription should produce timed LRC")
        let plainJSON = """
        {"text":"This is a clean high accuracy podcast transcript sentence for learners. It has enough content to estimate a useful timeline. The lyric bar can display this text while the episode plays. Another line keeps the transcript long enough for conversion."}
        """.data(using: .utf8)!
        let plainLRC = try! AITranscriptionService.extractLRC(data: plainJSON, track: podcast, chunkOffsetMs: 240_000, chunkDurationMs: 120_000)
        require(plainLRC.contains("[04:"), "plain GPT transcription chunks should still estimate shifted LRC timing")

        let topAnchor = CGRect(x: 500, y: 860, width: 360, height: 36)
        let panelSize = CGSize(width: 380, height: 300)
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let origin = FloatingPanelPlacement.origin(
            anchorFrame: topAnchor,
            panelSize: panelSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            preferredEdge: .below
        )
        require(origin.y + panelSize.height == topAnchor.minY, "panel opened from lyric capsule should touch the capsule without a gap")
        require(origin.x >= visibleFrame.minX + 10 && origin.x + panelSize.width <= visibleFrame.maxX - 10, "panel should be horizontally clamped to visible screen")

        print("Unit checks passed.")
    }
}
