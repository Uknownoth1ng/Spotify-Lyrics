import Foundation

final class CompositeLyricsSearchService: LyricsSearching, @unchecked Sendable {
    private let lrclib: LyricsSearching
    private let netease: LyricsSearching

    init(lrclib: LyricsSearching = LRCLibService(), netease: LyricsSearching = NetEaseLyricsService()) {
        self.lrclib = lrclib
        self.netease = netease
    }

    /// Run both providers in parallel and pick the best result. LRCLib has higher
    /// English-language coverage but cold-start responses are 6-9 s; NetEase is fast
    /// but unreliable from outside China. Running them concurrently means the slow
    /// provider can complete in the time the fast provider was already going to take.
    func bestLyrics(for track: PlaybackTrack) async throws -> LyricsCandidate {
        let providers = providers(for: track)
        let collected: (synced: LyricsCandidate?, plainOnly: LyricsCandidate?, low: Double, network: Bool) =
            await withTaskGroup(of: ProviderOutcome.self) { group in
                for provider in providers {
                    group.addTask {
                        do {
                            let candidate = try await provider.bestLyrics(for: track)
                            return .success(candidate)
                        } catch let error as LyricsSearchError {
                            return .failure(error)
                        } catch is CancellationError {
                            return .failure(.timedOut)
                        } catch {
                            return .failure(.network)
                        }
                    }
                }

                var bestSynced: LyricsCandidate?
                var bestPlainOnly: LyricsCandidate?
                var bestLowConfidence: Double = 0
                var sawNetworkError = false

                for await outcome in group {
                    switch outcome {
                    case .success(let candidate):
                        if candidate.confidence > (bestSynced?.confidence ?? 0) {
                            bestSynced = candidate
                        }
                        if candidate.confidence >= 0.94 {
                            group.cancelAll()
                            return (candidate, bestPlainOnly, bestLowConfidence, sawNetworkError)
                        }
                    case .failure(.plainOnly(let candidate)):
                        if candidate.confidence > (bestPlainOnly?.confidence ?? 0) {
                            bestPlainOnly = candidate
                        }
                    case .failure(.lowConfidence(let confidence)):
                        bestLowConfidence = max(bestLowConfidence, confidence)
                    case .failure(.network), .failure(.timedOut):
                        sawNetworkError = true
                    case .failure:
                        continue
                    }
                }
                return (bestSynced, bestPlainOnly, bestLowConfidence, sawNetworkError)
            }

        if let synced = collected.synced { return synced }
        if let plainOnly = collected.plainOnly { throw LyricsSearchError.plainOnly(plainOnly) }
        if collected.low > 0 { throw LyricsSearchError.lowConfidence(collected.low) }
        if collected.network { throw LyricsSearchError.network }
        throw LyricsSearchError.notFound
    }

    private func providers(for track: PlaybackTrack) -> [LyricsSearching] {
        // Order doesn't matter for parallel fan-out, but keep it deterministic so the
        // log lines stay readable.
        let isCJK = TextNormalizer.containsCJK(track.title) || TextNormalizer.containsCJK(track.artist)
        return isCJK ? [netease, lrclib] : [lrclib, netease]
    }

    private enum ProviderOutcome {
        case success(LyricsCandidate)
        case failure(LyricsSearchError)
    }
}
