import Foundation

/// Split already speaker-assigned paragraphs at other voices' boundaries. Each
/// track keeps its own words and timing, including genuinely simultaneous speech.
public enum TranscriptInterleaver {
    private struct Boundary {
        let time: Double
        let speakerID: String
    }

    public static func overlappingSegmentIDs(in segments: [TranscriptSegment]) -> Set<String> {
        var result: Set<String> = []
        for paragraphs in Dictionary(grouping: segments, by: \.recordingID).values {
            var active: [TranscriptSegment] = []
            for segment in paragraphs.filter({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start })
                .sorted(by: { $0.start < $1.start }) {
                active.removeAll { $0.end <= segment.start }
                for other in active where other.speakerID != segment.speakerID {
                    result.insert(other.id)
                    result.insert(segment.id)
                }
                active.append(segment)
            }
        }
        return result
    }

    public static func interleave(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let boundaries = Dictionary(grouping: segments, by: \.recordingID).mapValues { paragraphs in
            paragraphs.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }.flatMap {
                [Boundary(time: $0.start, speakerID: $0.speakerID), Boundary(time: $0.end, speakerID: $0.speakerID)]
            }.sorted { $0.time < $1.time }
        }
        var result: [TranscriptSegment] = []
        for segment in segments {
            // Never split saved or edited text without its actual word alignment.
            guard let words = segment.words, !words.isEmpty,
                  words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == segment.text,
                  words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }),
                  let events = boundaries[segment.recordingID] else {
                result.append(segment)
                continue
            }
            var low = 0, high = events.count
            while low < high {
                let middle = (low + high) / 2
                if events[middle].time <= segment.start { low = middle + 1 } else { high = middle }
            }
            var cuts: [Double] = []
            for event in events.dropFirst(low) {
                if event.time >= segment.end { break }
                if event.speakerID != segment.speakerID, cuts.last != event.time { cuts.append(event.time) }
            }
            guard !cuts.isEmpty else { result.append(segment); continue }

            var groups: [[TimedWord]] = [], group: [TimedWord] = []
            var cutIndex = 0
            for word in words {
                // A boundary inside a word takes effect before the next word. Keep the
                // crossing word intact rather than clipping audio or duplicating its text.
                var crossedBoundary = false
                if word.text.rangeOfCharacter(from: .alphanumerics) != nil {
                    while cutIndex < cuts.count && cuts[cutIndex] <= word.start {
                        crossedBoundary = true
                        cutIndex += 1
                    }
                }
                if crossedBoundary, !group.isEmpty { groups.append(group); group = [] }
                group.append(word)
            }
            if !group.isEmpty { groups.append(group) }
            for (index, group) in groups.enumerated() {
                var part = segment
                if index > 0 { part.id = UUID().uuidString }
                part.words = group
                part.start = group[0].start
                part.end = group.map(\.end).max() ?? part.start
                part.text = group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(part)
            }
        }
        return result.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
    }
}
