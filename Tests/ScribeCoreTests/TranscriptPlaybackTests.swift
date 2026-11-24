import XCTest
@testable import ScribeCore

final class TranscriptPlaybackTests: XCTestCase {
    func testIndexedTimelineMatchesLinearReferenceAcrossSeeksAndManyOverlaps() {
        let ordered: [TranscriptSegment] = (0..<3000).map { index in
            let start = Double(index / 3)
            let duration: Double = index % 17 == 0 ? 100 : 2
            return paragraph(String(index), start, start + duration)
        }
        let segments = Array(ordered.reversed())
        let timeline = TranscriptPlaybackTimeline(segments: segments)
        for position in stride(from: 1050.0, through: 0, by: -2.75) {
            let expectedActive = Set(segments.filter { $0.start <= position && position < $0.end }.map(\.id))
            var latest: TranscriptSegment?
            for segment in segments where segment.start <= position {
                if segment.start >= (latest?.start ?? -.infinity) { latest = segment }
            }
            let actual = timeline.state(at: position, isPlaying: true)
            XCTAssertEqual(actual.activeSegmentIDs, expectedActive)
            XCTAssertEqual(actual.followingSegmentID, latest?.id)
        }
    }

    func testIndexedPlaybackScaling() {
        let segments = (0..<20_000).map { paragraph(String($0), Double($0) * 2, Double($0) * 2 + 1) }
        let timeline = TranscriptPlaybackTimeline(segments: segments)
        let start = ContinuousClock.now
        var activeCount = 0
        for index in 0..<10_000 {
            activeCount += timeline.state(at: Double(index * 2) + 0.5, isPlaying: true).activeSegmentIDs.count
        }
        XCTAssertEqual(activeCount, 10_000)
        print("Indexed playback: 10,000 lookups across 20,000 paragraphs in \(ContinuousClock.now - start)")
    }

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
