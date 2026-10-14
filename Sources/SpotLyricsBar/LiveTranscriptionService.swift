import AVFoundation
import Foundation
import Speech

@MainActor
final class LiveTranscriptionService {
    enum LiveState { case idle, running, paused, error(String) }

    private(set) var state: LiveState = .idle
    private let captureService = SystemAudioCaptureService()
    private let settings: LLMSettingsStore
    private var accumulatedLines: [LyricLine] = []
    private var baseTimeMs: Int = 0

    private let sentenceBuffer = SentenceBuffer()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionEpoch: Int = 0
    /// Audio-clock millisecond at which the current recognition task started.
    /// Used to rotate the task before Apple's ~60s ceiling without a hard
    /// failure mid-sentence.
    private var recognitionTaskStartedAtMs: Int = 0
    /// Errors in a row from `recognitionTask` (excluding 1110/216). Reset on
    /// any successful partial. When the count exceeds a threshold we stop
    /// auto-restarting and surface the failure to the UI.
    private var consecutiveRecognizerErrors: Int = 0
    private var pcmFormat: AVAudioFormat?
    private var lastAudioTimeMs: Int = 0
    private var lastVoiceAudioTimeMs: Int = 0
    private var lastSilenceCheckAudioTimeMs: Int = 0
    private var lastPartialLogAtMs: Int = 0
    private var hasAuthorization = false
    private var localePreferences: [String] = ["en-US"]
    private(set) var activeLocale: String = "en-US"

    var onLinesUpdated: (([LyricLine]) -> Void)?
    var onPartialUpdated: ((String) -> Void)?

    init(settings: LLMSettingsStore) {
        self.settings = settings
    }

    /// Adjust the recognizer locale for the upcoming session. Call this BEFORE
    /// `start(playbackPositionMs:)`. The first identifier we can actually
    /// instantiate wins; the rest serve as fallbacks (e.g. zh-Hans → en-US for
    /// users whose macOS install has no Mandarin language pack).
    func configureLocales(preferences: [String]) {
        let fallback = "en-US"
        var seen = Set<String>()
        var ordered: [String] = []
        for id in preferences + [fallback] where !id.isEmpty {
            if seen.insert(id).inserted { ordered.append(id) }
        }
        localePreferences = ordered
    }

    var isConfigured: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func start(playbackPositionMs: Int) {
        guard case .idle = state else { return }
        baseTimeMs = playbackPositionMs
        accumulatedLines = []
        sentenceBuffer.reset()
        state = .running

        // SFSpeechRecognizer.requestAuthorization invokes its completion on a
        // TCC dispatch queue, NOT MainActor. Under Swift 6 strict concurrency
        // an inferred @MainActor closure here trips
        // swift_task_isCurrentExecutorWithFlagsImpl → dispatch_assert_queue_fail
        // → SIGTRAP, which the user sees as "permission dialog → click allow →
        // crash". Declare the closure as @Sendable nonisolated and hop to
        // MainActor inside via Task.
        let handler: @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.hasAuthorization = (status == .authorized)
                if !self.hasAuthorization {
                    self.state = .error("Speech recognition not authorized")
                    NSLog("SpotLyrics Live: speech auth denied: %@", String(describing: status))
                    return
                }
                self.beginCapture()
            }
        }
        SFSpeechRecognizer.requestAuthorization(handler)
    }

    func pause() {
        guard case .running = state else { return }
        captureService.stopCapture()
        captureService.onPCMChunk = nil
        endRecognition(flush: true)
        state = .paused
    }

    func resume(playbackPositionMs: Int) {
        guard case .paused = state else { return }
        baseTimeMs = playbackPositionMs
        state = .running
        beginCapture()
    }

    func stop() {
        captureService.stopCapture()
        captureService.onPCMChunk = nil
        endRecognition(flush: true)
        state = .idle
    }

    func currentLRC() -> String? {
        guard accumulatedLines.count >= 2 else { return nil }
        return accumulatedLines.map { line in
            let ms = line.timeMs
            let min = ms / 60000
            let sec = (ms % 60000) / 1000
            let hundredths = (ms % 1000) / 10
            return "[\(String(format: "%02d:%02d.%02d", min, sec, hundredths))]\(line.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Pipeline

    private func beginCapture() {
        do {
            try captureService.startCapture()
        } catch {
            state = .error("Audio capture failed: \(error.localizedDescription)")
            NSLog("SpotLyrics Live: capture start failed: %@", String(describing: error))
            return
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            state = .error("Failed to create audio format")
            return
        }
        pcmFormat = format

        startRecognition()

        captureService.onPCMChunk = { [weak self] samples, audioTimeMs, isVoice in
            Task { @MainActor [weak self] in
                self?.handlePCM(samples: samples, audioTimeMs: audioTimeMs, isVoice: isVoice)
            }
        }
        NSLog("SpotLyrics Live: streaming pipeline armed")
    }

    private func startRecognition() {
        let speech = makeRecognizer()
        guard let speech else {
            state = .error("Speech recognizer unavailable")
            NSLog("SpotLyrics Live: no usable recognizer for any of %@", localePreferences as NSArray)
            return
        }
        recognizer = speech
        activeLocale = speech.locale.identifier

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Only force on-device when the recognizer actually advertises it.
        // Setting `requiresOnDeviceRecognition = true` on a locale whose offline
        // model isn't installed makes recognitionTask fail immediately with no
        // useful diagnostic and the UI hangs in "loading" forever — fall back
        // to cloud recognition for those locales.
        request.requiresOnDeviceRecognition = speech.supportsOnDeviceRecognition
        recognitionRequest = request

        recognitionEpoch += 1
        let myEpoch = recognitionEpoch

        // recognitionTask invokes its result handler on a Speech-internal
        // dispatch queue, NOT MainActor. Same trap as requestAuthorization:
        // an inferred @MainActor closure here would crash. Use an explicit
        // @Sendable nonisolated handler and hop to MainActor inside.
        let resultHandler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { [weak self] result, error in
            // SFSpeechRecognitionResult is not Sendable, so we extract the
            // string here on the recognizer's queue before hopping. The error
            // is bridged to NSError (which is Sendable) for the same reason.
            let partial: String? = result?.bestTranscription.formattedString
            let nsError: NSError? = error as NSError?
            Task { @MainActor [weak self] in
                guard let self, myEpoch == self.recognitionEpoch else { return }
                if let partial {
                    self.consecutiveRecognizerErrors = 0
                    self.onPartialUpdated?(partial)
                    if self.lastAudioTimeMs - self.lastPartialLogAtMs >= 3000 {
                        self.lastPartialLogAtMs = self.lastAudioTimeMs
                        NSLog("SpotLyrics Live: partial → \"%@\"", partial)
                    }
                    let anchor = self.lastVoiceAudioTimeMs > 0 ? self.lastVoiceAudioTimeMs : self.lastAudioTimeMs
                    if let completed = self.sentenceBuffer.updatePartial(partial, atAudioTimeMs: anchor) {
                        self.commit(completed)
                        // Do NOT restart the recognition task here. Apple's
                        // recognizer takes 300-800ms to start producing partials
                        // again after a fresh task — speech during that window
                        // is dropped. SentenceBuffer now tracks the committed
                        // prefix of the cumulative partial, so a single task
                        // can serve many sentences and we only rotate it on
                        // error or to stay under the ~60s task ceiling.
                    }
                }
                if let nsError {
                    // 1110 (no speech detected) and 216 (canceled) are normal
                    // mid-stream events. Other errors usually mean the task
                    // hit the time ceiling or hit transient infrastructure
                    // trouble — we auto-rotate up to a few times before
                    // giving up so the user doesn't permanently lose live
                    // captions on a long episode.
                    if nsError.code != 1110 && nsError.code != 216 {
                        NSLog("SpotLyrics Live: recognizer error: %@ (code=%d) — auto-restarting", nsError.localizedDescription, nsError.code)
                        if case .running = self.state {
                            self.consecutiveRecognizerErrors += 1
                            if self.consecutiveRecognizerErrors <= 5 {
                                self.sentenceBuffer.recognizerWillRestart()
                                self.restartRecognition()
                            } else {
                                self.state = .error("Speech recognition failed: \(nsError.localizedDescription)")
                            }
                        }
                    } else {
                        self.consecutiveRecognizerErrors = 0
                    }
                }
            }
        }
        recognitionTask = speech.recognitionTask(with: request, resultHandler: resultHandler)
        recognitionTaskStartedAtMs = lastAudioTimeMs
        NSLog("SpotLyrics Live: recognizer task started (locale=%@, epoch=%d, onDevice=%@)", activeLocale, myEpoch, speech.supportsOnDeviceRecognition ? "yes" : "no")
    }

    private func makeRecognizer() -> SFSpeechRecognizer? {
        for identifier in localePreferences {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else { continue }
            if recognizer.isAvailable { return recognizer }
        }
        return nil
    }

    private func restartRecognition() {
        endRecognition(flush: false)
        startRecognition()
    }

    private func endRecognition(flush: Bool) {
        recognitionEpoch += 1
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        if flush, let completed = sentenceBuffer.flush() {
            commit(completed)
        }
    }

    private func handlePCM(samples: [Float], audioTimeMs: Int, isVoice: Bool) {
        lastAudioTimeMs = audioTimeMs + Int(Double(samples.count) / 16.0)
        guard let format = pcmFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = buffer.floatChannelData
        else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channelData[0].update(from: base, count: samples.count)
            }
        }
        recognitionRequest?.append(buffer)

        if isVoice {
            lastVoiceAudioTimeMs = lastAudioTimeMs
        } else if audioTimeMs - lastSilenceCheckAudioTimeMs >= 200 {
            lastSilenceCheckAudioTimeMs = audioTimeMs
            if let completed = sentenceBuffer.markSilence(atAudioTimeMs: audioTimeMs) {
                commit(completed)
                // Do NOT restart on a silence-driven commit either — see the
                // comment in the recognition handler. Long pauses are exactly
                // when restarts hurt most, because the user just stopped
                // talking and is about to start again.
            }
        }

        // Rotate the recognition task before Apple's hard ~60-second
        // single-task limit kicks in. Doing it well before the limit means
        // the new task is already producing partials by the time the user
        // starts the next utterance, instead of cold-starting mid-sentence.
        if recognitionTaskStartedAtMs > 0,
           lastAudioTimeMs - recognitionTaskStartedAtMs >= 50_000,
           lastAudioTimeMs - lastVoiceAudioTimeMs >= 200 {
            NSLog("SpotLyrics Live: rotating recognition task before 60s ceiling")
            sentenceBuffer.recognizerWillRestart()
            restartRecognition()
        }
    }

    private func commit(_ sentence: SentenceBuffer.CompletedSentence) {
        let absoluteMs = baseTimeMs + sentence.startMs
        let line = LyricLine(timeMs: absoluteMs, text: sentence.text)
        if let last = accumulatedLines.last,
           last.text == line.text, abs(last.timeMs - line.timeMs) < 1500 {
            return
        }
        accumulatedLines.append(line)
        accumulatedLines.sort { $0.timeMs < $1.timeMs }
        NSLog("SpotLyrics Live: sentence @%dms — %@", absoluteMs, line.text)
        onLinesUpdated?(accumulatedLines)
    }
}
