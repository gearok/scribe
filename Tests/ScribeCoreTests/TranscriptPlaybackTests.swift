import XCTest
@testable import ScribeCore

final class TranscriptPlaybackTests: XCTestCase {
    private func paragraph(_ id: String, _ start: Double, _ end: Double, track: AudioTrack = .system) -> TranscriptSegment {
        TranscriptSegment(id: id, recordingID: "recording", speakerID: id, start: start, end: end, text: id, track: track)
    }

    func testHighlightUsesExclusiveEndAndMovesAtAnExactBoundary() {
        let segments = [paragraph("first", 1, 3), paragraph("second", 3, 5)]
        XCTAssertEqual(TranscriptPlaybackState(segments: segments, position: 1, isPlaying: true).activeSegmentIDs, ["first"])
        let next = TranscriptPlaybackState(segments: segments, position: 3, isPlaying: true)
        XCTAssertEqual(next.activeSegmentIDs, ["second"])
        XCTAssertEqual(next.followingSegmentID, "second")
        XCTAssertTrue(TranscriptPlaybackState(segments: segments, position: 5, isPlaying: true).activeSegmentIDs.isEmpty)
    }

    func testPausingAndStoppingClearTheMarkerAndDoNotRequestScrolling() {
        let segments = [paragraph("first", 1, 3)]
        for time in [0.0, 2, 3, 20] {
            let state = TranscriptPlaybackState(segments: segments, position: time, isPlaying: false)
            XCTAssertTrue(state.activeSegmentIDs.isEmpty)
            XCTAssertNil(state.followingSegmentID)
        }
    }

    func testSilenceKeepsTheLastParagraphInViewWithoutHighlightingIt() {
        let segments = [paragraph("first", 1, 3), paragraph("second", 7, 9)]
        let beforeSpeech = TranscriptPlaybackState(segments: segments, position: 0, isPlaying: true)
        XCTAssertTrue(beforeSpeech.activeSegmentIDs.isEmpty)
        XCTAssertNil(beforeSpeech.followingSegmentID)
        let silence = TranscriptPlaybackState(segments: segments, position: 5, isPlaying: true)
        XCTAssertTrue(silence.activeSegmentIDs.isEmpty)
        XCTAssertEqual(silence.followingSegmentID, "first")
    }

    func testOverlappingTracksHighlightBothAndDoNotScrollBackwardWhenOneEnds() {
        let segments = [paragraph("long", 1, 20), paragraph("short", 5, 7, track: .microphone)]
        let overlap = TranscriptPlaybackState(segments: segments, position: 6, isPlaying: true)
        XCTAssertEqual(overlap.activeSegmentIDs, ["long", "short"])
        XCTAssertEqual(overlap.followingSegmentID, "short")
        let afterOverlap = TranscriptPlaybackState(segments: segments, position: 8, isPlaying: true)
        XCTAssertEqual(afterOverlap.activeSegmentIDs, ["long"])
        XCTAssertEqual(afterOverlap.followingSegmentID, "short")
    }

    func testSeekingInEitherDirectionWorksWithUnsortedParagraphs() {
        let segments = [paragraph("last", 20, 25), paragraph("first", 1, 3), paragraph("middle", 10, 15)]
        for (time, id) in [(21.0, "last"), (2.0, "first"), (12.0, "middle")] {
            let state = TranscriptPlaybackState(segments: segments, position: time, isPlaying: true)
            XCTAssertEqual(state.activeSegmentIDs, [id])
            XCTAssertEqual(state.followingSegmentID, id)
        }
    }

    func testEmptyAndInvalidRangesNeverHighlightOrScroll() {
        let segments = [paragraph("empty", 2, 2), paragraph("reversed", 4, 1), paragraph("invalid", .nan, 10)]
        for time in [3.0, -.infinity, .nan, -1] {
            let state = TranscriptPlaybackState(segments: segments, position: time, isPlaying: true)
            XCTAssertTrue(state.activeSegmentIDs.isEmpty)
            XCTAssertNil(state.followingSegmentID)
        }
    }
}
