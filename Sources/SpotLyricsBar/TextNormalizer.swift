import Foundation

enum TextNormalizer {
    private static let noisePatterns = [
        #"\((?i:explicit|remaster(?:ed)?|radio edit|live|acoustic|sped up|speed up|slowed|instrumental|mono|stereo|deluxe).{0,40}?\)"#,
        #"\[(?i:explicit|remaster(?:ed)?|radio edit|live|acoustic|sped up|speed up|slowed|instrumental|mono|stereo|deluxe).{0,40}?\]"#,
        #"(?i)\s+-\s+(remaster(?:ed)?|radio edit|live|acoustic|sped up|speed up|slowed|instrumental).*$"#
    ]

    static func normalize(_ text: String) -> String {
        var value = halfWidth(text)
        value = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        value = value.replacingOccurrences(of: #"(?i)\b(feat\.?|ft\.?|featuring)\b"#, with: " featuring ", options: .regularExpression)
        for pattern in noisePatterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: #"[\p{P}\p{S}&&[^&]]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Comparison fingerprint: width-normalized, lower-cased, simplified-Chinese collapsed,
    /// punctuation stripped. Used so 陳潔儀 / 陈洁仪 / Kit Chan match against each other after
    /// optional transliteration.
    static func fingerprint(_ text: String) -> String {
        let simplified = toSimplified(halfWidth(text))
        let folded = simplified.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var value = folded
        value = value.replacingOccurrences(of: #"(?i)\b(feat\.?|ft\.?|featuring)\b"#, with: " ", options: .regularExpression)
        for pattern in noisePatterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: #"[\p{P}\p{S}&&[^&]]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func conservativeSearchTitle(_ text: String) -> String {
        let widthFixed = halfWidth(text)
        if containsCJK(widthFixed) {
            return widthFixed
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalize(widthFixed)
    }

    static func cacheKey(_ text: String) -> String {
        let base = fingerprint(text)
        if !base.isEmpty { return base }
        return normalize(text)
            .replacingOccurrences(of: #"[^a-z0-9\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func boundedMenuText(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 4 else { return String(text.prefix(max(0, maxCharacters))) }
        if text.count <= maxCharacters { return text }
        let end = text.index(text.startIndex, offsetBy: maxCharacters - 1)
        return String(text[..<end]) + "…"
    }

    /// CJK-aware similarity: Traditional and Simplified Chinese collapse to the same
    /// fingerprint, so 富士山下 ↔ 富士山下 still scores 1.0 even when sources disagree.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let af = fingerprint(lhs)
        let bf = fingerprint(rhs)
        if !af.isEmpty, !bf.isEmpty {
            if af == bf { return 1 }
            if af.contains(bf) || bf.contains(af) { return 0.92 }
        }
        let a = normalize(lhs)
        let b = normalize(rhs)
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) {
            return 0.88
        }
        let distance = levenshtein(Array(a), Array(b))
        let maxLength = max(a.count, b.count)
        let normalScore = max(0, 1 - Double(distance) / Double(maxLength))
        if !af.isEmpty, !bf.isEmpty, af != bf {
            let fpDistance = levenshtein(Array(af), Array(bf))
            let fpMax = max(af.count, bf.count)
            let fpScore = max(0, 1 - Double(fpDistance) / Double(fpMax))
            return max(normalScore, fpScore)
        }
        return normalScore
    }

    static func stableTextHash(_ text: String) -> String {
        let scalars = normalize(text).unicodeScalars
        let value = scalars.reduce(UInt64(1_469_598_103_934_665_603)) { partial, scalar in
            (partial ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }
        return String(value, radix: 16)
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    /// Detects the dominant script of a string. We use this to pick the right
    /// speech-recognition locale for live podcast transcription — an English
    /// recognizer on a Mandarin podcast produces useless gibberish.
    enum DominantScript { case latin, hanSimplified, hanTraditional, japanese, korean }

    static func dominantScript(_ text: String) -> DominantScript {
        var hasHan = false
        var hasKana = false
        var hasHangul = false
        for scalar in text.unicodeScalars {
            if (0x3040...0x30FF).contains(scalar.value) { hasKana = true }
            else if (0xAC00...0xD7AF).contains(scalar.value) { hasHangul = true }
            else if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                hasHan = true
            }
        }
        if hasHangul { return .korean }
        if hasKana { return .japanese }
        if hasHan {
            // No reliable script test for Simplified vs Traditional from a short
            // string; fall back to whether the round-trip Hant→Hans changes it.
            let simplified = toSimplified(text)
            return simplified == text ? .hanSimplified : .hanTraditional
        }
        return .latin
    }

    static func toSimplified(_ text: String) -> String {
        guard containsCJK(text) else { return text }
        return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    static func toTraditional(_ text: String) -> String {
        guard containsCJK(text) else { return text }
        return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    static func halfWidth(_ text: String) -> String {
        text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
    }

    /// Splits an artist field that may contain multiple performers (",", "/", "&", "、", "，").
    static func splitArtists(_ artist: String) -> [String] {
        artist
            .components(separatedBy: CharacterSet(charactersIn: ",/&、，;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Strip parenthetical / bracketed segments. Use only when both the cleaned and
    /// original variants are searched, since CJK bracket text is sometimes the show name.
    static func stripBrackets(_ text: String) -> String {
        var value = text
        let patterns = [
            #"\s*\([^()]*\)\s*"#,
            #"\s*\[[^\[\]]*\]\s*"#,
            #"\s*（[^（）]*）\s*"#,
            #"\s*【[^【】]*】\s*"#,
            #"\s*「[^「」]*」\s*"#,
            #"\s*『[^『』]*』\s*"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
