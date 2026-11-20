import Foundation

/// Remove repeated recognition of the same passage, never repetition at a later time.
/// Work before paragraph assembly so unique words retain their original timestamps.
public enum TranscriptDeduplicator {
    private static let timeTolerance = 0.8
    private static let minimumWords = 4
    private static let minimumCharacters = 16

    public static func clean(wordsByTrack: [AudioTrack: [TimedWord]],
                             turnsByTrack: [AudioTrack: [SpeakerTurn]] = [:]) -> [AudioTrack: [TimedWord]] {
        var result = wordsByTrack
        for track in [AudioTrack.system, .microphone] {
            guard let words = result[track] else { continue }
            result[track] = removingDuplicates(from: words, matching: words, sameTrack: true,
                                                turns: turnsByTrack[track] ?? [])
        }
        // Meeting audio has the remote speaker labels. A matching microphone passage is
        // usually speaker playback leaking into the microphone; keep the direct copy.
        if let system = result[.system], let microphone = result[.microphone] {
            result[.microphone] = removingDuplicates(from: microphone, matching: system, sameTrack: false, turns: [])
        }
        return result
    }

    private struct Token {
        let text: String
        let word: Int
        let start: Double
        let end: Double
        var middle: Double { start + (end - start) / 2 }
    }

    private struct TokenizedWords {
        var tokens: [Token] = []
        var ranges: [Range<Int>] = []

        init(_ words: [TimedWord]) {
            for (index, word) in words.enumerated() {
                let start = tokens.count
                if word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start,
                   word.end < Double(Int.max) / 2 {
                    let normalized = word.text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                       locale: Locale(identifier: "en_US_POSIX"))
                    for text in normalized.components(separatedBy: .alphanumerics.inverted) where !text.isEmpty {
                        tokens.append(Token(text: text, word: index, start: word.start, end: word.end))
                    }
                }
                ranges.append(start..<tokens.count)
            }
        }
    }

    private struct Key: Hashable {
        let text: String
        let second: Int
    }

    private static func removingDuplicates(from words: [TimedWord], matching reference: [TimedWord],
                                           sameTrack: Bool, turns: [SpeakerTurn]) -> [TimedWord] {
        let target = TokenizedWords(words), source = TokenizedWords(reference)
        var index: [Key: [Int]] = [:]
        for (position, token) in source.tokens.enumerated() {
            index[Key(text: token.text, second: Int(floor(token.middle))), default: []].append(position)
        }
        var removed: Set<Int> = []
        for (position, token) in target.tokens.enumerated() where !removed.contains(token.word) {
            let second = Int(floor(token.middle))
            let candidates = (-1...1).flatMap { index[Key(text: token.text, second: second + $0)] ?? [] }
            for candidate in candidates {
                let first = source.tokens[candidate]
                if sameTrack && (first.word >= token.word || removed.contains(first.word)) { continue }
                var count = 0, characters = 0
                while position + count < target.tokens.count, candidate + count < source.tokens.count {
                    let a = target.tokens[position + count], b = source.tokens[candidate + count]
                    guard a.text == b.text, abs(a.middle - b.middle) <= timeTolerance,
                          !removed.contains(a.word) else { break }
                    if sameTrack && (b.word >= token.word || removed.contains(b.word)) { break }
                    if count > 0 {
                        let previousA = target.tokens[position + count - 1], previousB = source.tokens[candidate + count - 1]
                        if a.start - previousA.end > 1.8 || b.start - previousB.end > 1.8 { break }
                    }
                    count += 1
                    characters += a.text.count
                }
                guard count >= minimumWords, characters >= minimumCharacters else { continue }
                let aEnd = target.tokens[position + count - 1].end
                let bEnd = source.tokens[candidate + count - 1].end
                let shorterDuration = min(aEnd - token.start, bEnd - first.start)
                let overlap = min(aEnd, bEnd) - max(token.start, first.start)
                guard shorterDuration >= 0.25, overlap >= shorterDuration * 0.5 else { continue }
                if sameTrack {
                    // Do not collapse a genuine exchange between different voices.
                    let voices = Set(turns.filter { $0.start < max(aEnd, bEnd) && $0.end > min(token.start, first.start) }.map(\.speaker))
                    guard voices.count <= 1 else { continue }
                }
                let matched = position..<(position + count)
                for word in token.word...target.tokens[position + count - 1].word {
                    let range = target.ranges[word]
                    // A fallback recognizer result may contain a whole sentence. Only remove
                    // it if every token matched; never discard its unmatched prefix or suffix.
                    if !range.isEmpty, range.lowerBound >= matched.lowerBound, range.upperBound <= matched.upperBound {
                        removed.insert(word)
                    }
                }
                if removed.contains(token.word) { break }
            }
        }
        guard !removed.isEmpty else { return words }
        var previousWordRemoved = false
        return words.enumerated().compactMap { index, word in
            let isLexical = !target.ranges[index].isEmpty || word.text.rangeOfCharacter(from: .alphanumerics) != nil
            let discard = removed.contains(index) || (!isLexical && previousWordRemoved)
            if isLexical { previousWordRemoved = discard }
            return discard ? nil : word
        }
    }
}
