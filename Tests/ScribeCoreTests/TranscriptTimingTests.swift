import XCTest
@testable import ScribeCore

final class TranscriptTimingTests: XCTestCase {
    func testRecognitionIsClippedToItsSegmentAndSuppliedAudio() {
        let words = [TimedWord(text: " First", start: 9.8, end: 10.5),
                     TimedWord(text: " second", start: 10.5, end: 14)]
        let fallback = TimedWord(text: "First second", start: 9, end: 13)
        let result = TranscriptTiming.recognitionWords(words, fallback: fallback, within: SpeechWindow(start: 10, end: 12))
        XCTAssertEqual(result.map(\.start), [10, 10.5])
        XCTAssertEqual(result.map(\.end), [10.5, 12])
        XCTAssertEqual(result.map(\.text), words.map(\.text))
    }

    func testInvalidWordAlignmentPreservesTheCompleteSegmentAsAFallback() {
        let fallback = TimedWord(text: "Keep every word.", start: 1, end: 4)
        for invalid in [TimedWord(text: "bad", start: .nan, end: 2),
                        TimedWord(text: "bad", start: 1, end: .infinity),
                        TimedWord(text: "bad", start: 3, end: 2),
                        TimedWord(text: "bad", start: 30, end: 40)] {
            XCTAssertEqual(TranscriptTiming.recognitionWords([invalid], fallback: fallback,
                                                              within: SpeechWindow(start: 0, end: 5)), [fallback])
        }
        XCTAssertEqual(TranscriptTiming.recognitionWords([], fallback: fallback,
                                                          within: SpeechWindow(start: 0, end: 5)), [fallback])
        let invalidSegment = TimedWord(text: fallback.text, start: .nan, end: .infinity)
        let bounded = TranscriptTiming.recognitionWords([], fallback: invalidSegment, within: SpeechWindow(start: 0, end: 5))
        XCTAssertEqual(bounded, [TimedWord(text: fallback.text, start: 0, end: 5)])
        let invalidWord = TimedWord(text: " Preserve me.", start: .nan, end: 2)
        let blankFallback = TimedWord(text: "", start: 1, end: 4)
        XCTAssertEqual(TranscriptTiming.recognitionWords([invalidWord], fallback: blankFallback,
                                                          within: SpeechWindow(start: 0, end: 5)),
                       [TimedWord(text: invalidWord.text, start: 1, end: 4)])
    }

    func testOverlongWordCannotStretchAParagraphOverTheNextSpeaker() {
        let words = [TimedWord(text: " First.", start: 0, end: 30),
                     TimedWord(text: " Reply.", start: 5, end: 15),
                     TimedWord(text: " Last.", start: 15, end: 30)]
        let turns = [SpeakerTurn(speaker: "a", start: 0, end: 5),
                     SpeakerTurn(speaker: "b", start: 5, end: 15),
                     SpeakerTurn(speaker: "a", start: 15, end: 30)]
        let paragraphs = TranscriptAssembler.assemble(words: words, turns: turns, recordingID: "meeting",
                                                       speakerIDs: ["a": "anna", "b": "bob"], unknownID: "unknown", track: .system)
        XCTAssertEqual(paragraphs.map(\.speakerID), ["anna", "bob", "anna"])
        XCTAssertEqual(paragraphs.map(\.start), [0, 5, 15])
        XCTAssertEqual(paragraphs.map(\.end), [5, 15, 30])
        XCTAssertEqual(paragraphs.map(\.text), ["First.", "Reply.", "Last."])
    }

    func testZeroDurationPunctuationDoesNotTruncateThePreviousWord() {
        let words = [TimedWord(text: " Hello", start: 0, end: 1),
                     TimedWord(text: ".", start: 0.5, end: 0.5),
                     TimedWord(text: " Next", start: 2, end: 3)]
        let result = TranscriptTiming.orderedWords(words)
        XCTAssertEqual(result, words)
    }

    func testAssemblerRejectsInvalidRangesAndRetainsEqualTimeWordsInRecognitionOrder() {
        let words = [TimedWord(text: " First", start: 0, end: 1),
                     TimedWord(text: " second", start: 0, end: 1),
                     TimedWord(text: " invalid", start: .nan, end: 5),
                     TimedWord(text: " backwards", start: 6, end: 5)]
        let result = TranscriptAssembler.assemble(words: words, turns: [], recordingID: "meeting",
                                                  speakerIDs: [:], unknownID: "you", track: .microphone)
        XCTAssertEqual(result.map(\.text), ["First second"])
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 1)
    }

    func testLegacyParagraphDecodesWithoutWordTimings() throws {
        let json = #"{"id":"old","recordingID":"meeting","speakerID":"you","start":0,"end":30,"text":"Original text","track":"microphone"}"#
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))
        XCTAssertNil(segment.words)
        XCTAssertEqual(segment.text, "Original text")
    }

    func testZeroDurationWordsAndBoundaryPunctuationKeepTheirSpeakers() {
        let words = [TimedWord(text: " First", start: 0, end: 0),
                     TimedWord(text: " sentence", start: 0, end: 1),
                     TimedWord(text: ".", start: 1, end: 1),
                     TimedWord(text: " Reply", start: 1, end: 2)]
        let turns = [SpeakerTurn(speaker: "a", start: 0, end: 1), SpeakerTurn(speaker: "b", start: 1, end: 2)]
        let result = TranscriptAssembler.assemble(words: words, turns: turns, recordingID: "meeting",
                                                  speakerIDs: ["a": "anna", "b": "bob"], unknownID: "unknown", track: .system)
        XCTAssertEqual(result.map(\.speakerID), ["anna", "bob"])
        XCTAssertEqual(result.map(\.text), ["First sentence.", "Reply"])
    }
}
