import XCTest
import GRDB
@testable import ScribeCore

final class FolderTests: XCTestCase {
    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("library.sqlite")
    }

    func testFoldersAndAssignmentsPersistAcrossTranscriptReplacementAndReopening() throws {
        let url = try databaseURL(), db = try LibraryDatabase(url: url)
        let folder = RecordingFolder(name: "Работа", color: .purple)
        let recording = Recording(title: "Meeting")
        try db.saveFolder(folder)
        try db.save(recording)
        try db.moveRecordings([recording.id], toFolder: folder.id)
        // A processing task may still hold the original recording value when it finishes.
        try db.saveTranscript(recording: recording, speakers: [], segments: [])
        let reopened = try LibraryDatabase(url: url)
        XCTAssertEqual(try reopened.folders(), [folder])
        XCTAssertEqual(try reopened.folderAssignments(), [recording.id: folder.id])
        XCTAssertEqual(try reopened.recordings(), [recording])
    }

    func testMovingUnfilingAndDeletingRecordingsKeepAssignmentsConsistent() throws {
        let db = try LibraryDatabase(url: databaseURL())
        let work = RecordingFolder(name: "Work", color: .blue), personal = RecordingFolder(name: "Personal", color: .green)
        let first = Recording(title: "First"), second = Recording(title: "Second")
        try db.saveFolder(work); try db.saveFolder(personal)
        try db.save(first); try db.save(second)
        try db.moveRecordings([first.id, second.id], toFolder: work.id)
        try db.moveRecordings([first.id], toFolder: personal.id)
        XCTAssertEqual(try db.folderAssignments(), [first.id: personal.id, second.id: work.id])
        try db.moveRecordings([first.id], toFolder: nil)
        XCTAssertEqual(try db.folderAssignments(), [second.id: work.id])
        XCTAssertEqual(try db.recordings().count, 2)
        try db.delete(recordingID: second.id)
        XCTAssertTrue(try db.folderAssignments().isEmpty)
        XCTAssertEqual(try db.folders().count, 2)
    }

    func testInvalidMovesRollBackTheWholeBatch() throws {
        let db = try LibraryDatabase(url: databaseURL())
        let folder = RecordingFolder(name: "Work", color: .orange)
        let recording = Recording(title: "Keep unfiled")
        try db.saveFolder(folder); try db.save(recording)
        XCTAssertThrowsError(try db.moveRecordings([recording.id, "missing-recording"], toFolder: folder.id))
        XCTAssertTrue(try db.folderAssignments().isEmpty)
        XCTAssertThrowsError(try db.moveRecordings([recording.id], toFolder: "missing-folder"))
        XCTAssertTrue(try db.folderAssignments().isEmpty)
    }

    func testExistingLibraryMigratesWithoutChangingRecordingsOrTranscripts() throws {
        let url = try databaseURL()
        let recording = Recording(title: "Existing meeting", status: .ready)
        let speaker = Speaker(recordingID: recording.id, name: "Анна", colorIndex: 1)
        let segment = TranscriptSegment(recordingID: recording.id, speakerID: speaker.id, start: 0, end: 5, text: "Сохранить текст", track: .system)
        // Reproduce the previous schema, before any folder tables existed.
        do {
            let old = try DatabaseQueue(path: url.path)
            try old.write { db in
                try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('library-v1')")
                try db.execute(sql: "CREATE TABLE recordings (id TEXT PRIMARY KEY, createdAt DATETIME NOT NULL, payload BLOB NOT NULL)")
                try db.execute(sql: "CREATE TABLE speakers (id TEXT PRIMARY KEY, recordingID TEXT REFERENCES recordings(id), payload BLOB NOT NULL)")
                try db.execute(sql: "CREATE TABLE segments (id TEXT PRIMARY KEY, recordingID TEXT REFERENCES recordings(id), speakerID TEXT REFERENCES speakers(id), start DOUBLE NOT NULL, payload BLOB NOT NULL)")
                try db.execute(sql: "INSERT INTO recordings VALUES (?, ?, ?)", arguments: [recording.id, recording.createdAt, try JSONEncoder().encode(recording)])
                try db.execute(sql: "INSERT INTO speakers VALUES (?, ?, ?)", arguments: [speaker.id, recording.id, try JSONEncoder().encode(speaker)])
                try db.execute(sql: "INSERT INTO segments VALUES (?, ?, ?, ?, ?)", arguments: [segment.id, recording.id, speaker.id, segment.start, try JSONEncoder().encode(segment)])
            }
        }
        let migrated = try LibraryDatabase(url: url)
        XCTAssertEqual(try migrated.recordings(), [recording])
        XCTAssertEqual(try migrated.transcript(recordingID: recording.id).segments, [segment])
        XCTAssertEqual(try migrated.transcript(recordingID: recording.id).speakers, [speaker])
        XCTAssertTrue(try migrated.folders().isEmpty)
        XCTAssertTrue(try migrated.folderAssignments().isEmpty)
        let folder = RecordingFolder(name: "Existing", color: .red)
        try migrated.saveFolder(folder)
        try migrated.moveRecordings([recording.id], toFolder: folder.id)
        XCTAssertEqual(try migrated.folderAssignments(), [recording.id: folder.id])
    }
}
