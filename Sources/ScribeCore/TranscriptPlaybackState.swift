import Foundation

public struct TranscriptPlaybackState: Equatable, Sendable {
    public let activeSegmentIDs: Set<String>
    public let followingSegmentID: String?

    public init(segments: [TranscriptSegment], position: Double, isPlaying: Bool) {
        self = TranscriptPlaybackTimeline(segments: segments).state(at: position, isPlaying: isPlaying)
    }

    fileprivate init(active: Set<String> = [], following: String? = nil) {
        activeSegmentIDs = active
        followingSegmentID = following
    }
}

/// Build once when the visible transcript changes, rather than scanning every
/// paragraph on each playback tick. A max-end tree prunes finished paragraphs
/// while retaining overlapping voices and supporting arbitrary seeking.
public struct TranscriptPlaybackTimeline: Sendable {
    private struct Entry: Sendable {
        let id: String
        let start: Double
        let end: Double
    }
    private let entries: [Entry]
    private let maximumEnds: [Double]

    public init(segments: [TranscriptSegment]) {
        let entries = segments.enumerated().filter {
            $0.element.start.isFinite && $0.element.end.isFinite && $0.element.end > $0.element.start
        }.sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map { Entry(id: $0.element.id, start: $0.element.start, end: $0.element.end) }
        var ends = Array(repeating: -Double.infinity, count: max(1, entries.count * 4))
        func build(_ node: Int, _ lower: Int, _ upper: Int) -> Double {
            if upper - lower == 1 { ends[node] = entries[lower].end }
            else {
                let middle = (lower + upper) / 2
                ends[node] = max(build(node * 2, lower, middle), build(node * 2 + 1, middle, upper))
            }
            return ends[node]
        }
        if !entries.isEmpty { _ = build(1, 0, entries.count) }
        self.entries = entries
        maximumEnds = ends
    }

    public func state(at position: Double, isPlaying: Bool) -> TranscriptPlaybackState {
        guard isPlaying, position.isFinite, position >= 0 else {
            return TranscriptPlaybackState()
        }
        var lower = 0, upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entries[middle].start <= position { lower = middle + 1 }
            else { upper = middle }
        }
        let following = lower > 0 ? entries[lower - 1].id : nil
        var active: Set<String> = []
        func collect(_ node: Int, _ start: Int, _ end: Int) {
            guard start < lower, maximumEnds[node] > position else { return }
            if end - start == 1 { active.insert(entries[start].id); return }
            let middle = (start + end) / 2
            collect(node * 2, start, middle)
            collect(node * 2 + 1, middle, end)
        }
        if !entries.isEmpty { collect(1, 0, entries.count) }
        // Keep the latest utterance in view through pauses and overlapping turns. Ending a
        // short overlapping turn must not scroll back to an older, longer paragraph.
        return TranscriptPlaybackState(active: active, following: following)
    }
}
