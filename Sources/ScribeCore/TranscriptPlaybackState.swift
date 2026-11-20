import Foundation

public struct TranscriptPlaybackState: Equatable, Sendable {
    public let activeSegmentIDs: Set<String>
    public let followingSegmentID: String?

    public init(segments: [TranscriptSegment], position: Double, isPlaying: Bool) {
        guard isPlaying, position.isFinite, position >= 0 else {
            activeSegmentIDs = []; followingSegmentID = nil
            return
        }
        var active: Set<String> = []
        var latest: TranscriptSegment?
        for segment in segments where segment.start.isFinite && segment.end.isFinite
            && segment.end > segment.start && segment.start <= position {
            if position < segment.end { active.insert(segment.id) }
            if segment.start >= (latest?.start ?? -.infinity) { latest = segment }
        }
        activeSegmentIDs = active
        // Keep the latest utterance in view through pauses and overlapping turns. Ending a
        // short overlapping turn must not scroll back to an older, longer paragraph.
        followingSegmentID = latest?.id
    }
}
