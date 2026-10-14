import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var playback: PlaybackState = .idle
    @Published private(set) var lyricsStatus: LyricsStatus = .idle
    @Published private(set) var lyricsLoadingState: LyricsLoadingState = .idle
    @Published private(set) var lyricsRecoveryMessage = "Open Spotify to start lyrics"
    @Published private(set) var snapshot = SyncedLyricsSnapshot(previous: [], current: nil, next: [], effectivePositionMs: 0)
    @Published private(set) var lyricsLines: [LyricLine] = []
    @Published private(set) var menuTitle = "SpotLyrics"
    @Published private(set) var currentCandidate: LyricsCandidate?
    @Published private(set) var currentOffsetMs = 0
    @Published var learningNote: LyricLearningNote?
    @Published var learningError: String?
    @Published var isLearningLoading = false
    @Published var learningLine: String?
    @Published var panelRoute: PanelRoute = .lyrics
    @Published private(set) var isTranscribingPodcast = false
    @Published private(set) var podcastTranscriptionError: String?
    @Published private(set) var isLiveTranscribing = false
    @Published private(set) var livePartialText: String?
    @Published private(set) var currentTranslation: String?

    private func setLyricsLoadingState(_ state: LyricsLoadingState, message: String? = nil) {
        if lyricsLoadingState != state {
            lyricsLoadingState = state
            loadingStateChangedAt = Date()
        }
        if let message {
            lyricsRecoveryMessage = message
        }
    }

    let settings: SettingsStore
    let cache: LyricsCacheService
    let llmSettings: LLMSettingsStore

    private let playbackService: PlaybackServicing
    private let lyricsSearch: LyricsSearching
    private let podcastTranscriptSearch: LyricsSearching
    private let syncEngine = LyricsSyncEngine()
    private let englishLearningService: EnglishLearningService
    private let aiAssistant: AILyricsAssistantService
    private let aiTranscriptionService: AITranscriptionService
    private let spotifyTranscriptService = SpotifyTranscriptService()
    private var liveTranscriptionService: LiveTranscriptionService?

    private var loopTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var stableTrackTask: Task<Void, Never>?
    private var lastTrackKey: String?
    private var lastMenuLineID: String?
    private var lastPositionMs = 0
    private var lastPositionJumpAt: Date?
    private var lyricsInFlightTrackKey: String?
    private var activeLyricsSessionID: UUID?
    private var metadataWaitStartedAt: Date?
    private var loadingStateChangedAt: Date?
    private var nextLyricsRetryAt: [String: Date] = [:]
    private var recoverableFailureCount: [String: Int] = [:]
    private var translationCache: [String: String] = [:]
    private var translationTask: Task<Void, Never>?
    private var lastTranslatedLineID: String?

    init(
        settings: SettingsStore = SettingsStore(),
        cache: LyricsCacheService = LyricsCacheService(),
        llmSettings: LLMSettingsStore = LLMSettingsStore(),
        playbackService: PlaybackServicing = SpotifyPlaybackService(),
        lyricsSearch: LyricsSearching = CompositeLyricsSearchService(),
        podcastTranscriptSearch: LyricsSearching = PodcastTranscriptService()
    ) {
        self.settings = settings
        self.cache = cache
        self.llmSettings = llmSettings
        self.playbackService = playbackService
        self.lyricsSearch = lyricsSearch
        self.podcastTranscriptSearch = podcastTranscriptSearch
        self.englishLearningService = EnglishLearningService(settings: llmSettings, cacheService: cache)
        self.aiAssistant = AILyricsAssistantService(settings: llmSettings)
        self.aiTranscriptionService = AITranscriptionService(settings: llmSettings)
        syncEngine.globalLatencyCompensationMs = settings.globalLatencyCompensationMs
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(self.nextPollInterval() * 1_000_000_000))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        lyricsTask?.cancel()
        stableTrackTask?.cancel()
    }

    func retryLyrics() {
        guard let track = playback.track else { return }
        stopLiveTranscription()
        nextLyricsRetryAt[track.stableKey] = .distantPast
        recoverableFailureCount[track.stableKey] = 0
        scheduleLyricsSearch(for: track, forceNetwork: true)
    }

    func refreshNow(forceLyrics: Bool = false) {
        Task {
            await tick(forceLyrics: forceLyrics)
        }
    }

    func toggleLyricsVisibility() {
        settings.hideLyrics.toggle()
        refreshMenuTitle(force: true)
    }

    func showLyricsPanel() {
        panelRoute = .lyrics
    }

    func showSettings() {
        panelRoute = .settings
    }

    func showAISettings() {
        panelRoute = .aiSettings
    }

    func clearCache() {
        Task {
            await cache.clear()
            nextLyricsRetryAt.removeAll()
            recoverableFailureCount.removeAll()
            if let track = playback.track {
                scheduleLyricsSearch(for: track, forceNetwork: true)
            }
        }
    }

    func adjustOffset(by deltaMs: Int) {
        guard let track = playback.track else { return }
        let updated = max(-3_000, min(3_000, currentOffsetMs + deltaMs))
        currentOffsetMs = updated
        syncEngine.perTrackOffsetMs = updated
        updateSnapshot(positionMs: playback.positionMs, force: true)
        refreshMenuTitle(force: true)
        Task { await cache.setOffset(updated, for: track) }
    }

    func resetOffset() {
        guard let track = playback.track else { return }
        currentOffsetMs = 0
        syncEngine.perTrackOffsetMs = 0
        updateSnapshot(positionMs: playback.positionMs, force: true)
        refreshMenuTitle(force: true)
        Task { await cache.setOffset(0, for: track) }
    }

    func transcribePodcastAudio(from url: URL) {
        guard let track = playback.track, track.contentKind == .episode else { return }
        let sessionID = activeLyricsSessionID ?? UUID()
        activeLyricsSessionID = sessionID
        lyricsInFlightTrackKey = track.stableKey
        isTranscribingPodcast = true
        podcastTranscriptionError = nil
        lyricsStatus = .loading
        setLyricsLoadingState(.aiGeneratingLyrics, message: "AI transcribing podcast audio...")
        menuTitle = "♪ Transcribing podcast..."
        Task {
            do {
                let candidate = try await aiTranscriptionService.transcribe(fileURL: url, track: track)
                await MainActor.run {
                    guard self.playback.track?.stableKey == track.stableKey else { return }
                    self.isTranscribingPodcast = false
                    Task { await self.cache.save(candidate: candidate, for: track) }
                    self.applySyncedLyrics(candidate, track: track, offsetMs: self.currentOffsetMs, sessionID: sessionID, source: candidate.source)
                }
            } catch {
                await MainActor.run {
                    self.isTranscribingPodcast = false
                    self.podcastTranscriptionError = AITranscriptionService.humanReadable(error)
                    self.finishNeedsUserAction(
                        sessionID: sessionID,
                        trackKey: track.stableKey,
                        message: "AI transcription could not finish for this audio. Check the provider/audio error below, then retry or import a local audio file."
                    )
                }
            }
        }
    }

    private func startLiveTranscription(for track: PlaybackTrack, sessionID: UUID) {
        NSLog("SpotLyrics: Starting live transcription for \"%@\"", track.title)
        isLiveTranscribing = true
        setLyricsLoadingState(.aiGeneratingLyrics, message: "Live transcribing podcast audio...")
        menuTitle = "♪ Live transcribing..."
        lyricsStatus = .loading

        let service = LiveTranscriptionService(settings: llmSettings)
        service.configureLocales(preferences: Self.liveTranscriptionLocales(for: track))
        liveTranscriptionService = service

        service.onLinesUpdated = { [weak self] lines in
            guard let self, self.activeLyricsSessionID == sessionID else { return }
            self.livePartialText = nil
            self.syncEngine.replaceLines(lines)
            self.lyricsLines = lines
            self.updateSnapshot(positionMs: self.playback.positionMs, force: true)
            self.refreshMenuTitle(force: true)
            if lines.count >= 2 {
                let lrc = service.currentLRC() ?? ""
                self.currentCandidate = LyricsCandidate(
                    trackName: track.title,
                    artistName: track.podcastShowName,
                    albumName: track.album,
                    durationMs: track.durationMs,
                    syncedLyrics: lrc,
                    plainLyrics: nil,
                    source: "Live transcription",
                    confidence: 0.80
                )
                self.lyricsStatus = .ready(self.currentCandidate!)
                self.setLyricsLoadingState(.foundSyncedLyrics, message: "Live transcription active")
            }
        }

        service.onPartialUpdated = { [weak self] partial in
            guard let self, self.activeLyricsSessionID == sessionID else { return }
            let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            self.livePartialText = trimmed.isEmpty ? nil : trimmed
        }

        if playback.isPlaying {
            service.start(playbackPositionMs: playback.positionMs)
        } else {
            menuTitle = "♪ Live transcription ready — play to start"
        }
    }

    private func stopLiveTranscription() {
        guard isLiveTranscribing else { return }
        if let service = liveTranscriptionService, let lrc = service.currentLRC() {
            if let track = playback.track {
                let candidate = LyricsCandidate(
                    trackName: track.title,
                    artistName: track.podcastShowName,
                    albumName: track.album,
                    durationMs: track.durationMs,
                    syncedLyrics: lrc,
                    plainLyrics: nil,
                    source: "Live transcription",
                    confidence: 0.80
                )
                Task { await cache.save(candidate: candidate, for: track) }
            }
        }
        liveTranscriptionService?.stop()
        liveTranscriptionService = nil
        isLiveTranscribing = false
    }

    func importLRC(from url: URL) {
        guard let track = playback.track, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let candidate: LyricsCandidate
        if track.contentKind == .episode,
           let transcript = PodcastTranscriptService.candidate(from: text, track: track) {
            candidate = transcript
        } else {
            candidate = LyricsCandidate(
                trackName: track.title,
                artistName: track.artist,
                albumName: track.album,
                durationMs: track.durationMs,
                syncedLyrics: text,
                plainLyrics: nil,
                source: "Imported LRC",
                confidence: 1
            )
        }
        currentCandidate = candidate
        lyricsStatus = .ready(candidate)
        setLyricsLoadingState(.foundSyncedLyrics, message: track.contentKind == .episode ? "Imported podcast transcript" : "Imported synced lyrics")
        syncEngine.load(lrcText: candidate.syncedLyrics)
        lyricsLines = syncEngine.lines
        updateSnapshot(positionMs: playback.positionMs, force: true)
        refreshMenuTitle(force: true)
        Task { await cache.save(candidate: candidate, for: track) }
    }

    func explainCurrentLine() {
        guard let line = snapshot.current?.text else { return }
        explain(line: line)
    }

    func explain(line: LyricLine) {
        explain(line: line.text)
    }

    func explain(line: String) {
        guard !line.isEmpty, let track = playback.track else { return }
        learningLine = line
        isLearningLoading = true
        learningError = nil
        learningNote = nil
        Task {
            do {
                let note = try await englishLearningService.explain(
                    line: line,
                    previous: snapshot.previous.map(\.text),
                    next: snapshot.next.map(\.text),
                    track: track
                )
                await MainActor.run {
                    self.learningNote = note
                    self.isLearningLoading = false
                }
            } catch {
                await MainActor.run {
                    self.learningError = EnglishLearningService.humanReadable(error)
                    self.isLearningLoading = false
                }
            }
        }
    }

    func clearLearningNote() {
        learningNote = nil
        learningError = nil
        learningLine = nil
        isLearningLoading = false
    }

    /// True while the automatic lyrics pipeline is still running through its stages,
    /// or it has paused for a short retry window. The UI uses this to show progress
    /// instead of fallback action buttons.
    var isLyricsSearchActive: Bool {
        switch lyricsLoadingState {
        case .waitingForStableTrack, .checkingCache, .searchingPrimarySource,
             .searchingFallbackSources, .aiRewritingIdentity, .aiSearchingWithHints,
             .aiGeneratingLyrics, .aiAssistedSearch, .failedRecoverable:
            return true
        default:
            return false
        }
    }

    var lyricsNeedsUserAction: Bool {
        if case .needsUserAction = lyricsLoadingState { return true }
        if case .failedFinal = lyricsLoadingState { return true }
        return false
    }

    func pasteLyricsFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let track = playback.track
        else { return }

        let looksSynced = text.range(of: #"\[\d{1,2}:\d{2}"#, options: .regularExpression) != nil
        let candidate: LyricsCandidate
        if track.contentKind == .episode,
           let transcript = PodcastTranscriptService.candidate(from: text, track: track) {
            candidate = transcript
        } else if looksSynced {
            candidate = LyricsCandidate(
                trackName: track.title,
                artistName: track.artist,
                albumName: track.album,
                durationMs: track.durationMs,
                syncedLyrics: text,
                plainLyrics: nil,
                source: "Pasted LRC",
                confidence: 1
            )
        } else if let estimated = estimateSyncedLyrics(
            from: LyricsCandidate(
                trackName: track.title,
                artistName: track.artist,
                albumName: track.album,
                durationMs: track.durationMs,
                syncedLyrics: nil,
                plainLyrics: text,
                source: "Pasted lyrics",
                confidence: 0.95
            ),
            track: track
        ) {
            candidate = estimated
        } else {
            return
        }

        currentCandidate = candidate
        lyricsStatus = .ready(candidate)
        setLyricsLoadingState(.foundSyncedLyrics, message: track.contentKind == .episode ? "Using pasted podcast transcript" : "Using pasted lyrics")
        syncEngine.load(lrcText: candidate.syncedLyrics)
        lyricsLines = syncEngine.lines
        updateSnapshot(positionMs: playback.positionMs, force: true)
        refreshMenuTitle(force: true)
        Task { await cache.save(candidate: candidate, for: track) }
    }

    private func tick(forceLyrics: Bool = false) async {
        syncEngine.globalLatencyCompensationMs = settings.globalLatencyCompensationMs
        let previousPlayback = playback
        let newPlayback = await playbackService.fetchState()
        playback = newPlayback

        guard let track = newPlayback.track else {
            lastTrackKey = nil
            currentCandidate = nil
            lyricsLines = []
            cancelLyricsSearch()
            syncEngine.load(lrcText: nil)
            resetSnapshot(positionMs: 0)
            updateMenuForEmptyState(error: newPlayback.error)
            return
        }

        if !track.contentKind.supportsLyrics {
            applyNonLyricPlayback(track: track, playback: newPlayback)
            return
        }

        // Skip the search pipeline entirely for instrumentals / type beats / karaoke
        // backings — they have no lyrics and burning AI tokens on them is wasteful.
        if isLikelyInstrumental(track) {
            if track.stableKey != lastTrackKey {
                stableTrackTask?.cancel()
                lyricsTask?.cancel()
                lyricsInFlightTrackKey = nil
                activeLyricsSessionID = nil
                lastTrackKey = track.stableKey
                lastMenuLineID = nil
            }
            currentCandidate = nil
            lyricsLines = []
            syncEngine.load(lrcText: nil)
            resetSnapshot(positionMs: newPlayback.positionMs)
            lyricsStatus = .notFound("Instrumental — sit back and vibe.")
            setLyricsLoadingState(.instrumental, message: "Instrumental — sit back and vibe.")
            nextLyricsRetryAt[track.stableKey] = .distantFuture
            menuTitle = "♫ \(track.title)"
            return
        }

        if track.stableKey != lastTrackKey {
            // Cancel any in-flight search for the previous track.
            stableTrackTask?.cancel()
            lyricsTask?.cancel()
            lyricsInFlightTrackKey = nil
            activeLyricsSessionID = nil
            stopLiveTranscription()

            lastTrackKey = track.stableKey
            lastMenuLineID = nil
            lastPositionMs = newPlayback.positionMs
            lastPositionJumpAt = nil
            learningNote = nil
            learningLine = nil
            podcastTranscriptionError = nil
            translationCache = [:]
            translationTask?.cancel()
            translationTask = nil
            currentTranslation = nil
            lastTranslatedLineID = nil
            currentCandidate = nil
            lyricsLines = []
            syncEngine.load(lrcText: nil)
            resetSnapshot(positionMs: newPlayback.positionMs)
            lyricsStatus = .loading
            setLyricsLoadingState(.waitingForStableTrack, message: "Waiting for stable track details...")
            metadataWaitStartedAt = Date()
            // Reset retry gate so the search pipeline actually starts. Without this,
            // switching back to a previously-successful track would be blocked by
            // the .distantFuture set on first success.
            nextLyricsRetryAt[track.stableKey] = .distantPast
            currentOffsetMs = await cache.offset(for: track)
            syncEngine.perTrackOffsetMs = currentOffsetMs
            scheduleLyricsSearch(for: track, forceNetwork: false)
        } else if forceLyrics || shouldAutoRetryLyrics(for: track) {
            scheduleLyricsSearch(for: track, forceNetwork: forceLyrics)
        }

        recoverStuckLyricsLoadingIfNeeded(track: track)

        if newPlayback.isPlaying {
            if isLiveTranscribing, let liveService = liveTranscriptionService {
                switch liveService.state {
                case .paused:
                    liveService.resume(playbackPositionMs: newPlayback.positionMs)
                case .idle:
                    liveService.start(playbackPositionMs: newPlayback.positionMs)
                default:
                    break
                }
            }
            let expectedDelta = Int(newPlayback.updatedAt.timeIntervalSince(previousPlayback.updatedAt) * 1000)
            let actualDelta = abs(newPlayback.positionMs - lastPositionMs)
            if actualDelta > max(4_000, expectedDelta + 2_500) {
                lastMenuLineID = nil
                lastPositionJumpAt = Date()
                menuTitle = "♪ Syncing…"
            }
            lastPositionMs = newPlayback.positionMs
            updateSnapshot(positionMs: newPlayback.positionMs, force: lastPositionJumpAt != nil)
            refreshMenuTitle(force: false)
        } else {
            if isLiveTranscribing, case .running = liveTranscriptionService?.state {
                liveTranscriptionService?.pause()
            }
            lastPositionMs = newPlayback.positionMs
            menuTitle = "Ⅱ \(TextNormalizer.boundedMenuText(track.title, maxCharacters: menuCharacterLimit())) — Paused"
        }
    }

    private func scheduleLyricsSearch(for track: PlaybackTrack, forceNetwork: Bool) {
        let trackKey = track.stableKey
        guard forceNetwork || shouldStartLyricsRequest(for: track) else { return }

        stableTrackTask?.cancel()
        lyricsTask?.cancel()
        let sessionID = UUID()
        activeLyricsSessionID = sessionID
        lyricsInFlightTrackKey = trackKey
        lyricsStatus = .loading
        setLyricsLoadingState(.waitingForStableTrack, message: "Waiting for stable track details...")
        menuTitle = "♪ Preparing lyrics search..."
        logLyrics(sessionID: sessionID, track: track, state: .waitingForStableTrack, source: "metadata", resultCount: nil, error: nil)

        stableTrackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.isCurrentLyricsSession(sessionID, trackKey: trackKey),
                      self.playback.track?.stableKey == trackKey
                else { return }
                if self.isMetadataSearchable(track) {
                    self.startLyricsPipeline(for: track, forceNetwork: forceNetwork, sessionID: sessionID)
                } else if let started = self.metadataWaitStartedAt, Date().timeIntervalSince(started) >= 8 {
                    self.finishNeedsUserAction(
                        sessionID: sessionID,
                        trackKey: trackKey,
                        message: "Need better track details before searching. Try Refresh or import .lrc."
                    )
                } else {
                    self.nextLyricsRetryAt[trackKey] = Date().addingTimeInterval(1)
                    self.lyricsInFlightTrackKey = nil
                }
            }
        }
    }

    private func startLyricsPipeline(for track: PlaybackTrack, forceNetwork: Bool, sessionID: UUID) {
        let trackKey = track.stableKey
        lyricsTask?.cancel()
        lyricsTask = Task { [weak self] in
            guard let self else { return }

            await MainActor.run {
                guard self.isCurrentLyricsSession(sessionID, trackKey: trackKey) else { return }
                self.setLyricsLoadingState(.checkingCache, message: "Checking cached lyrics...")
                self.menuTitle = "♪ Checking cache..."
                self.logLyrics(sessionID: sessionID, track: track, state: .checkingCache, source: "cache", resultCount: nil, error: nil)
            }

            if !forceNetwork,
               let cached = await cache.cachedLyrics(for: track),
               let syncedText = cached.candidate.syncedLyrics, !syncedText.isEmpty,
               !LRCParser.parse(syncedText).isEmpty {
                let cachedSourceIsAI = cached.candidate.source.lowercased().contains("ai")
                let cjkOk = await MainActor.run {
                    self.passesCJKScriptCheck(track: track, generated: syncedText)
                }
                // Evict cached "transcript-page" candidates: their timestamps
                // were estimated from line count and drift wildly from the
                // actual audio. Falling through forces the fresh pipeline,
                // which will reject the same source and end up at Live
                // transcription.
                let cachedIsFakeTimedPodcast = Self.isFakeTimedPodcastTranscript(cached.candidate)
                if cachedSourceIsAI && !cjkOk {
                    await self.cache.save(
                        candidate: LyricsCandidate(
                            trackName: track.title, artistName: track.artist,
                            albumName: track.album, durationMs: track.durationMs,
                            syncedLyrics: nil, plainLyrics: nil,
                            source: "evicted-bad-cache", confidence: 0
                        ),
                        for: track
                    )
                } else if cachedIsFakeTimedPodcast {
                    NSLog("SpotLyrics: evicting cached fake-timed podcast transcript (%@)", cached.candidate.source)
                    await self.cache.save(
                        candidate: LyricsCandidate(
                            trackName: track.title, artistName: track.artist,
                            albumName: track.album, durationMs: track.durationMs,
                            syncedLyrics: nil, plainLyrics: nil,
                            source: "evicted-fake-timed-podcast", confidence: 0
                        ),
                        for: track
                    )
                } else {
                    await MainActor.run {
                        guard self.isCurrentLyricsSession(sessionID, trackKey: trackKey) else { return }
                        self.applySyncedLyrics(cached.candidate, track: track, offsetMs: cached.offsetMs, sessionID: sessionID, source: "cache")
                    }
                    return
                }
            }

            let result = await self.searchNetworkPipeline(for: track, sessionID: sessionID)
            await MainActor.run {
                guard self.isCurrentLyricsSession(sessionID, trackKey: trackKey) else { return }
                self.applySearchResult(result, track: track, sessionID: sessionID)
            }
        }
    }

    private func searchNetworkPipeline(for track: PlaybackTrack, sessionID: UUID) async -> LyricsPipelineResult {
        let variants = searchVariants(for: track)
        var bestPlainOnly: LyricsCandidate?
        var bestLowConfidence: Double = 0
        var lastRecoverableError: LyricsSearchError?
        let searchingPodcastTranscript = track.contentKind == .episode

        // For podcasts: try Spotify's own transcript FIRST (fastest, most accurate)
        if searchingPodcastTranscript {
            let spDc = (try? APIKeychainStore().readAPIKey(account: "spotify_sp_dc")) ?? nil
            if let spDc, !spDc.isEmpty {
                await MainActor.run {
                    guard self.isCurrentLyricsSession(sessionID, trackKey: track.stableKey) else { return }
                    self.setLyricsLoadingState(.searchingPrimarySource, message: "Fetching Spotify transcript...")
                    self.menuTitle = "♪ Fetching Spotify transcript..."
                }
                let episodeID = track.spotifyEpisodeID ?? ""
                if !episodeID.isEmpty,
                   let lrc = await spotifyTranscriptService.fetchTranscript(episodeID: episodeID, spDcCookie: spDc) {
                    let candidate = LyricsCandidate(
                        trackName: track.title,
                        artistName: track.podcastShowName,
                        albumName: track.album,
                        durationMs: track.durationMs,
                        syncedLyrics: lrc,
                        plainLyrics: lrc,
                        source: "Spotify Transcript",
                        confidence: 0.95
                    )
                    return .synced(candidate)
                }
            }
        }

        for (index, variant) in variants.enumerated() {
            let state: LyricsLoadingState = index == 0 ? .searchingPrimarySource : .searchingFallbackSources
            await MainActor.run {
                guard self.isCurrentLyricsSession(sessionID, trackKey: track.stableKey) else { return }
                let message = searchingPodcastTranscript
                    ? "Searching podcast transcripts..."
                    : (index == 0 ? "Searching lyrics on public sources..." : "Trying another source...")
                self.setLyricsLoadingState(state, message: message)
                self.menuTitle = searchingPodcastTranscript
                    ? "♪ Searching transcript..."
                    : (index == 0 ? "♪ Searching lyrics..." : "♪ Trying another source...")
                self.logLyrics(sessionID: sessionID, track: variant, state: state, source: searchingPodcastTranscript ? "podcast-transcript" : "public", resultCount: nil, error: nil)
            }

            do {
                // First variant gets the longest budget because LRCLib often warms up
                // around 8s on the first call; subsequent variants are usually warm.
                let candidate = try await Self.withTimeout(seconds: index == 0 ? 14 : 9) {
                    try await self.searchService(for: variant).bestLyrics(for: variant)
                }
                // Reject "transcript text" candidates for podcasts: those are
                // show-notes / episode-page text where we synthesize fake
                // timestamps from line count. The result drifts wildly from
                // the actual audio (see live-listener bug report). Fall
                // through to Live transcription instead.
                if searchingPodcastTranscript,
                   Self.isFakeTimedPodcastTranscript(candidate) {
                    NSLog("SpotLyrics: rejecting estimated-timing transcript from %@; will use live transcription", candidate.source)
                    continue
                }
                return .synced(candidate)
            } catch LyricsSearchError.plainOnly(let candidate) {
                if candidate.confidence > (bestPlainOnly?.confidence ?? 0) {
                    bestPlainOnly = candidate
                }
            } catch LyricsSearchError.lowConfidence(let confidence) {
                bestLowConfidence = max(bestLowConfidence, confidence)
            } catch LyricsSearchError.network {
                lastRecoverableError = .network
            } catch LyricsSearchError.timedOut {
                lastRecoverableError = .timedOut
            } catch is CancellationError {
                return .cancelled
            } catch {
                lastRecoverableError = .network
            }
        }

        if searchingPodcastTranscript {
            // Priority 2: YouTube CC subtitles (free, accurate, timestamped)
            await MainActor.run {
                guard self.isCurrentLyricsSession(sessionID, trackKey: track.stableKey) else { return }
                self.setLyricsLoadingState(.searchingPrimarySource, message: "Searching YouTube captions...")
                self.menuTitle = "♪ Searching YouTube CC..."
            }
            if let lrc = await YouTubeTranscriptService().fetchTranscript(
                title: track.title,
                showName: track.podcastShowName,
                durationMs: track.durationMs
            ) {
                let candidate = LyricsCandidate(
                    trackName: track.title,
                    artistName: track.podcastShowName,
                    albumName: track.album,
                    durationMs: track.durationMs,
                    syncedLyrics: lrc,
                    plainLyrics: lrc,
                    source: "YouTube CC",
                    confidence: 0.90
                )
                return .synced(candidate)
            }

            // Priority 3: Live transcription from system audio.
            // No public transcript was usable. Capture what's actually playing
            // through Spotify and transcribe it in realtime. This is the only
            // path that can guarantee timestamps match the audio currently in
            // the user's ears.
            if #available(macOS 14.2, *) {
                return .liveTranscription
            }

            // Fallback: RSS audio AI transcription (older macOS, if YouTube CC not available)
            if aiTranscriptionService.isConfigured,
               let audioURL = await podcastTranscriptAudioURL(for: track) {
                await MainActor.run {
                    guard self.isCurrentLyricsSession(sessionID, trackKey: track.stableKey) else { return }
                    self.setLyricsLoadingState(.aiGeneratingLyrics, message: "AI transcribing RSS podcast audio in timed chunks...")
                    self.menuTitle = "♪ Transcribing podcast..."
                    self.logLyrics(sessionID: sessionID, track: track, state: .aiGeneratingLyrics, source: "rss-audio", resultCount: nil, error: nil)
                }
                do {
                    let candidate = try await aiTranscriptionService.transcribe(audioURL: audioURL, track: track)
                    return .synced(candidate)
                } catch {
                    await MainActor.run {
                        self.podcastTranscriptionError = AITranscriptionService.humanReadable(error)
                    }
                }
            }
            let message = aiTranscriptionService.isConfigured
                ? "No public transcript or RSS audio was available for automatic transcription. Import a local audio file to transcribe it."
                : "No public transcript was found. Add an OpenAI-compatible API key to enable automatic podcast audio transcription."
            return .needsUserAction(message)
        }

        // Public sources failed. Bring in the user-configured LLM to (a) translate
        // names so we can re-query, and (b) generate the LRC outright when the
        // databases are unreachable / don't have the song.
        if aiAssistant.isConfigured {
            if let aiResult = await runAIAssistedPipeline(
                for: track,
                sessionID: sessionID,
                bestPlainOnly: &bestPlainOnly
            ) {
                return aiResult
            }
        }

        if let bestPlainOnly {
            if let estimated = estimateSyncedLyrics(from: bestPlainOnly, track: track) {
                return .estimatedSync(estimated)
            }
            return .plainOnly(bestPlainOnly)
        }
        if bestLowConfidence > 0 {
            return .lowConfidence(bestLowConfidence)
        }
        if let lastRecoverableError {
            return .recoverable(lastRecoverableError)
        }
        return .needsUserAction("Need your help: import or paste lyrics. Public sources did not return a trustworthy synced match.")
    }

    private func runAIAssistedPipeline(
        for track: PlaybackTrack,
        sessionID: UUID,
        bestPlainOnly: inout LyricsCandidate?
    ) async -> LyricsPipelineResult? {
        // Stage 1: ask the LLM to translate / romanize names so public sources can find it.
        await MainActor.run {
            guard self.isCurrentLyricsSession(sessionID, trackKey: track.stableKey) else { return }
            self.setLyricsLoadingState(.aiRewritingIdentity, message: "Asking AI for alternate names...")
            self.menuTitle = "♪ AI translating names..."
            self.logLyrics(sessionID: sessionID, track: track, state: .aiRewritingIdentity, source: "ai-rewrite", resultCount: nil, error: nil)
        }

        var hints: LyricsIdentityHints?
        do {
            hints = try await aiAssistant.rewriteIdentity(for: track)
        } catch {
            logLyrics(sessionID: sessionID, track: track, state: .aiRewritingIdentity, source: "ai-rewrite", resultCount: 0, error: String(describing: error))
        }

        if let hints, !hints.altTitles.isEmpty || !hints.altArtists.isEmpty {
            let aiVariants = aiSearchVariants(for: track, hints: hints)
            for (index, variant) in aiVariants.enumerated() {
                await MainActor.run {
                    guard self.isCurrentLyricsSession(sessionID, trackKey: track.stableKey) else { return }
                    self.setLyricsLoadingState(.aiSearchingWithHints, message: "Searching with AI hint #\(index + 1)...")
                    self.menuTitle = "♪ AI assisted search..."
                    self.logLyrics(sessionID: sessionID, track: variant, state: .aiSearchingWithHints, source: "ai-hints", resultCount: nil, error: nil)
                }
                do {
                    let candidate = try await Self.withTimeout(seconds: 10) {
                        try await self.searchService(for: variant).bestLyrics(for: variant)
                    }
                    return .synced(candidate)
                } catch LyricsSearchError.plainOnly(let candidate) {
                    if candidate.confidence > (bestPlainOnly?.confidence ?? 0) {
                        bestPlainOnly = candidate
                    }
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    continue
                }
            }
        }

        // Stage 2: have the LLM generate an LRC directly, using the hints to anchor the song.
        await MainActor.run {
            guard self.isCurrentLyricsSession(sessionID, trackKey: track.stableKey) else { return }
            self.setLyricsLoadingState(.aiGeneratingLyrics, message: "AI generating synced lyrics...")
            self.menuTitle = "♪ AI generating lyrics..."
            self.logLyrics(sessionID: sessionID, track: track, state: .aiGeneratingLyrics, source: "ai-generate", resultCount: nil, error: nil)
        }
        let frozenHints = hints
        do {
            // Generating a full LRC can take 20-40s depending on the model; give it room.
            let candidate = try await Self.withTimeout(seconds: 60) {
                try await self.aiAssistant.generateLyrics(for: track, hints: frozenHints)
            }
            if candidate.confidence >= 0.4,
               let synced = candidate.syncedLyrics, !synced.isEmpty,
               LRCParser.parse(synced).count >= 5,
               passesCJKScriptCheck(track: track, generated: synced) {
                return .synced(candidate)
            }
            logLyrics(sessionID: sessionID, track: track, state: .aiGeneratingLyrics, source: "ai-generate", resultCount: 0, error: "aiOutputUnusable(\(candidate.confidence))")
        } catch {
            logLyrics(sessionID: sessionID, track: track, state: .aiGeneratingLyrics, source: "ai-generate", resultCount: 0, error: String(describing: error))
        }
        return nil
    }

    /// If the song's title or artist is in CJK, the AI's generated lyrics MUST also
    /// contain CJK characters. Otherwise the model returned a Pinyin/Romaji/Hangul
    /// transliteration, which is unusable — reject and let the user import a .lrc.
    private func passesCJKScriptCheck(track: PlaybackTrack, generated: String) -> Bool {
        let originalIsCJK = TextNormalizer.containsCJK(track.title) || TextNormalizer.containsCJK(track.artist)
        guard originalIsCJK else { return true }
        // Strip timestamps and parser metadata before counting CJK chars in the body.
        let stripped = generated
            .replacingOccurrences(of: #"\[\d{1,2}:\d{2}(?:\.\d{1,3})?\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(作词|作曲|编曲|演唱)\s*:.*$"#, with: "", options: [.regularExpression])
        let cjkScalarCount = stripped.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains($0.value) ||
            (0x3400...0x4DBF).contains($0.value) ||
            (0x3040...0x30FF).contains($0.value) ||
            (0xAC00...0xD7AF).contains($0.value)
        }.count
        // Need at least ~30 CJK characters in the body to consider this a real
        // Chinese/Japanese/Korean transcription rather than a romanized one.
        return cjkScalarCount >= 30
    }

    private func aiSearchVariants(for track: PlaybackTrack, hints: LyricsIdentityHints) -> [PlaybackTrack] {
        var variants: [PlaybackTrack] = []
        var seen = Set<String>()
        let originalTitles = [track.title]
        let titles = (hints.altTitles + originalTitles).filter { !$0.isEmpty }
        let artists = (hints.altArtists + [track.artist]).filter { !$0.isEmpty }

        for title in titles.prefix(4) {
            for artist in artists.prefix(4) {
                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedTitle.isEmpty, !trimmedArtist.isEmpty else { continue }
                let key = "\(TextNormalizer.cacheKey(trimmedTitle))|\(TextNormalizer.cacheKey(trimmedArtist))"
                guard seen.insert(key).inserted else { continue }
                variants.append(track.copyForLyricsSearch(title: trimmedTitle, artist: trimmedArtist))
                if variants.count >= 6 { return variants }
            }
        }
        return variants
    }

    private func applySearchResult(_ result: LyricsPipelineResult, track: PlaybackTrack, sessionID: UUID) {
        let trackKey = track.stableKey
        switch result {
        case .synced(let candidate):
            Task { await cache.save(candidate: candidate, for: track) }
            applySyncedLyrics(candidate, track: track, offsetMs: currentOffsetMs, sessionID: sessionID, source: candidate.source)
        case .estimatedSync(let candidate):
            Task { await cache.save(candidate: candidate, for: track) }
            applySyncedLyrics(candidate, track: track, offsetMs: currentOffsetMs, sessionID: sessionID, source: candidate.source)
            setLyricsLoadingState(.foundSyncedLyrics, message: "Found plain lyrics, estimating sync...")
        case .plainOnly(let candidate):
            lyricsInFlightTrackKey = nil
            currentCandidate = candidate
            syncEngine.load(lrcText: nil)
            lyricsLines = []
            lyricsStatus = .plainOnly(candidate)
            setLyricsLoadingState(.foundUnsyncedLyrics, message: "Found plain lyrics without a timeline. Import .lrc for timing.")
            // Don't auto-retry — we already exhausted public sources + AI generate.
            nextLyricsRetryAt[trackKey] = .distantFuture
            menuTitle = "♪ Unsynced lyrics available"
            logLyrics(sessionID: sessionID, track: track, state: .foundUnsyncedLyrics, source: candidate.source, resultCount: 1, error: nil)
        case .lowConfidence(let confidence):
            lyricsInFlightTrackKey = nil
            lyricsStatus = .lowConfidence(confidence)
            finishNeedsUserAction(
                sessionID: sessionID,
                trackKey: trackKey,
                message: "We searched several sources but the best match was too uncertain. Help us match this song."
            )
            logLyrics(sessionID: sessionID, track: track, state: .needsUserAction, source: "public", resultCount: 0, error: "lowConfidence(\(confidence))")
        case .recoverable(let error):
            // The whole pipeline (parallel public sources + AI rewrite + AI generate)
            // already ran. Looping back would burn AI tokens and spam the UI with
            // "Lyrics source slow" repeatedly. Park it here until the user clicks Retry
            // or the track changes.
            lyricsInFlightTrackKey = nil
            finishNeedsUserAction(
                sessionID: sessionID,
                trackKey: trackKey,
                message: "Lyric sources didn't respond and AI couldn't recover them. Click Retry or import a .lrc."
            )
            logLyrics(sessionID: sessionID, track: track, state: .needsUserAction, source: "public", resultCount: 0, error: "recoverable(\(error))")
        case .needsUserAction(let message):
            finishNeedsUserAction(sessionID: sessionID, trackKey: trackKey, message: message)
        case .liveTranscription:
            lyricsInFlightTrackKey = nil
            startLiveTranscription(for: track, sessionID: sessionID)
        case .cancelled:
            break
        }
    }

    private func applySyncedLyrics(_ candidate: LyricsCandidate, track: PlaybackTrack, offsetMs: Int, sessionID: UUID, source: String) {
        lyricsInFlightTrackKey = nil
        currentCandidate = candidate
        currentOffsetMs = offsetMs
        syncEngine.perTrackOffsetMs = offsetMs
        syncEngine.load(
            lrcText: candidate.syncedLyrics,
            sourceDurationMs: candidate.durationMs,
            playbackDurationMs: track.durationMs
        )

        // AI-generated LRCs often have intro/outro padding wrong: lines start at
        // 0s instead of after the actual intro, or finish 30s early. Normalize so
        // the first line lands in [9s, 25s] and the last line at duration - 8s.
        if candidate.source.lowercased().contains("ai"), let trackMs = track.durationMs, trackMs > 60_000 {
            let calibrated = autoCalibrateAILines(syncEngine.lines, trackDurationMs: trackMs)
            syncEngine.replaceLines(calibrated)
        }
        lyricsLines = syncEngine.lines

        // Guard: if the candidate had a syncedLyrics string but the parser produced no
        // usable lines, the LRC was malformed (no [mm:ss.xx] markers, AI hallucination,
        // etc.). Don't claim "Synced lyrics ready" while showing a blank list.
        guard !lyricsLines.isEmpty else {
            currentCandidate = nil
            lyricsStatus = .notFound("Got lyrics but no timestamps. Click Retry or import a .lrc.")
            finishNeedsUserAction(
                sessionID: sessionID,
                trackKey: track.stableKey,
                message: "Got lyrics but no timestamps. Click Retry or import a .lrc."
            )
            logLyrics(sessionID: sessionID, track: track, state: .needsUserAction, source: source, resultCount: 0, error: "lrcParsedToZero")
            return
        }

        lyricsStatus = .ready(candidate)
        let readyMessage: String
        let lowerSource = candidate.source.lowercased()
        if track.contentKind == .episode {
            readyMessage = lowerSource.contains("text")
                ? "Podcast transcript ready — timing is estimated"
                : "Podcast transcript ready"
        } else if lowerSource.contains("estimated") {
            readyMessage = "✨ AI estimated sync — use offset controls to fine tune."
        } else if lowerSource.contains("ai") {
            readyMessage = "✨ AI generated lyrics ready"
        } else {
            readyMessage = "Synced lyrics ready"
        }
        setLyricsLoadingState(.foundSyncedLyrics, message: readyMessage)
        updateSnapshot(positionMs: playback.positionMs, force: true)
        nextLyricsRetryAt[track.stableKey] = .distantFuture
        recoverableFailureCount[track.stableKey] = 0
        refreshMenuTitle(force: true)
        logLyrics(sessionID: sessionID, track: track, state: .foundSyncedLyrics, source: source, resultCount: lyricsLines.count, error: nil)
        startBatchTranslationIfNeeded()
    }

    private func shouldAutoRetryLyrics(for track: PlaybackTrack) -> Bool {
        currentCandidate == nil && shouldStartLyricsRequest(for: track)
    }

    private func shouldStartLyricsRequest(for track: PlaybackTrack) -> Bool {
        let key = track.stableKey
        if isLiveTranscribing { return false }
        if lyricsInFlightTrackKey == key { return false }
        if case .loading = lyricsStatus, lyricsInFlightTrackKey != nil { return false }
        if currentCandidate?.syncedLyrics?.isEmpty == false { return false }
        return Date() >= (nextLyricsRetryAt[key] ?? .distantPast)
    }

    private func recoverStuckLyricsLoadingIfNeeded(track: PlaybackTrack) {
        // Only treat as stuck after the entire pipeline budget elapsed: parallel
        // public sources (~14s) + AI rewrite (~20s) + AI generate (~60s) + slack.
        guard case .loading = lyricsStatus,
              let changedAt = loadingStateChangedAt
        else { return }
        let timeout: TimeInterval = track.contentKind == .episode && lyricsLoadingState == .aiGeneratingLyrics ? 45 * 60 : 110
        guard Date().timeIntervalSince(changedAt) > timeout else { return }
        let sessionID = activeLyricsSessionID ?? UUID()
        lyricsTask?.cancel()
        stableTrackTask?.cancel()
        lyricsInFlightTrackKey = nil

        // Whatever the current stage, parking once is the right call. Re-running the
        // pipeline would burn AI tokens and put us back in the same loop the user
        // explicitly asked us to stop. A manual Retry / track change re-arms it.
        finishNeedsUserAction(
            sessionID: sessionID,
            trackKey: track.stableKey,
            message: "Search took too long. Click Retry, paste lyrics, or import a .lrc."
        )
        logLyrics(sessionID: sessionID, track: track, state: .needsUserAction, source: "timeout-recovery", resultCount: 0, error: "stateTimeout(\(lyricsLoadingState))")
    }

    private func updateSnapshot(positionMs: Int, force: Bool) {
        let nextSnapshot = syncEngine.snapshot(positionMs: positionMs)
        if force || nextSnapshot.current?.id != snapshot.current?.id || nextSnapshot.previous != snapshot.previous || nextSnapshot.next != snapshot.next {
            snapshot = nextSnapshot
            translateCurrentLineIfNeeded()
        }
    }

    private func resetSnapshot(positionMs: Int) {
        snapshot = SyncedLyricsSnapshot(previous: [], current: nil, next: [], effectivePositionMs: positionMs)
        currentTranslation = nil
        lastTranslatedLineID = nil
    }

    private func translateCurrentLineIfNeeded() {
        guard let line = snapshot.current else {
            currentTranslation = nil
            return
        }
        // Even when the line id hasn't changed, the cache may have just been
        // populated by an in-flight batch — push it through so the user sees
        // the translation appear without waiting for the next line transition.
        if line.id == lastTranslatedLineID {
            if currentTranslation == nil, let cached = translationCache[line.id] {
                currentTranslation = cached
            }
            return
        }
        lastTranslatedLineID = line.id

        if let cached = translationCache[line.id] {
            currentTranslation = cached
        } else {
            currentTranslation = nil
        }

        startBatchTranslationIfNeeded()
    }

    private func startBatchTranslationIfNeeded() {
        let provider = llmSettings.provider
        guard let apiKey = llmSettings.apiKey(), !apiKey.isEmpty else {
            NSLog("SpotLyrics Translate: no API key configured")
            return
        }
        guard !lyricsLines.isEmpty else { return }

        let currentIndex = lyricsLines.firstIndex(where: { $0.id == snapshot.current?.id }) ?? 0
        let currentID = snapshot.current?.id
        let needsCurrent = currentID.map { translationCache[$0] == nil } ?? false

        // Priority pass: if the current line isn't cached, fire a tiny batch
        // (5 lines around the cursor) IMMEDIATELY in parallel with whatever
        // the bulk task is doing. Without this the user waits 5-10 s for the
        // first 25-line batch to come back before seeing any translation.
        if needsCurrent {
            let priorityStart = max(0, currentIndex - 1)
            let priorityEnd = min(lyricsLines.count, currentIndex + 4)
            let priorityBatch = Array(lyricsLines[priorityStart..<priorityEnd])
                .filter { translationCache[$0.id] == nil }
            if !priorityBatch.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    await self.translateBatch(priorityBatch, provider: provider, apiKey: apiKey, label: "priority")
                }
            }
        }

        // Bulk prefetch: cancel any stale ordered task and re-anchor at the
        // current cursor so jumping ahead in the episode doesn't leave the
        // user waiting for the old start point's batches to drain.
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            guard let self else { return }
            let batchSize = 20
            var startIdx = max(0, currentIndex - 2)

            while !Task.isCancelled, startIdx < self.lyricsLines.count {
                let batch = Array(self.lyricsLines.dropFirst(startIdx).prefix(batchSize))
                    .filter { self.translationCache[$0.id] == nil }
                if batch.isEmpty {
                    startIdx += batchSize
                    continue
                }
                await self.translateBatch(batch, provider: provider, apiKey: apiKey, label: "bulk@\(startIdx)")
                startIdx += batchSize
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self.translationTask = nil
        }
    }

    private func translateBatch(_ batch: [LyricLine], provider: LLMProviderConfig, apiKey: String, label: String) async {
        let texts = batch.map { $0.text }
        let numberedInput = texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = "Translate each numbered line to natural Chinese. Keep the same numbering. Output ONLY translations:\n\(numberedInput)"

        NSLog("SpotLyrics Translate[%@]: translating %d lines", label, batch.count)
        guard let result = await self.callTranslationAPI(prompt: prompt, provider: provider, apiKey: apiKey) else {
            NSLog("SpotLyrics Translate[%@]: API returned nil", label)
            return
        }
        let translations = self.parseBatchTranslation(result, count: batch.count)
        NSLog("SpotLyrics Translate[%@]: got %d/%d translations", label, translations.count, batch.count)
        for (i, line) in batch.enumerated() where i < translations.count {
            self.translationCache[line.id] = translations[i]
        }
        // Push to UI immediately if the cursor has landed on (or moved to) a
        // line we just translated.
        if let currentID = self.snapshot.current?.id,
           let translation = self.translationCache[currentID],
           self.currentTranslation != translation {
            self.currentTranslation = translation
        }
    }

    private func parseBatchTranslation(_ text: String, count: Int) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var results: [String] = []
        for line in lines {
            var cleaned = line
            if let dotRange = cleaned.range(of: #"^\d+[\.\)、]\s*"#, options: .regularExpression) {
                cleaned = String(cleaned[dotRange.upperBound...])
            }
            if !cleaned.isEmpty {
                results.append(cleaned)
            }
            if results.count >= count { break }
        }
        return results
    }

    private func callTranslationAPI(prompt: String, provider: LLMProviderConfig, apiKey: String) async -> String? {
        let baseURL = provider.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = URL(string: baseURL + "/chat/completions")!

        let body: [String: Any] = [
            "model": provider.model,
            "messages": [
                ["role": "system", "content": "You are a concise translator. Translate English to natural Chinese. Output ONLY the translation, nothing else."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "max_tokens": 4000
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Linear-rescale AI-generated lyric timestamps so they actually align to the
    /// track's intro/outro. AI tends to either pile lines at 0s or stretch past the
    /// real song length. We anchor the first line to a typical intro position and
    /// the last line to a typical outro position, then scale linearly between.
    private func autoCalibrateAILines(_ lines: [LyricLine], trackDurationMs: Int) -> [LyricLine] {
        guard lines.count >= 4 else { return lines }
        guard let actualFirst = lines.first?.timeMs,
              let actualLast = lines.last?.timeMs,
              actualLast > actualFirst else { return lines }

        // Target landing zones — tuned for typical Mandopop / Cantopop / English pop.
        let targetFirstMs = 14_000
        let targetLastMs = max(targetFirstMs + 30_000, trackDurationMs - 10_000)

        // Already in sane bounds → leave alone (don't introduce drift on a good LRC).
        let firstOk = actualFirst >= 6_000 && actualFirst <= 28_000
        let lastOk = actualLast >= trackDurationMs - 30_000 && actualLast <= trackDurationMs - 4_000
        if firstOk, lastOk { return lines }

        let actualSpan = max(1, actualLast - actualFirst)
        let targetSpan = max(20_000, targetLastMs - targetFirstMs)
        let scale = Double(targetSpan) / Double(actualSpan)

        return lines.map { line in
            let shifted = targetFirstMs + Int(Double(line.timeMs - actualFirst) * scale)
            return LyricLine(timeMs: max(0, min(trackDurationMs - 500, shifted)), text: line.text)
        }
    }

    /// Heuristic for "this track has no vocals to sync". We refuse to spam public
    /// sources or burn AI tokens on these. Strict signals only — the cost of a
    /// false positive (skipping a real song) is higher than a false negative
    /// (briefly searching a beat that has no lyrics anyway).
    private func isLikelyInstrumental(_ track: PlaybackTrack) -> Bool {
        let haystack = "\(track.title) \(track.artist) \(track.album ?? "")".lowercased()
        let signals = [
            "type beat",
            "instrumental",
            "(inst.)", "(inst)", "[inst]",
            "(karaoke)", "karaoke version", " karaoke",
            "backing track",
            "no vocals",
            "minus one",
            "纯音乐", "伴奏", "卡拉ok", "卡拉OK",
            "off vocal"
        ]
        return signals.contains { haystack.contains($0) }
    }

    private func isMetadataSearchable(_ track: PlaybackTrack) -> Bool {
        let hasTitle = !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasArtist = !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let duration = track.durationMs ?? 0
        if track.contentKind == .episode {
            return hasTitle && duration >= 60_000 && duration <= 8 * 60 * 60_000
        }
        return hasTitle && hasArtist && duration >= 30_000 && duration <= 30 * 60_000
    }

    private func isCurrentLyricsSession(_ sessionID: UUID, trackKey: String) -> Bool {
        activeLyricsSessionID == sessionID && playback.track?.stableKey == trackKey
    }

    private func cancelLyricsSearch() {
        stableTrackTask?.cancel()
        lyricsTask?.cancel()
        stableTrackTask = nil
        lyricsTask = nil
        lyricsInFlightTrackKey = nil
        activeLyricsSessionID = nil
        setLyricsLoadingState(.idle)
    }

    private func applyNonLyricPlayback(track: PlaybackTrack, playback: PlaybackState) {
        if track.stableKey != lastTrackKey {
            learningNote = nil
            learningLine = nil
            lastMenuLineID = nil
        }
        currentCandidate = nil
        lyricsLines = []
        cancelLyricsSearch()
        syncEngine.load(lrcText: nil)
        resetSnapshot(positionMs: playback.positionMs)
        currentOffsetMs = 0
        lastPositionMs = playback.positionMs
        lastTrackKey = track.stableKey

        switch track.contentKind {
        case .episode:
            lyricsStatus = .notFound("Podcast mode")
            setLyricsLoadingState(.podcastEpisode, message: "Podcast playback")
            let prefix = playback.isPlaying ? "Podcast" : "Podcast Paused"
            menuTitle = PlaybackPresentation.progressTitle(
                prefix: prefix,
                track: track,
                positionMs: playback.positionMs,
                maxTitleCharacters: max(14, min(menuCharacterLimit(), 28))
            )
        default:
            lyricsStatus = .notFound("Current Spotify content does not support lyrics")
            setLyricsLoadingState(.unsupportedContent, message: "Current Spotify content does not support lyrics")
            menuTitle = PlaybackPresentation.progressTitle(
                prefix: "Unsupported",
                track: track,
                positionMs: playback.positionMs,
                maxTitleCharacters: 14
            )
        }
    }

    private func finishNeedsUserAction(sessionID: UUID, trackKey: String, message: String) {
        guard isCurrentLyricsSession(sessionID, trackKey: trackKey) else { return }
        lyricsInFlightTrackKey = nil
        lyricsStatus = .notFound(message)
        setLyricsLoadingState(.needsUserAction, message: message)
        // Park until the user clicks Retry or the track changes. No automatic re-search.
        nextLyricsRetryAt[trackKey] = .distantFuture
        menuTitle = "♪ Need lyrics help"
        if let track = playback.track {
            logLyrics(sessionID: sessionID, track: track, state: .needsUserAction, source: "recovery", resultCount: 0, error: "needsUserAction")
        }
    }

    private func searchVariants(for track: PlaybackTrack) -> [PlaybackTrack] {
        guard track.contentKind.usesSongLyricsProviders else {
            return [track]
        }
        // Each variant fans out across both providers (LRCLib + NetEase) inside the
        // Composite service, and each provider already tries Hans/Hant + multi-query
        // internally. So this list stays short — anything beyond ~3 variants explodes
        // total search time.
        let conservativeTitle = TextNormalizer.conservativeSearchTitle(track.title)
        let strippedTitle = TextNormalizer.stripBrackets(conservativeTitle)
        let normalizedTitle = TextNormalizer.normalize(track.title)
        let normalizedArtist = TextNormalizer.normalize(track.artist)
        let firstArtist = TextNormalizer.splitArtists(track.artist).first

        var variants: [PlaybackTrack] = [track]

        func add(title: String, artist: String) {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty, !trimmedArtist.isEmpty else { return }
            variants.append(track.copyForLyricsSearch(title: trimmedTitle, artist: trimmedArtist))
        }

        if !strippedTitle.isEmpty, strippedTitle != track.title, strippedTitle != conservativeTitle {
            add(title: strippedTitle, artist: track.artist)
        }
        if let firstArtist, firstArtist != track.artist {
            add(title: conservativeTitle, artist: firstArtist)
        }
        if !normalizedTitle.isEmpty, !normalizedArtist.isEmpty,
           normalizedTitle != conservativeTitle.lowercased() {
            add(title: normalizedTitle, artist: normalizedArtist)
        }

        var seen = Set<String>()
        return variants.filter { variant in
            let key = "\(TextNormalizer.cacheKey(variant.title))|\(TextNormalizer.cacheKey(variant.artist))"
            return seen.insert(key).inserted
        }
    }

    private func searchService(for track: PlaybackTrack) -> LyricsSearching {
        track.contentKind == .episode ? podcastTranscriptSearch : lyricsSearch
    }

    private func podcastTranscriptAudioURL(for track: PlaybackTrack) async -> URL? {
        await (podcastTranscriptSearch as? PodcastTranscriptService)?.publicAudioURL(for: track)
    }

    private func estimateSyncedLyrics(from candidate: LyricsCandidate, track: PlaybackTrack) -> LyricsCandidate? {
        guard let plain = candidate.plainLyrics else { return nil }
        let lines = plain
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        let duration = max(30_000, track.durationMs ?? candidate.durationMs ?? 180_000)
        let usableDuration = max(10_000, duration - 8_000)
        let step = max(1_500, usableDuration / max(1, lines.count))
        let lrc = lines.enumerated().map { index, text in
            let timeMs = 4_000 + index * step
            return "[\(formatLRCTime(timeMs))]\(text)"
        }.joined(separator: "\n")
        return LyricsCandidate(
            trackName: candidate.trackName,
            artistName: candidate.artistName,
            albumName: candidate.albumName,
            durationMs: candidate.durationMs ?? track.durationMs,
            syncedLyrics: lrc,
            plainLyrics: plain,
            source: "\(candidate.source) · AI estimated sync",
            confidence: min(candidate.confidence, 0.62)
        )
    }

    private func formatLRCTime(_ ms: Int) -> String {
        let clamped = max(0, ms)
        let minutes = clamped / 60_000
        let seconds = (clamped % 60_000) / 1_000
        let hundredths = (clamped % 1_000) / 10
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }

    private func logLyrics(sessionID: UUID, track: PlaybackTrack, state: LyricsLoadingState, source: String, resultCount: Int?, error: String?) {
        let shortSession = sessionID.uuidString.prefix(8)
        let duration = track.durationMs.map(String.init) ?? "nil"
        let result = resultCount.map(String.init) ?? "-"
        let errorValue = error ?? "-"
        NSLog(
            "SpotLyrics search session=%@ state=%@ source=%@ track=\"%@\" artist=\"%@\" durationMs=%@ results=%@ error=%@",
            String(shortSession),
            String(describing: state),
            source,
            track.title,
            track.artist,
            duration,
            result,
            errorValue
        )
    }

    /// Detect "transcript-page" candidates whose timestamps were synthesized
    /// from line count rather than measured from audio. Those drift wildly
    /// against the actual playback (the bug the live-transcription work was
    /// supposed to solve) and we'd rather start the live recognizer than
    /// display them.
    ///
    /// Real timed transcripts come from VTT/SRT and pass through. Episode
    /// pages, fan transcripts, RSS show notes — those came from
    /// `TranscriptParser.lrcFromPlainText`, which produces evenly spaced
    /// pseudo-timestamps and tags itself with one of the labels below.
    private static func isFakeTimedPodcastTranscript(_ candidate: LyricsCandidate) -> Bool {
        let src = candidate.source.lowercased()
        return src.contains("podcast transcript page")
            || src.contains("podcast transcript text")
    }

    /// Pick speech-recognition locales for a podcast track based on the script
    /// of its title and show name. Without this the recognizer is locked to
    /// en-US and Mandarin/Cantonese/Japanese/Korean podcasts produce gibberish.
    /// We return an ordered list — the first locale macOS can actually load
    /// wins, the rest are fallbacks for installs missing the language pack.
    private static func liveTranscriptionLocales(for track: PlaybackTrack) -> [String] {
        let haystack = "\(track.title) \(track.podcastShowName) \(track.album ?? "")"
        switch TextNormalizer.dominantScript(haystack) {
        case .hanSimplified:
            return ["zh-CN", "zh-Hans-CN", "yue-CN", "en-US"]
        case .hanTraditional:
            return ["zh-TW", "zh-Hant-TW", "yue-HK", "zh-HK", "en-US"]
        case .japanese:
            return ["ja-JP", "en-US"]
        case .korean:
            return ["ko-KR", "en-US"]
        case .latin:
            return ["en-US"]
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LyricsSearchError.timedOut
            }
            guard let result = try await group.next() else {
                throw LyricsSearchError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    private func refreshMenuTitle(force: Bool) {
        if settings.hideLyrics {
            menuTitle = "SpotLyrics"
            return
        }
        guard let current = snapshot.current else {
            if let track = playback.track, !track.contentKind.supportsLyrics {
                menuTitle = PlaybackPresentation.progressTitle(
                    prefix: "Unsupported",
                    track: track,
                    positionMs: playback.positionMs,
                    maxTitleCharacters: 14
                )
                return
            }
            if case .loading = lyricsStatus {
                menuTitle = "♪ " + TextNormalizer.boundedMenuText(lyricsRecoveryMessage, maxCharacters: menuCharacterLimit())
            } else if currentCandidate?.syncedLyrics?.isEmpty == false, !snapshot.next.isEmpty {
                menuTitle = "♪ Waiting for lyrics…"
            } else if case .plainOnly = lyricsStatus {
                menuTitle = "♪ Unsynced lyrics available"
            } else if playback.track != nil {
                menuTitle = "♪ Need lyrics help"
            }
            return
        }
        if let jumpAt = lastPositionJumpAt, Date().timeIntervalSince(jumpAt) < 0.7 {
            menuTitle = "♪ Syncing…"
            return
        }
        guard force || current.id != lastMenuLineID else { return }
        lastMenuLineID = current.id
        // No truncation for the actual lyric line — the user explicitly asked us never
        // to render "..." on a long line. macOS will let the status item grow; if it
        // gets too crowded the user can enable the desktop bar instead.
        menuTitle = "♪ " + current.text
    }

    private func updateMenuForEmptyState(error: PlaybackError?) {
        switch error {
        case .spotifyNotRunning:
            menuTitle = "SpotLyrics"
            lyricsStatus = .notFound("Open Spotify to start lyrics")
        case .unsupportedContent, .emptyTrack:
            menuTitle = "♪ Unsupported content"
            lyricsStatus = .notFound("Current Spotify content does not support lyrics")
        case .scriptFailed:
            menuTitle = "SpotLyrics"
            lyricsStatus = .notFound("Allow automation access to Spotify")
        case nil:
            menuTitle = "SpotLyrics"
        }
    }

    private func nextPollInterval() -> Double {
        if playback.error == .spotifyNotRunning { return 4.0 }
        if playback.isPlaying { return 0.4 }
        return 1.5
    }

    private func menuCharacterLimit() -> Int {
        let userLimit = settings.menuBarMaxCharacters
        let width = NSScreen.main?.visibleFrame.width ?? 1440
        if width <= 1300 { return min(userLimit, 18) }
        if width <= 1500 { return min(userLimit, 24) }
        return userLimit
    }
}

private enum LyricsPipelineResult {
    case synced(LyricsCandidate)
    case estimatedSync(LyricsCandidate)
    case plainOnly(LyricsCandidate)
    case lowConfidence(Double)
    case recoverable(LyricsSearchError)
    case needsUserAction(String)
    case liveTranscription
    case cancelled
}

private extension PlaybackTrack {
    func copyForLyricsSearch(title: String, artist: String) -> PlaybackTrack {
        PlaybackTrack(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs,
            source: source,
            spotifyURI: spotifyURI,
            contentKind: contentKind,
            artworkURL: artworkURL
        )
    }
}
