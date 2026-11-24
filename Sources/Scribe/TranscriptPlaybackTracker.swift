import Combine
import ScribeCore

/// Playback ticks update the slider continuously. The transcript only needs a
/// redraw when a paragraph enters/leaves playback or the scroll target changes.
@MainActor
final class TranscriptPlaybackTracker: ObservableObject {
    @Published private(set) var state = TranscriptPlaybackState(segments: [], position: 0, isPlaying: false)
    private var timeline = TranscriptPlaybackTimeline(segments: [])

    func setSegments(_ segments: [TranscriptSegment], position: Double, isPlaying: Bool) {
        timeline = TranscriptPlaybackTimeline(segments: segments)
        update(position: position, isPlaying: isPlaying)
    }

    func update(position: Double, isPlaying: Bool) {
        let next = timeline.state(at: position, isPlaying: isPlaying)
        if next != state { state = next }
    }
}
