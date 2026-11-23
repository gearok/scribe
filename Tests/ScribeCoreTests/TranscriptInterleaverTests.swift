import XCTest
@testable import ScribeCore

final class TranscriptInterleaverTests: XCTestCase {
    private func paragraph(_ speaker: String, _ start: Int, _ end: Int, track: AudioTrack,
                           recordingID: String = "meeting") -> TranscriptSegment {
        let words = (start..<end).map { TimedWord(text: " \(speaker)-\($0)", start: Double($0), end: Double($0 + 1)) }
        return TranscriptAssembler.assemble(words: words, turns: [], recordingID: recordingID,
                                             speakerIDs: [:], unknownID: speaker, track: track)[0]
    }

    func testNestedTurnSplitsTheLongParagraphAtBothBoundariesWithoutLosingWords() {
        let long = paragraph("remote", 0, 30, track: .system)
        let short = paragraph("you", 5, 15, track: .microphone)
        let result = TranscriptInterleaver.interleave([short, long])
        let remote = result.filter { $0.speakerID == "remote" }
        XCTAssertEqual(remote.map(\.start), [0, 5, 15])
        XCTAssertEqual(remote.map(\.end), [5, 15, 30])
        XCTAssertEqual(remote.flatMap { $0.words ?? [] }, long.words)
        XCTAssertEqual(result.first { $0.speakerID == "you" }, short)
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        XCTAssertEqual(remote.first?.id, long.id)
        XCTAssertEqual(result.map(\.start), result.map(\.start).sorted())

        let overlap = TranscriptPlaybackState(segments: result, position: 10, isPlaying: true)
        XCTAssertEqual(overlap.activeSegmentIDs.count, 2)
        XCTAssertEqual(TranscriptInterleaver.overlappingSegmentIDs(in: result), [short.id, remote[1].id])
        XCTAssertEqual(TranscriptPlaybackState(segments: result, position: 20, isPlaying: true).activeSegmentIDs,
                       [remote[2].id])
    }

    func testInterruptionInsideAShortPauseDoesNotLeaveABridgingParagraph() {
        let remoteWords = [TimedWord(text: " Before.", start: 0, end: 5),
                           TimedWord(text: " After.", start: 6.5, end: 8)]
        let remote = TranscriptAssembler.assemble(words: remoteWords, turns: [], recordingID: "meeting",
                                                  speakerIDs: [:], unknownID: "remote", track: .system)
        XCTAssertEqual(remote.count, 1) // This pause is shorter than the ordinary paragraph gap.
        let reply = paragraph("you", 5, 6, track: .microphone)
        let result = TranscriptInterleaver.interleave(remote + [reply])
        XCTAssertEqual(result.map(\.text), ["Before.", "you-5", "After."])
        XCTAssertEqual(result.map(\.start), [0, 5, 6.5])
        XCTAssertEqual(result.map(\.end), [5, 6, 8])
    }

    func testBoundaryInsideAWordKeepsTheWholeWordAndItsAudioRange() {
        let words = [TimedWord(text: " Before", start: 0, end: 1),
                     TimedWord(text: " crossing", start: 1, end: 2),
                     TimedWord(text: " after", start: 2, end: 3)]
        let long = TranscriptAssembler.assemble(words: words, turns: [], recordingID: "meeting",
                                                speakerIDs: [:], unknownID: "remote", track: .system)
        let reply = TranscriptSegment(recordingID: "meeting", speakerID: "you", start: 1.5, end: 2.5,
                                      text: "reply", track: .microphone)
        let result = TranscriptInterleaver.interleave(long + [reply]).filter { $0.speakerID == "remote" }
        XCTAssertEqual(result.map(\.text), ["Before crossing", "after"])
        XCTAssertEqual(result.flatMap { $0.words ?? [] }, words)
        XCTAssertEqual(result[0].end, 2)
        XCTAssertEqual(result[1].start, 2)
    }

    func testSameSpeakerAndOtherRecordingsDoNotCreateBreaks() {
        let long = paragraph("remote", 0, 30, track: .system)
        let same = paragraph("remote", 5, 15, track: .microphone)
        let elsewhere = paragraph("other", 10, 20, track: .system, recordingID: "other-meeting")
        XCTAssertEqual(TranscriptInterleaver.interleave([long, same, elsewhere]), [long, same, elsewhere])
    }

    func testNonOverlappingSpeechAndUnalignedTextRemainUnchanged() {
        let long = paragraph("remote", 0, 30, track: .system)
        let later = paragraph("you", 30, 35, track: .microphone)
        XCTAssertEqual(TranscriptInterleaver.interleave([later, long]), [long, later])

        var edited = long
        edited.text = "Manually edited transcript"
        let reply = paragraph("you", 5, 15, track: .microphone)
        XCTAssertEqual(TranscriptInterleaver.interleave([edited, reply]), [edited, reply])
        edited.words = nil
        XCTAssertEqual(TranscriptInterleaver.interleave([edited, reply]), [edited, reply])
    }

    func testMultipleNestedSpeakersKeepEveryWordAndBoundTheirParagraphs() {
        let long = paragraph("remote", 0, 30, track: .system)
        let first = paragraph("you", 5, 15, track: .microphone)
        let second = paragraph("other", 10, 20, track: .system)
        let result = TranscriptInterleaver.interleave([long, first, second])
        for original in [long, first, second] {
            let parts = result.filter { $0.speakerID == original.speakerID }
            XCTAssertEqual(parts.flatMap { $0.words ?? [] }, original.words)
            XCTAssertTrue(parts.allSatisfy { $0.end - $0.start <= 10 })
        }
    }

    func testOverlapIndicatorExcludesSameSpeakerOtherMeetingsAndTouchingBoundaries() {
        let first = paragraph("a", 0, 5, track: .system)
        let next = paragraph("b", 5, 10, track: .microphone)
        let same = paragraph("a", 1, 4, track: .microphone)
        let elsewhere = paragraph("c", 1, 4, track: .system, recordingID: "other")
        XCTAssertTrue(TranscriptInterleaver.overlappingSegmentIDs(in: [next, first, same, elsewhere]).isEmpty)
        let overlapping = paragraph("d", 2, 3, track: .system)
        XCTAssertEqual(TranscriptInterleaver.overlappingSegmentIDs(in: [next, first, same, elsewhere, overlapping]),
                       [first.id, same.id, overlapping.id])
    }

    func testPunctuationAtAnInterruptionStaysWithItsSentence() {
        let words = [TimedWord(text: " First", start: 0, end: 1),
                     TimedWord(text: ".", start: 1, end: 1),
                     TimedWord(text: " Next", start: 1.5, end: 2)]
        let long = TranscriptAssembler.assemble(words: words, turns: [], recordingID: "meeting",
                                                speakerIDs: [:], unknownID: "remote", track: .system)
        let reply = paragraph("you", 1, 2, track: .microphone)
        let result = TranscriptInterleaver.interleave(long + [reply]).filter { $0.speakerID == "remote" }
        XCTAssertEqual(result.map(\.text), ["First.", "Next"])
        XCTAssertEqual(result.flatMap { $0.words ?? [] }, words)
    }
}
