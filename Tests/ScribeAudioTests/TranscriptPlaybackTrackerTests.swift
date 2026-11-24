import XCTest
import Combine
import ScribeCore
@testable import Scribe

@MainActor
final class TranscriptPlaybackTrackerTests: XCTestCase {
    func testOnlyParagraphChangesPublishTranscriptUpdates() {
        let tracker = TranscriptPlaybackTracker()
        let segments = [TranscriptSegment(recordingID: "r", speakerID: "s", start: 1, end: 3, text: "Speech", track: .system)]
        tracker.setSegments(segments, position: 0, isPlaying: false)
        var updates = 0
        let observation = tracker.objectWillChange.sink { updates += 1 }
        for position in [1.0, 1.1, 1.25, 1.5, 2.0, 2.9] { tracker.update(position: position, isPlaying: true) }
        XCTAssertEqual(updates, 1)
        tracker.update(position: 3, isPlaying: true)
        XCTAssertEqual(updates, 2)
        tracker.update(position: 4, isPlaying: true)
        XCTAssertEqual(updates, 2)
        tracker.update(position: 4, isPlaying: false)
        XCTAssertEqual(updates, 3)
        withExtendedLifetime(observation) {}
    }
}
