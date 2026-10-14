import SwiftUI
import AppKit

struct LyricsPanelView: View {
    @EnvironmentObject private var appState: AppState
    @State private var hoveredLineID: String?
    @State private var autoScrollPausedUntil = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            lyricsBlock
            controls
            learningBlock
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(SpotifyDesign.background)
        .foregroundStyle(SpotifyDesign.primaryText)
        .preferredColorScheme(.dark)
        .tint(SpotifyDesign.green)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.playback.track?.title ?? "SpotLyrics Bar")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(appState.playback.track?.displaySubtitle ?? statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(SpotifyDesign.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(appState.settings.hideLyrics ? "Show" : "Hide") {
                    appState.toggleLyricsVisibility()
                }
                .buttonStyle(PanelButtonStyle())
                Button("×") {
                    // Close just the lyrics panel — NOT quit the whole app.
                    // Quit lives in the right-click status-bar menu.
                    NSApp.windows.first(where: { $0 is LyricsFloatingPanel })?.close()
                }
                .buttonStyle(IconPanelButtonStyle())
                .accessibilityLabel("Close panel")
                .help("Close panel (right-click the menu bar item to Quit)")
            }
        }
    }

    private var lyricsBlock: some View {
        Group {
            if !appState.lyricsLines.isEmpty {
                syncedLyricsList
            } else if case .plainOnly(let candidate) = appState.lyricsStatus {
                plainLyricsView(candidate)
            } else {
                emptyLyricsView
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpotifyDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var syncedLyricsList: some View {
        // Simple 3-line display: previous / CURRENT / next. Current always centered.
        // No scrolling, no jitter, no complex LazyVStack. Clean and elegant.
        VStack(alignment: .leading, spacing: 6) {
            // Previous line
            if let prev = appState.snapshot.previous.last {
                Text(prev.text)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SpotifyDesign.secondaryText.opacity(0.50))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onHover { h in if h { hoveredLineID = prev.id } else { hoveredLineID = nil } }
                    .onTapGesture { appState.explain(line: prev) }
            } else {
                Spacer().frame(height: 16)
            }

            // Current line — always present, always centered visually
            if let current = appState.snapshot.current {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(SpotifyDesign.green)
                            .frame(width: 3, height: 20)
                            .padding(.trailing, 8)
                        Text(current.text)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(SpotifyDesign.mutedGreen)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(current.id)
                            .transition(.opacity)
                    }
                    // Chinese translation
                    if let translation = appState.currentTranslation {
                        Text(translation)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(SpotifyDesign.secondaryText.opacity(0.75))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 11)
                            .transition(.opacity)
                    }
                    // Explain button always occupies space (no height change on hover).
                    // Visibility controlled by opacity so the VStack never resizes.
                    HStack {
                        Spacer()
                        Button("Explain") { appState.explain(line: current) }
                            .buttonStyle(PanelButtonStyle())
                    }
                    .opacity(hoveredLineID == current.id ? 1 : 0)
                    .allowsHitTesting(hoveredLineID == current.id)
                    .animation(.easeOut(duration: 0.12), value: hoveredLineID)
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoveredLineID = hovering ? current.id : nil
                }
            } else {
                Text("♪ Waiting for lyrics…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SpotifyDesign.secondaryText)
            }

            // Next line — in Live mode, show the in-progress partial as a
            // ghost line so the user sees real-time progress instead of
            // staring at the previous committed sentence for 5+ seconds while
            // the recognizer waits for a full sentence boundary.
            if let next = appState.snapshot.next.first {
                Text(next.text)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SpotifyDesign.secondaryText.opacity(0.50))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onHover { h in if h { hoveredLineID = next.id } else { hoveredLineID = nil } }
                    .onTapGesture { appState.explain(line: next) }
            } else if appState.isLiveTranscribing, let partial = appState.livePartialText, !partial.isEmpty {
                Text(partial + "…")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SpotifyDesign.secondaryText.opacity(0.45))
                    .italic()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                Spacer().frame(height: 16)
            }
        }
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.22), value: appState.snapshot.current?.id)
    }

    private var emptyLyricsView: some View {
        Group {
            if appState.lyricsLoadingState == .unsupportedContent {
                UnsupportedContentCard(track: appState.playback.track)
            } else if appState.lyricsLoadingState == .instrumental {
                InstrumentalCard()
            } else if appState.isLiveTranscribing {
                LiveTranscriptionCard(partial: appState.livePartialText)
            } else if appState.isLyricsSearchActive {
                SearchingCard(
                    title: stageTitle,
                    subtitle: stageSubtitle,
                    stageIndex: stageProgress.current,
                    totalStages: stageProgress.total
                )
            } else if appState.lyricsNeedsUserAction {
                NeedsHelpCard(
                    isPodcast: appState.playback.track?.contentKind == .episode,
                    message: appState.lyricsRecoveryMessage,
                    transcriptionError: appState.podcastTranscriptionError,
                    isTranscribing: appState.isTranscribingPodcast,
                    onImport: importLRC,
                    onPaste: pasteLyrics,
                    onTranscribe: transcribePodcastAudio,
                    onRetry: { appState.retryLyrics() }
                )
            } else {
                IdleCard(message: appState.lyricsRecoveryMessage)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.18), value: appState.lyricsLoadingState)
    }

    private func plainLyricsView(_ candidate: LyricsCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SpotifyDesign.green)
                Text("Unsynced lyrics found — estimating timing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SpotifyDesign.green)
            }
            ScrollView {
                Text(candidate.plainLyrics ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(SpotifyDesign.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 130)
            HStack(spacing: 6) {
                Button("Import synced .lrc") { importLRC() }
                Button("Paste lyrics") { pasteLyrics() }
            }
            .buttonStyle(PanelButtonStyle())
        }
    }

    // MARK: - Stage helpers

    private var stageTitle: String {
        switch appState.lyricsLoadingState {
        case .waitingForStableTrack: return "Preparing search"
        case .checkingCache: return "Checking cache"
        case .searchingPrimarySource: return "Searching public sources"
        case .searchingFallbackSources: return "Trying another source"
        case .aiRewritingIdentity: return "AI translating song info"
        case .aiSearchingWithHints: return "Re-searching with AI hints"
        case .aiGeneratingLyrics: return "AI generating synced lyrics"
        case .aiAssistedSearch: return "AI assisted search"
        case .failedRecoverable: return "Lyric source slow"
        default: return "Looking for lyrics"
        }
    }

    private var stageSubtitle: String {
        switch appState.lyricsLoadingState {
        case .waitingForStableTrack:
            return "Waiting for full track details from Spotify."
        case .checkingCache:
            return "Looking in your local cache first."
        case .searchingPrimarySource:
            return "Querying LRCLIB & NetEase with the title and artist."
        case .searchingFallbackSources:
            return "Trying alternate names, simplified/traditional, and stripped variants."
        case .aiRewritingIdentity:
            return "Asking AI for the song's official Chinese / romanized names."
        case .aiSearchingWithHints:
            return "Re-querying public sources with the AI suggested names."
        case .aiGeneratingLyrics:
            return "AI is producing a synced .lrc aligned to this track's duration."
        case .aiAssistedSearch:
            return "Falling back to AI based discovery."
        case .failedRecoverable:
            return appState.lyricsRecoveryMessage
        default:
            return appState.lyricsRecoveryMessage
        }
    }

    private var stageProgress: (current: Int, total: Int) {
        switch appState.lyricsLoadingState {
        case .waitingForStableTrack: return (1, 5)
        case .checkingCache: return (2, 5)
        case .searchingPrimarySource: return (3, 5)
        case .searchingFallbackSources: return (3, 5)
        case .aiRewritingIdentity: return (4, 5)
        case .aiSearchingWithHints: return (4, 5)
        case .aiGeneratingLyrics: return (5, 5)
        case .aiAssistedSearch: return (4, 5)
        case .failedRecoverable: return (3, 5)
        default: return (1, 5)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.playback.track?.contentKind.supportsLyrics != false {
                HStack(spacing: 4) {
                    Text("Offset \(String(format: "%.1fs", Double(appState.currentOffsetMs) / 1000))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SpotifyDesign.secondaryText)
                        .monospacedDigit()
                    Spacer()
                    Button("-0.5") { appState.adjustOffset(by: -500) }
                    Button("-0.1") { appState.adjustOffset(by: -100) }
                    Button(action: { appState.resetOffset() }) {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .help("Reset offset")
                    Button("+0.1") { appState.adjustOffset(by: 100) }
                    Button("+0.5") { appState.adjustOffset(by: 500) }
                }
                .buttonStyle(PanelButtonStyle())
            }

            HStack(spacing: 6) {
                Button(action: { appState.showSettings() }) {
                    Label("Settings", systemImage: "gearshape")
                }
                Button(action: { appState.showAISettings() }) {
                    Label("AI", systemImage: "sparkles")
                }
                Spacer()
                Button(action: { appState.refreshNow(forceLyrics: appState.playback.track?.contentKind.supportsLyrics != false) }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(PanelButtonStyle())
        }
    }

    private func distance(for line: LyricLine) -> Int {
        guard let current = appState.snapshot.current,
              let currentIndex = appState.lyricsLines.firstIndex(where: { $0.id == current.id }),
              let lineIndex = appState.lyricsLines.firstIndex(where: { $0.id == line.id })
        else { return 3 }
        return abs(lineIndex - currentIndex)
    }

    @ViewBuilder
    private var learningBlock: some View {
        if appState.isLearningLoading {
            learningShell(title: appState.learningLine ?? "Explain this line") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Explaining this line...")
                        .foregroundStyle(SpotifyDesign.secondaryText)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 220, height: 12)
                }
            }
        } else if let error = appState.learningError {
            learningShell(title: appState.learningLine ?? "Explain this line") {
                Text(error)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let note = appState.learningNote {
            learningShell(title: "Explain this line") {
                VStack(alignment: .leading, spacing: 7) {
                    LabelText("Original", note.line)
                    LabelText("Meaning in context", note.meaningInContext)
                    LabelText("Natural Chinese", note.naturalChinese)
                    if !note.slangOrIdiom.isEmpty {
                        LabelText("Slang / Idiom", note.slangOrIdiom.joined(separator: "; "))
                    }
                    if let culture = note.cultureNote, !culture.isEmpty {
                        LabelText("Culture note", culture)
                    }
                    if !note.examples.isEmpty {
                        LabelText("Examples", note.examples.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                    }
                    if let caution = note.caution, !caution.isEmpty {
                        LabelText("Careful", caution, color: .orange)
                    }
                }
            }
        }
    }

    private func learningShell<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Explaining")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SpotifyDesign.green)
                Spacer()
                Text(TextNormalizer.boundedMenuText(title, maxCharacters: 28))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SpotifyDesign.secondaryText)
                Button("×") { appState.clearLearningNote() }
                    .buttonStyle(IconPanelButtonStyle())
                    .accessibilityLabel("Close explanation")
            }
            ScrollView {
                content()
                    .font(.system(size: 12))
                    .foregroundStyle(SpotifyDesign.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(SpotifyDesign.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeOut(duration: 0.18), value: appState.learningNote)
    }

    @ViewBuilder
    private var footer: some View {
        if let candidate = appState.currentCandidate, appState.settings.showLyricsSource {
            HStack(spacing: 6) {
                if candidate.source.lowercased().contains("ai") {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SpotifyDesign.green)
                }
                Text(footerText)
                    .font(.system(size: 11))
                    .foregroundStyle(SpotifyDesign.secondaryText)
                Spacer()
            }
        }
    }

    private var statusText: String {
        switch appState.lyricsStatus {
        case .idle:
            return "Open Spotify to start lyrics"
        case .loading:
            return loadingStatusText
        case .ready:
            return appState.playback.isPlaying ? "Playing" : "Paused"
        case .notFound(let message):
            return message
        case .plainOnly:
            return "Unsynced lyrics found. Import .lrc for timing."
        case .lowConfidence(let confidence):
            return "Possible lyrics found, but confidence is \(Int(confidence * 100))%."
        case .offlineUsingCache:
            return "Offline — using cached lyrics"
        }
    }

    private var loadingStatusText: String {
        switch appState.lyricsLoadingState {
        case .waitingForStableTrack:
            return "Preparing lyrics search..."
        case .checkingCache:
            return "Checking cached lyrics..."
        case .searchingPrimarySource:
            return "Searching lyrics..."
        case .searchingFallbackSources:
            return "Trying another source..."
        case .aiAssistedSearch:
            return "Using AI assisted search..."
        case .unsupportedContent:
            return "Unsupported Spotify content"
        default:
            return appState.lyricsRecoveryMessage
        }
    }

    private var footerText: String {
        guard appState.settings.showLyricsSource else { return "" }
        if let candidate = appState.currentCandidate {
            return "Source: \(candidate.source) · Confidence: \(Int(candidate.confidence * 100))%"
        }
        return "Source: Waiting · Confidence: --"
    }

    private func importLRC() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["lrc", "vtt", "srt", "txt"].compactMap { .init(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.importLRC(from: url)
        }
    }

    private func pasteLyrics() {
        appState.pasteLyricsFromClipboard()
    }

    private func transcribePodcastAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["mp3", "m4a", "mp4", "wav", "webm"].compactMap { .init(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.transcribePodcastAudio(from: url)
        }
    }
}

private struct SearchingCard: View {
    let title: String
    let subtitle: String
    let stageIndex: Int
    let totalStages: Int

    @State private var spin = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 2.5)
                    .frame(width: 32, height: 32)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(SpotifyDesign.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: spin)
            }
            .onAppear { spin = true }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SpotifyDesign.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(SpotifyDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    ForEach(1...totalStages, id: \.self) { i in
                        Capsule()
                            .fill(i <= stageIndex ? SpotifyDesign.green : Color.white.opacity(0.12))
                            .frame(width: i == stageIndex ? 18 : 10, height: 3)
                            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: stageIndex)
                    }
                }
                .padding(.top, 2)
            }
            .id("\(title)|\(stageIndex)")
            .transition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }
}

private struct NeedsHelpCard: View {
    let isPodcast: Bool
    let message: String
    let transcriptionError: String?
    let isTranscribing: Bool
    let onImport: () -> Void
    let onPaste: () -> Void
    let onTranscribe: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isPodcast ? "Need podcast transcript" : "Couldn't auto-match this song")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SpotifyDesign.primaryText)
                    Text(message.isEmpty ? fallbackMessage : message)
                        .font(.system(size: 11))
                        .foregroundStyle(SpotifyDesign.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let transcriptionError, !transcriptionError.isEmpty {
                        Text(transcriptionError)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                Button(action: onImport) {
                    Label(isPodcast ? "Import" : "Import .lrc", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelButtonStyle())
                .help(isPodcast ? "Import transcript (.lrc, .vtt, .srt, .txt)" : "Import synced .lrc")
                Button(action: onPaste) {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelButtonStyle())
                if isPodcast {
                    Button(action: onTranscribe) {
                        Label(isTranscribing ? "Working" : "Transcribe", systemImage: "waveform.badge.mic")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PanelButtonStyle())
                    .disabled(isTranscribing)
                }
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelButtonStyle())
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }

    private var fallbackMessage: String {
        isPodcast
            ? "Searches public transcript sources first, then uses timed AI transcription when audio is available."
            : "We tried public sources and AI without finding reliable lyrics."
    }
}

private struct InstrumentalCard: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(SpotifyDesign.green.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SpotifyDesign.mutedGreen)
                    .scaleEffect(pulse ? 1.05 : 0.95)
                    .opacity(pulse ? 1.0 : 0.7)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
            }
            .onAppear { pulse = true }

            VStack(alignment: .leading, spacing: 3) {
                Text("Instrumental")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SpotifyDesign.primaryText)
                Text("Sit back and vibe — no lyrics to sync.")
                    .font(.system(size: 11))
                    .foregroundStyle(SpotifyDesign.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }
}

private struct UnsupportedContentCard: View {
    let track: PlaybackTrack?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Unsupported Spotify content")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SpotifyDesign.primaryText)
                Text(track.map { "\($0.contentKind.label): \($0.title)" } ?? "This Spotify item does not provide enough music metadata for synced lyrics.")
                    .font(.system(size: 11))
                    .foregroundStyle(SpotifyDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }
}

private struct IdleCard: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 18))
                .foregroundStyle(SpotifyDesign.secondaryText.opacity(0.6))
            Text(message.isEmpty ? "Open Spotify to start lyrics" : message)
                .font(.system(size: 12))
                .foregroundStyle(SpotifyDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }
}

private struct LiveTranscriptionCard: View {
    let partial: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SpotifyDesign.green)
                Text("Live transcription")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SpotifyDesign.green)
                Spacer(minLength: 0)
            }
            if let partial, !partial.isEmpty {
                Text(partial)
                    .font(.system(size: 13))
                    .foregroundStyle(SpotifyDesign.primaryText.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Listening to system audio…")
                    .font(.system(size: 12))
                    .foregroundStyle(SpotifyDesign.secondaryText)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(configuration.isPressed ? SpotifyDesign.mutedGreen.opacity(0.85) : SpotifyDesign.green)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct LyricLineRow: View {
    let line: LyricLine
    let isCurrent: Bool
    let distance: Int
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onExplain: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack(alignment: .leading) {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(SpotifyDesign.green)
                        .frame(width: 2, height: 18)
                        .offset(x: -10)
                        .transition(.opacity)
                }
                Text(line.text)
                    .font(.system(size: fontSize, weight: isCurrent ? .semibold : .regular, design: .rounded))
                    .tracking(isCurrent ? -0.2 : 0)
                    .lineSpacing(2)
                    .foregroundStyle(isCurrent ? SpotifyDesign.mutedGreen : SpotifyDesign.primaryText)
                    .opacity(opacity)
                    .scaleEffect(isCurrent ? 1.015 : 1, anchor: .leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.spring(response: 0.36, dampingFraction: 0.82), value: isCurrent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Button("Explain") { onExplain() }
                    .buttonStyle(PanelButtonStyle())
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(PanelButtonStyle())
                .help("Copy this line")
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        // Note: NO .onTapGesture here. Tapping a row used to trigger Explain, which
        // means scrolling or accidental clicks could fire an AI request. Now only
        // the explicit "Explain" button does it.
    }

    private var fontSize: CGFloat {
        if isCurrent { return 16 }
        if distance == 1 { return 13 }
        if distance == 2 { return 12 }
        return 11.5
    }

    private var opacity: Double {
        if isCurrent { return 1 }
        if distance == 1 { return 0.62 }
        if distance == 2 { return 0.34 }
        if distance == 3 { return 0.16 }
        return 0.08
    }
}
