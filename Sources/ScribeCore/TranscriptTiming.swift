import Foundation

/// Validate recognition against the audio actually supplied to the recognizer.
public enum TranscriptTiming {
    public static func recognitionWords(_ words: [TimedWord], fallback: TimedWord,
                                        within audio: SpeechWindow) -> [TimedWord] {
        guard audio.start.isFinite, audio.end.isFinite, audio.start >= 0, audio.end > audio.start else { return [] }
        let fallbackRange: SpeechWindow
        if fallback.start.isFinite, fallback.end.isFinite, fallback.end > fallback.start,
           fallback.end > audio.start, fallback.start < audio.end {
            fallbackRange = SpeechWindow(start: max(audio.start, fallback.start), end: min(audio.end, fallback.end))
        } else {
            fallbackRange = audio
        }
        // A whole-segment fallback preserves the text when individual word alignment is
        // unusable. Do not invent word boundaries by spreading words evenly over the clip.
        guard !words.isEmpty, words.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
                && $0.end >= fallbackRange.start && $0.start <= fallbackRange.end
        }) else {
            let text = fallback.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? words.map(\.text).joined() : fallback.text
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? []
                : [TimedWord(text: text, start: fallbackRange.start, end: fallbackRange.end)]
        }
        return words.map {
            TimedWord(text: $0.text, start: max(fallbackRange.start, $0.start),
                      end: min(fallbackRange.end, $0.end))
        }
    }

    /// A single recognition stream is sequential. An excessively long word timestamp
    /// must not stretch one speaker's paragraph over the next speaker's words.
    /// Different audio tracks are normalized separately, preserving actual crosstalk.
    public static func orderedWords(_ words: [TimedWord]) -> [TimedWord] {
        var ordered = words.enumerated().filter {
            let word = $0.element
            return word.start.isFinite && word.end.isFinite && word.start >= 0 && word.end >= word.start
                && !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        // Punctuation often has a zero-duration timestamp inside its preceding word.
        // It should not cut that word's range short.
        var nextStart: Double?
        for index in ordered.indices.reversed() {
            if let nextStart { ordered[index].end = min(ordered[index].end, max(ordered[index].start, nextStart)) }
            if ordered[index].text.rangeOfCharacter(from: .alphanumerics) != nil {
                nextStart = ordered[index].start
            }
        }
        return ordered
    }
}
