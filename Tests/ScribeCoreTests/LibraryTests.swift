import XCTest
@testable import ScribeCore

final class LibraryTests: XCTestCase {
    private func makeDatabase() throws -> (LibraryDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (try LibraryDatabase(url: folder.appendingPathComponent("library.sqlite")), folder)
    }

    func testNamesAndEditedParagraphsPersistAfterReopeningLibrary() throws {
        let (db, directory) = try makeDatabase()
        let recording = Recording(title: "Встреча", status: .ready)
        var speaker = Speaker(recordingID: recording.id, name: "Speaker 1", colorIndex: 1)
        var segment = TranscriptSegment(recordingID: recording.id, speakerID: speaker.id, start: 1, end: 5, text: "Привет", track: .system)
        try db.saveTranscript(recording: recording, speakers: [speaker], segments: [segment])
        speaker.name = "Анна"; try db.saveSpeaker(speaker)
        segment.text = "Привет, коллеги."; try db.saveSegment(segment)
        let reopened = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let saved = try reopened.transcript(recordingID: recording.id)
        XCTAssertEqual(saved.speakers.first?.name, "Анна")
        XCTAssertEqual(saved.segments.first?.text, "Привет, коллеги.")
        XCTAssertEqual(try reopened.recordings().first?.title, "Встреча")
    }

    func testMergingSpeakersReassignsAllParagraphsWithoutChangingAudioTrack() throws {
        let (db, _) = try makeDatabase()
        let recording = Recording(title: "Meeting", status: .ready)
        let first = Speaker(recordingID: recording.id, name: "Anna", colorIndex: 1)
        let duplicate = Speaker(recordingID: recording.id, name: "Speaker 2", colorIndex: 2)
        let segments = [
            TranscriptSegment(recordingID: recording.id, speakerID: first.id, start: 1, end: 2, text: "One", track: .system),
            TranscriptSegment(recordingID: recording.id, speakerID: duplicate.id, start: 4, end: 5, text: "Two", track: .microphone),
            TranscriptSegment(recordingID: recording.id, speakerID: duplicate.id, start: 7, end: 8, text: "Three", track: .system),
        ]
        try db.saveTranscript(recording: recording, speakers: [first, duplicate], segments: segments)
        try db.mergeSpeaker(duplicate, into: first)
        let saved = try db.transcript(recordingID: recording.id)
        XCTAssertEqual(saved.speakers.count, 1)
        XCTAssertEqual(Set(saved.segments.map(\.speakerID)), [first.id])
        XCTAssertEqual(saved.segments.map(\.track), [.system, .microphone, .system])
        XCTAssertEqual(saved.segments.map(\.start), [1, 4, 7])
    }

    func testWordTimingsSurviveReopeningAndSpeakerMerging() throws {
        let (db, directory) = try makeDatabase()
        let recording = Recording(title: "Meeting", status: .ready)
        let first = Speaker(recordingID: recording.id, name: "Anna", colorIndex: 1)
        let duplicate = Speaker(recordingID: recording.id, name: "Other", colorIndex: 2)
        let words = [TimedWord(text: " Hello", start: 1, end: 2), TimedWord(text: " there", start: 2, end: 3)]
        let paragraphs = TranscriptAssembler.assemble(words: words, turns: [], recordingID: recording.id,
                                                       speakerIDs: [:], unknownID: duplicate.id, track: .system)
        try db.saveTranscript(recording: recording, speakers: [first, duplicate], segments: paragraphs)
        try db.mergeSpeaker(duplicate, into: first)
        let reopened = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let saved = try XCTUnwrap(reopened.transcript(recordingID: recording.id).segments.first)
        XCTAssertEqual(saved.words, words)
        XCTAssertEqual(saved.text, "Hello there")
        XCTAssertEqual(saved.speakerID, first.id)
    }

    func testInvalidReplacementRollsBackEntireTranscript() throws {
        let (db, _) = try makeDatabase()
        let recording = Recording(title: "Original", status: .ready)
        let speaker = Speaker(recordingID: recording.id, name: "Anna", colorIndex: 1)
        let segment = TranscriptSegment(recordingID: recording.id, speakerID: speaker.id, start: 1, end: 2, text: "Keep this", track: .system)
        try db.saveTranscript(recording: recording, speakers: [speaker], segments: [segment])
        var invalid = segment; invalid.speakerID = "missing-speaker"
        var changed = recording; changed.title = "Should roll back"
        XCTAssertThrowsError(try db.saveTranscript(recording: changed, speakers: [speaker], segments: [invalid]))
        XCTAssertEqual(try db.recordings().first?.title, "Original")
        XCTAssertEqual(try db.transcript(recordingID: recording.id).segments.first?.text, "Keep this")
    }

    func testDeletingOneRecordingPreservesAnother() throws {
        let (db, _) = try makeDatabase()
        let first = Recording(title: "First", status: .ready)
        let second = Recording(title: "Second")
        let speaker = Speaker(recordingID: first.id, name: "Speaker", colorIndex: 0)
        let segment = TranscriptSegment(recordingID: first.id, speakerID: speaker.id, start: 0, end: 1, text: "Text", track: .system)
        try db.saveTranscript(recording: first, speakers: [speaker], segments: [segment])
        try db.save(second)
        try db.delete(recordingID: first.id)
        XCTAssertEqual(try db.recordings().map(\.id), [second.id])
        XCTAssertTrue(try db.transcript(recordingID: first.id).segments.isEmpty)
        XCTAssertTrue(try db.transcript(recordingID: first.id).speakers.isEmpty)
    }

    func testCrossMeetingMergeDoesNotChangeEitherSpeaker() throws {
        let (db, _) = try makeDatabase()
        let a = Recording(title: "A"), b = Recording(title: "B")
        let sa = Speaker(recordingID: a.id, name: "A speaker", colorIndex: 0)
        let sb = Speaker(recordingID: b.id, name: "B speaker", colorIndex: 1)
        try db.saveTranscript(recording: a, speakers: [sa], segments: [])
        try db.saveTranscript(recording: b, speakers: [sb], segments: [])
        try db.mergeSpeaker(sa, into: sb)
        XCTAssertEqual(try db.transcript(recordingID: a.id).speakers.count, 1)
        XCTAssertEqual(try db.transcript(recordingID: b.id).speakers.count, 1)
    }
}

final class TranscriptAssemblerTests: XCTestCase {
    func testSpeechWindowsKeepSeparateSpeakerTurnsForLanguageDetection() {
        let turns = [SpeakerTurn(speaker: "russian", start: 1, end: 5), SpeakerTurn(speaker: "english", start: 6, end: 10)]
        let windows = SpeechWindowBuilder.windows(turns: turns, duration: 12)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].start, 0.82, accuracy: 0.001)
        XCTAssertEqual(windows[1].start, 5.82, accuracy: 0.001)
        XCTAssertLessThan(windows[0].end, windows[1].start)
    }

    func testOverlappingSpeechIsNotTranscribedTwiceAndLongTurnsAreBounded() {
        let turns = [SpeakerTurn(speaker: "a", start: 0, end: 25), SpeakerTurn(speaker: "b", start: 20, end: 50)]
        let windows = SpeechWindowBuilder.windows(turns: turns, duration: 50)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.first?.start, 0)
        XCTAssertEqual(windows.last?.end, 50)
        XCTAssertTrue(windows.allSatisfy { $0.end - $0.start <= 22 })
        for index in 1..<windows.count { XCTAssertEqual(windows[index - 1].end, windows[index].start) }
    }

    func testNoSpeechProducesNoRecognitionWindows() {
        XCTAssertTrue(SpeechWindowBuilder.windows(turns: [], duration: 3600).isEmpty)
    }

    func testAssignsByOverlapAndSplitsAtSpeakerChanges() {
        let words = [TimedWord(text: " Привет", start: 0, end: 0.5), TimedWord(text: " всем.", start: 0.5, end: 1),
                     TimedWord(text: " Hello.", start: 1.2, end: 1.7)]
        let turns = [SpeakerTurn(speaker: "a", start: 0, end: 1.1), SpeakerTurn(speaker: "b", start: 1.1, end: 2)]
        let segments = TranscriptAssembler.assemble(words: words, turns: turns, recordingID: "meeting",
                                                    speakerIDs: ["a": "anna", "b": "bob"], unknownID: "unknown", track: .system)
        XCTAssertEqual(segments.map(\.speakerID), ["anna", "bob"])
        XCTAssertEqual(segments.map(\.text), ["Привет всем.", "Hello."])
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 1)
    }

    func testUsesGreatestOverlapRatherThanFirstOverlappingVoice() {
        let words = [TimedWord(text: " word", start: 1, end: 2)]
        let turns = [SpeakerTurn(speaker: "a", start: 0, end: 1.2), SpeakerTurn(speaker: "b", start: 1.1, end: 3)]
        let segments = TranscriptAssembler.assemble(words: words, turns: turns, recordingID: "meeting",
                                                    speakerIDs: ["a": "anna", "b": "bob"], unknownID: "unknown", track: .system)
        XCTAssertEqual(segments.first?.speakerID, "bob")
    }

    func testUnmatchedWordsAreNotAssignedToAnArbitrarySpeaker() {
        let segments = TranscriptAssembler.assemble(words: [TimedWord(text: " word", start: 10, end: 11)],
                                                    turns: [SpeakerTurn(speaker: "a", start: 0, end: 1)], recordingID: "meeting",
                                                    speakerIDs: ["a": "anna"], unknownID: "unassigned", track: .system)
        XCTAssertEqual(segments.first?.speakerID, "unassigned")
    }

    func testLongSilenceSeparatesParagraphsFromTheSameSpeaker() {
        let words = [TimedWord(text: " First.", start: 0, end: 1), TimedWord(text: " Later.", start: 20, end: 21)]
        let result = TranscriptAssembler.assemble(words: words, turns: [], recordingID: "meeting", speakerIDs: [:], unknownID: "me", track: .microphone)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.track), [.microphone, .microphone])
    }

    func testDurationFormattingSupportsLongMeetings() {
        XCTAssertEqual(TimeLabel.clock(65), "1:05")
        XCTAssertEqual(TimeLabel.clock(3605), "1:00:05")
        XCTAssertEqual(TimeLabel.clock(-1), "0:00")
        XCTAssertEqual(TimeLabel.clock(.infinity), "0:00")
    }
}
