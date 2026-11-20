import Foundation
import GRDB

public final class LibraryDatabase: @unchecked Sendable {
    private let queue: DatabaseQueue

    public init(url: URL) throws {
        queue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("library-v1") { db in
            try db.create(table: "recordings") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .datetime).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "speakers") { t in
                t.column("id", .text).primaryKey()
                t.column("recordingID", .text).notNull().references("recordings", onDelete: .cascade)
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "segments") { t in
                t.column("id", .text).primaryKey()
                t.column("recordingID", .text).notNull().references("recordings", onDelete: .cascade)
                t.column("speakerID", .text).notNull().references("speakers")
                t.column("start", .double).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(index: "segments_by_recording", on: "segments", columns: ["recordingID", "start"])
            try db.create(index: "speakers_by_recording", on: "speakers", columns: ["recordingID"])
        }
        try migrator.migrate(queue)
    }

    public func recordings() throws -> [Recording] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM recordings ORDER BY createdAt DESC").map { row in
                try JSONDecoder().decode(Recording.self, from: row["payload"])
            }
        }
    }

    public func save(_ recording: Recording) throws {
        try queue.write { db in try Self.saveRecording(recording, db: db) }
    }

    private static func saveRecording(_ recording: Recording, db: Database) throws {
        try db.execute(sql: "INSERT INTO recordings (id, createdAt, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET createdAt=excluded.createdAt, payload=excluded.payload",
                       arguments: [recording.id, recording.createdAt, try JSONEncoder().encode(recording)])
    }

    public func transcript(recordingID: String) throws -> (speakers: [Speaker], segments: [TranscriptSegment]) {
        try queue.read { db in
            let speakers = try Row.fetchAll(db, sql: "SELECT payload FROM speakers WHERE recordingID=? ORDER BY rowid", arguments: [recordingID])
                .map { try JSONDecoder().decode(Speaker.self, from: $0["payload"]) }
            let segments = try Row.fetchAll(db, sql: "SELECT payload FROM segments WHERE recordingID=? ORDER BY start, rowid", arguments: [recordingID])
                .map { try JSONDecoder().decode(TranscriptSegment.self, from: $0["payload"]) }
            return (speakers, segments)
        }
    }

    public func saveTranscript(recording: Recording, speakers: [Speaker], segments: [TranscriptSegment]) throws {
        try queue.write { db in
            try Self.saveRecording(recording, db: db)
            try db.execute(sql: "DELETE FROM segments WHERE recordingID=?", arguments: [recording.id])
            try db.execute(sql: "DELETE FROM speakers WHERE recordingID=?", arguments: [recording.id])
            for speaker in speakers {
                try db.execute(sql: "INSERT INTO speakers (id, recordingID, payload) VALUES (?, ?, ?)",
                               arguments: [speaker.id, speaker.recordingID, try JSONEncoder().encode(speaker)])
            }
            for segment in segments { try Self.saveSegment(segment, db: db) }
        }
    }

    public func saveSpeaker(_ speaker: Speaker) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE speakers SET payload=? WHERE id=? AND recordingID=?",
                           arguments: [try JSONEncoder().encode(speaker), speaker.id, speaker.recordingID])
        }
    }

    public func saveSegment(_ segment: TranscriptSegment) throws {
        try queue.write { db in try Self.saveSegment(segment, db: db) }
    }

    private static func saveSegment(_ segment: TranscriptSegment, db: Database) throws {
        try db.execute(sql: "INSERT INTO segments (id, recordingID, speakerID, start, payload) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET speakerID=excluded.speakerID, start=excluded.start, payload=excluded.payload",
                       arguments: [segment.id, segment.recordingID, segment.speakerID, segment.start, try JSONEncoder().encode(segment)])
    }

    public func mergeSpeaker(_ source: Speaker, into destination: Speaker) throws {
        guard source.recordingID == destination.recordingID, source.id != destination.id else { return }
        try queue.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT payload FROM segments WHERE recordingID=? AND speakerID=?",
                                        arguments: [source.recordingID, source.id])
            for row in rows {
                var segment = try JSONDecoder().decode(TranscriptSegment.self, from: row["payload"])
                segment.speakerID = destination.id
                try Self.saveSegment(segment, db: db)
            }
            try db.execute(sql: "DELETE FROM speakers WHERE id=?", arguments: [source.id])
        }
    }

    public func delete(recordingID: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM segments WHERE recordingID=?", arguments: [recordingID])
            try db.execute(sql: "DELETE FROM speakers WHERE recordingID=?", arguments: [recordingID])
            try db.execute(sql: "DELETE FROM recordings WHERE id=?", arguments: [recordingID])
        }
    }
}
