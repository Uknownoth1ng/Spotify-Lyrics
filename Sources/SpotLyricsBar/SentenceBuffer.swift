import Foundation

/// Detects complete-sentence boundaries from a streaming partial transcript.
///
/// Apple's `SFSpeechRecognitionTask` emits each `partial` as the cumulative
/// text for the entire task lifetime, not just the latest utterance. This
/// buffer tracks the prefix already committed so we can keep one task running
/// across many sentences — restarting the recognizer per sentence costs
/// 300-800ms of cold-start time during which speech is lost, which is the
/// main reason captions visibly lag behind the speaker.
///
/// A sentence boundary is taken when ANY trigger fires on the *new* part of
/// the partial (everything past `committedPrefix`):
///   1. Trailing terminal punctuation (. ? ! 。 ？ ！)
///   2. Clause punctuation (, ; ， ；) once the unspoken buffer is long
///      enough to be useful as a standalone caption
///   3. Silence/pause longer than `silenceThresholdMs`
///   4. Buffer text length exceeds `maxBufferChars`
final class SentenceBuffer {
    struct CompletedSentence: Equatable {
        let text: String
        let startMs: Int
        let endMs: Int
    }

    /// Pause before we treat the in-progress partial as done. Tuned for
    /// fast-paced podcast dialogue.
    var silenceThresholdMs: Int = 350
    /// Hard cap on the in-progress partial length before forcing a commit.
    var maxBufferChars: Int = 60

    /// The cumulative partial as Apple last reported it — used to detect
    /// when the recognizer has rewritten earlier text (it sometimes does
    /// when refining transcription) so we can re-anchor the prefix.
    private var lastFullPartial: String = ""
    /// Everything we've already emitted as completed sentences. The "current
    /// in-progress sentence" is whatever follows this in the cumulative
    /// partial.
    private var committedPrefix: String = ""
    private var pendingStartMs: Int?
    private var lastVoiceTimeMs: Int = 0

    var pendingText: String {
        unspokenText(after: committedPrefix, in: lastFullPartial)
    }

    func reset() {
        lastFullPartial = ""
        committedPrefix = ""
        pendingStartMs = nil
        lastVoiceTimeMs = 0
    }

    /// Called when the long-running recognition task is being torn down and
    /// replaced (e.g. Apple's ~1-minute single-task ceiling). The next call
    /// to `updatePartial` will be against a fresh cumulative partial — clear
    /// the prefix so we don't accidentally swallow new speech as already
    /// committed.
    func recognizerWillRestart() {
        lastFullPartial = ""
        committedPrefix = ""
    }

    func updatePartial(_ partial: String, atAudioTimeMs: Int) -> CompletedSentence? {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // The recognizer occasionally refines past text. If the new partial no
        // longer starts with our committed prefix, fall back to a more lenient
        // suffix-based reconciliation: keep whatever portion of `committedPrefix`
        // still appears as a prefix of the new partial.
        if !trimmed.hasPrefix(committedPrefix) {
            committedPrefix = longestCommonPrefix(committedPrefix, trimmed)
        }
        lastFullPartial = trimmed

        let pending = unspokenText(after: committedPrefix, in: trimmed)
        if pending.isEmpty { return nil }

        if pendingStartMs == nil {
            // Anchor sentence start a little before the recognizer's first
            // partial; the model takes ~0.6-0.8s to commit a word.
            pendingStartMs = max(0, atAudioTimeMs - 800)
        }
        lastVoiceTimeMs = atAudioTimeMs

        if let last = pending.unicodeScalars.last,
           last == "." || last == "?" || last == "!"
            || last == "。" || last == "？" || last == "！" {
            return takeCompleted(endMs: atAudioTimeMs)
        }

        if pending.count >= 30,
           let last = pending.unicodeScalars.last,
           last == "," || last == ";" || last == "，" || last == "；" {
            return takeCompleted(endMs: atAudioTimeMs)
        }

        if pending.count > maxBufferChars {
            return takeCompleted(endMs: atAudioTimeMs)
        }

        return nil
    }

    func markSilence(atAudioTimeMs: Int) -> CompletedSentence? {
        let pending = unspokenText(after: committedPrefix, in: lastFullPartial)
        guard !pending.isEmpty, pendingStartMs != nil,
              atAudioTimeMs - lastVoiceTimeMs >= silenceThresholdMs
        else { return nil }
        return takeCompleted(endMs: atAudioTimeMs)
    }

    func flush() -> CompletedSentence? {
        let pending = unspokenText(after: committedPrefix, in: lastFullPartial)
        guard !pending.isEmpty, pendingStartMs != nil else { return nil }
        return takeCompleted(endMs: lastVoiceTimeMs)
    }

    private func takeCompleted(endMs: Int) -> CompletedSentence? {
        let pending = unspokenText(after: committedPrefix, in: lastFullPartial)
        guard let start = pendingStartMs, !pending.isEmpty else { return nil }
        let text = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        committedPrefix = lastFullPartial
        pendingStartMs = nil
        return CompletedSentence(text: text, startMs: start, endMs: endMs)
    }

    private func unspokenText(after prefix: String, in full: String) -> String {
        guard full.hasPrefix(prefix) else {
            return full
        }
        let suffix = full.dropFirst(prefix.count)
        // Trim leading whitespace that always sits between the committed
        // prefix and the new spoken material.
        return String(suffix).trimmingCharacters(in: .whitespaces)
    }

    private func longestCommonPrefix(_ a: String, _ b: String) -> String {
        var idx = a.startIndex
        var jdx = b.startIndex
        while idx < a.endIndex, jdx < b.endIndex, a[idx] == b[jdx] {
            idx = a.index(after: idx)
            jdx = b.index(after: jdx)
        }
        return String(a[..<idx])
    }
}
