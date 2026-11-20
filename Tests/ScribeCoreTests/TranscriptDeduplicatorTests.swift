import XCTest
@testable import ScribeCore

final class TranscriptDeduplicatorTests: XCTestCase {
    private func words(_ text: String, start: Double = 0) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TimedWord(text: " " + word, start: start + Double(index) * 0.4, end: start + Double(index + 1) * 0.4)
        }
    }

    private func text(_ words: [TimedWord]?) -> String {
        (words ?? []).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testRemovesMicrophoneEchoDespitePunctuationCaseAndSmallDelay() {
        let system = words("Давайте обсудим планы следующего спринта.")
        let microphone = words("ДАВАЙТЕ обсудим, планы следующего спринта!", start: 0.3)
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: system, .microphone: microphone])
        XCTAssertEqual(text(result[.system]), text(system))
        XCTAssertTrue(result[.microphone]!.isEmpty)
    }

    func testTrimsOnlyTheMatchingPartAndKeepsOriginalTimesForUniqueWords() throws {
        let system = words("we should review these important requirements", start: 2)
        let prefix = words("My introduction", start: 0)
        let echo = words("we should review these important requirements", start: 2.2)
        let suffix = words("My conclusion", start: 5)
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: system, .microphone: prefix + echo + suffix])
        let remaining = try XCTUnwrap(result[.microphone])
        XCTAssertEqual(text(remaining), "My introduction My conclusion")
        XCTAssertEqual(remaining.map(\.start), (prefix + suffix).map(\.start))
        XCTAssertEqual(remaining.map(\.end), (prefix + suffix).map(\.end))
    }

    func testRemovesRepeatedRecognitionWithinOneTrackBeforeTimestampSorting() {
        let original = words("Нужно проверить все новые настройки.")
        let repeated = words("Нужно проверить все новые настройки.", start: 0.1)
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.microphone: original + repeated])
        XCTAssertEqual(text(result[.microphone]), text(original))
        XCTAssertEqual(result[.microphone]?.map(\.start), original.map(\.start))
        XCTAssertNil(result[.system])
    }

    func testKeepsTheSamePhraseRepeatedLaterOnEitherTrack() {
        let phrase = "Please check the latest release notes."
        let system = words(phrase)
        let microphone = words(phrase, start: 5) + words(phrase, start: 10)
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: system, .microphone: microphone])
        XCTAssertEqual(text(result[.microphone]), text(microphone))
    }

    func testKeepsBriefRepliesAndStuttering() {
        let system = words("да да да да")
        let microphone = words("да да да да", start: 0.1)
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: system, .microphone: microphone])
        XCTAssertEqual(text(result[.microphone]), text(microphone))
        let short = words("That's a good idea")
        XCTAssertEqual(text(TranscriptDeduplicator.clean(wordsByTrack: [.microphone: short + short])[.microphone]), text(short + short))
    }

    func testKeepsDifferentWordsSpokenAtTheSameTime() {
        let system = words("We need to discuss the delivery schedule")
        let microphone = words("Давайте сначала проверим результаты вчерашнего тестирования")
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: system, .microphone: microphone])
        XCTAssertEqual(text(result[.system]), text(system))
        XCTAssertEqual(text(result[.microphone]), text(microphone))
    }

    func testKeepsAnExchangeBetweenDifferentSystemSpeakers() {
        let first = words("Нужно проверить все новые настройки.")
        let second = words("Нужно проверить все новые настройки.", start: 0.3)
        let turns = [SpeakerTurn(speaker: "anna", start: 0, end: 1.4),
                     SpeakerTurn(speaker: "bob", start: 1.4, end: 3)]
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: first + second], turnsByTrack: [.system: turns])
        XCTAssertEqual(text(result[.system]), text(first + second))
    }

    func testCleansOverlappingSystemRecognitionForTheSameSpeaker() {
        let phrase = words("Нужно проверить все новые настройки.")
        let turns = [SpeakerTurn(speaker: "anna", start: 0, end: 3)]
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: phrase + phrase], turnsByTrack: [.system: turns])
        let cleaned = result[.system]!
        let paragraphs = TranscriptAssembler.assemble(words: cleaned, turns: turns, recordingID: "meeting",
                                                       speakerIDs: ["anna": "speaker-1"], unknownID: "unknown", track: .system)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs.first?.text, text(phrase))
        XCTAssertEqual(paragraphs.first?.speakerID, "speaker-1")
    }

    func testKeepsWordsWithUnreliableTimestampsInsteadOfGuessing() {
        let phrase = words("Please review these important requirements")
        let unreliable = [TimedWord(text: " Unknown", start: .infinity, end: .infinity),
                          TimedWord(text: " Huge", start: 1e100, end: 1e100)]
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: phrase, .microphone: phrase + unreliable])
        XCTAssertEqual(text(result[.microphone]), "Unknown Huge")
    }

    func testHandlesFallbackResultsContainingWholeSentences() {
        let original = TimedWord(text: "Обсудим важные изменения в следующем выпуске.", start: 0, end: 5)
        let repeated = TimedWord(text: "Обсудим важные изменения в следующем выпуске!", start: 0.2, end: 5.2)
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: [original], .microphone: [repeated]])
        XCTAssertTrue(result[.microphone]!.isEmpty)
        let partial = TimedWord(text: repeated.text + " Дополнительные слова.", start: 0.2, end: 5.2)
        let preserved = TranscriptDeduplicator.clean(wordsByTrack: [.system: [original], .microphone: [partial]])
        XCTAssertEqual(text(preserved[.microphone]), partial.text)
    }

    func testDoesNotMatchSeparatePassagesAcrossALongPause() {
        let phrase = words("Review important project requirements")
        var split = phrase
        split[2].start += 8; split[2].end += 8
        split[3].start += 8; split[3].end += 8
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: split, .microphone: split])
        XCTAssertEqual(text(result[.microphone]), text(split))
    }

    func testRemovesAttachedPunctuationWithoutLeavingAnEmptyParagraph() {
        let phrase = words("Please review these important requirements")
        let punctuation = TimedWord(text: ".", start: 2, end: 2)
        let result = TranscriptDeduplicator.clean(wordsByTrack: [.system: phrase, .microphone: phrase + [punctuation]])
        XCTAssertTrue(result[.microphone]!.isEmpty)
    }

    func testCleanupIsIdempotentAndAcceptsEmptyTracks() {
        XCTAssertTrue(TranscriptDeduplicator.clean(wordsByTrack: [:]).isEmpty)
        let phrase = words("Please review these important requirements")
        let input: [AudioTrack: [TimedWord]] = [.system: phrase + phrase, .microphone: phrase]
        let once = TranscriptDeduplicator.clean(wordsByTrack: input)
        let twice = TranscriptDeduplicator.clean(wordsByTrack: once)
        for track in [AudioTrack.system, .microphone] {
            XCTAssertEqual(text(once[track]), text(twice[track]))
            XCTAssertEqual(once[track]?.map(\.start), twice[track]?.map(\.start))
        }
    }
}
