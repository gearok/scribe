import XCTest
import ScribeCore
import Combine
@testable import Scribe

@MainActor
final class AppModelTests: XCTestCase {
    func testRecordingMeterUpdatesDoNotInvalidateTheLibraryModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-meter-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(isDemo: true, dataDirectory: root)
        var libraryUpdates = 0, meterUpdates = 0
        let library = model.objectWillChange.sink { libraryUpdates += 1 }
        let meters = model.recordingActivity.objectWillChange.sink { meterUpdates += 1 }
        model.recordingActivity.elapsed = 1
        model.recordingActivity.microphoneLevel = 0.5
        model.recordingActivity.systemLevel = 0.25
        XCTAssertEqual(libraryUpdates, 0)
        XCTAssertEqual(meterUpdates, 3)
        withExtendedLifetime((library, meters)) {}
    }

    func testMetadataEditsRetainCachedAudioSizesAndCannotRestoreDeletedRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-metadata-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(isDemo: true, dataDirectory: root)
        let recording = try XCTUnwrap(model.selectedRecording)
        let folder = model.directory(for: recording)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 123).write(to: folder.appendingPathComponent("system.caf"))
        model.renameRecording(recording, title: "Renamed")
        model.changeLanguage(recording, to: .english)
        XCTAssertTrue(model.createFolder(name: "Another folder"))
        XCTAssertEqual(model.recordingByteCounts[recording.id], 0, "Metadata edits must not rescan audio.")
        try model.reload()
        XCTAssertEqual(model.recordingByteCounts[recording.id], 123)
        model.delete(recording)
        model.renameRecording(recording, title: "Delayed focus callback")
        model.changeLanguage(recording, to: .russian)
        try model.reload()
        XCTAssertFalse(model.recordings.contains { $0.id == recording.id })
    }

    func testTranscriptSearchUsesLocalizedSpeakerDisplayNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-speaker-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(isDemo: true, dataDirectory: root)
        // Do not change the persisted interface preference for this regression check.
        let local = try XCTUnwrap(model.speakers.first(where: \.isLocal))
        model.transcriptSearch = local.displayName(in: model.interfaceLanguage)
        XCTAssertFalse(model.filteredSegments.isEmpty)
        XCTAssertTrue(model.filteredSegments.allSatisfy { $0.speakerID == local.id })
    }

    func testRecordingSizesIncludeBothTracksWithoutAFolderAndRefreshOnReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-recording-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(isDemo: true, dataDirectory: root)
        let recording = try XCTUnwrap(model.recordings.first { model.folder(for: $0) == nil })
        XCTAssertEqual(model.recordingByteCounts[recording.id], 0)
        let directory = model.directory(for: recording)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let system = directory.appendingPathComponent(AudioTrack.system.filename)
        let microphone = directory.appendingPathComponent(AudioTrack.microphone.filename)
        try Data(repeating: 0, count: 2048).write(to: system)
        try Data(repeating: 0, count: 1024).write(to: microphone)
        try Data(repeating: 0, count: 512).write(to: directory.appendingPathComponent("notes.txt"))
        try model.reload()
        XCTAssertEqual(model.recordingByteCounts[recording.id], 3072)
        try Data(repeating: 0, count: 4096).write(to: system)
        try FileManager.default.removeItem(at: microphone)
        try model.reload()
        XCTAssertEqual(model.recordingByteCounts[recording.id], 4096)
    }

    func testFolderCreationScopedSearchMovesAndReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-folder-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(isDemo: true, dataDirectory: root)
        let meeting = try XCTUnwrap(model.selectedRecording)
        let allIDs = Set(model.recordings.map(\.id))
        XCTAssertFalse(model.createFolder(name: "  \n ", color: .red))
        XCTAssertTrue(model.createFolder(name: "  Project  "))
        let project = try XCTUnwrap(model.selectedFolder)
        XCTAssertEqual(project.name, "Project")
        XCTAssertEqual(project.color, .gray)
        XCTAssertNil(model.selectedRecording)
        XCTAssertTrue(model.filteredRecordings.isEmpty)

        model.search = "Планирование"
        XCTAssertTrue(model.filteredRecordings.isEmpty) // Never leak matches from other folders.
        XCTAssertTrue(model.moveRecordings([meeting.id], toFolder: project.id))
        XCTAssertEqual(model.filteredRecordings.map(\.id), [meeting.id])
        XCTAssertEqual(model.folder(for: meeting), project)
        model.select(meeting.id)
        let work = try XCTUnwrap(model.folders.first { $0.id != project.id })
        model.selectFolder(work.id)
        XCTAssertTrue(model.filteredRecordings.isEmpty)
        XCTAssertNil(model.selectedRecording)
        model.selectFolder(nil)
        XCTAssertEqual(model.filteredRecordings.map(\.id), [meeting.id])
        model.search = ""
        XCTAssertEqual(Set(model.filteredRecordings.map(\.id)), allIDs)

        model.selectFolder(project.id)
        XCTAssertEqual(model.selectedID, meeting.id)
        XCTAssertTrue(model.moveRecordings([meeting.id], toFolder: nil))
        XCTAssertNil(model.selectedID)
        XCTAssertTrue(model.filteredRecordings.isEmpty)
        XCTAssertTrue(model.moveRecordings([meeting.id], toFolder: project.id))
        XCTAssertFalse(model.moveRecordings(["outside-this-library"], toFolder: project.id))
        XCTAssertFalse(model.moveRecordings([meeting.id], toFolder: "missing-folder"))
        model.selectFolder("missing-folder")
        XCTAssertEqual(model.selectedFolderID, project.id)

        let reopened = AppModel(isDemo: false, dataDirectory: root)
        XCTAssertEqual(reopened.folders.first { $0.id == project.id }, project)
        XCTAssertEqual(reopened.folderAssignments[meeting.id], project.id)
        XCTAssertEqual(Set(reopened.filteredRecordings.map(\.id)), allIDs)
        XCTAssertNil(model.errorMessage)
    }

    func testInterfaceLanguageSwitchPersistsAndPreservesRecordingContent() throws {
        let defaults = UserDefaults.standard
        let oldLanguage = defaults.object(forKey: "interfaceLanguage")
        let oldAppleLanguages = defaults.object(forKey: "AppleLanguages")
        defer {
            defaults.set(oldLanguage, forKey: "interfaceLanguage")
            defaults.set(oldAppleLanguages, forKey: "AppleLanguages")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-language-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(isDemo: true, dataDirectory: root)
        let selected = try XCTUnwrap(model.selectedRecording)
        let localSpeaker = try XCTUnwrap(model.speakers.first(where: \.isLocal))
        model.renameSpeaker(localSpeaker, name: "You")
        let transcript = model.segments
        let transcriptionLanguage = model.defaultLanguage
        model.interfaceLanguage = .english
        XCTAssertEqual(L10n.text("Settings"), "Settings")
        model.interfaceLanguage = .russian
        XCTAssertEqual(L10n.text("Settings"), "Настройки")
        XCTAssertEqual(model.selectedRecording, selected)
        XCTAssertEqual(model.segments, transcript)
        XCTAssertEqual(model.defaultLanguage, transcriptionLanguage)
        XCTAssertEqual(model.speaker(for: localSpeaker.id)?.displayName, "You")
        let reopened = AppModel(isDemo: false, dataDirectory: root)
        XCTAssertEqual(reopened.interfaceLanguage, .russian)
        XCTAssertEqual(reopened.selectedRecording, selected)
        XCTAssertEqual(reopened.speaker(for: localSpeaker.id)?.displayName, "You")
    }

    func testSpeakerEditsRemainCorrectWhenSwitchingRecordings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-app-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(isDemo: true, dataDirectory: root)
        let meeting = try XCTUnwrap(model.selectedRecording)
        let speaker = try XCTUnwrap(model.speakers.first(where: { !$0.isLocal }))
        let segment = try XCTUnwrap(model.segments.first(where: { $0.speakerID == speaker.id }))
        model.renameSpeaker(speaker, name: "Екатерина")
        model.editText(segment, text: "Исправленный текст.")
        let other = try XCTUnwrap(model.recordings.first(where: { $0.id != meeting.id }))
        model.select(other.id)
        XCTAssertTrue(model.segments.isEmpty)
        model.select(meeting.id)
        XCTAssertEqual(model.speaker(for: speaker.id)?.name, "Екатерина")
        XCTAssertEqual(model.segments.first(where: { $0.id == segment.id })?.text, "Исправленный текст.")
        XCTAssertNil(model.errorMessage)
    }

    func testMergeAndParagraphReassignmentRefreshTheVisibleTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-app-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(isDemo: true, dataDirectory: root)
        let remote = model.speakers.filter { !$0.isLocal }
        XCTAssertEqual(remote.count, 2)
        let segment = try XCTUnwrap(model.segments.first)
        model.reassign(segment, to: remote[1])
        XCTAssertEqual(model.segments.first?.speakerID, remote[1].id)
        model.mergeSpeaker(remote[1], into: remote[0])
        XCTAssertEqual(model.speakers.count, 2)
        XCTAssertFalse(model.segments.contains { $0.speakerID == remote[1].id })
        XCTAssertEqual(model.segments.first?.speakerID, remote[0].id)
        XCTAssertNil(model.errorMessage)
    }

    func testTextEditsInvalidateWordAlignmentButSpeakerChangesPreserveIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-word-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(isDemo: true, dataDirectory: root)
        var segment = try XCTUnwrap(model.segments.first)
        segment.words = [TimedWord(text: segment.text, start: segment.start, end: segment.end)]
        let speaker = try XCTUnwrap(model.speakers.first)
        model.reassign(segment, to: speaker)
        var saved = try XCTUnwrap(model.segments.first { $0.id == segment.id })
        XCTAssertEqual(saved.words, segment.words)
        model.editText(saved, text: saved.text)
        saved = try XCTUnwrap(model.segments.first { $0.id == segment.id })
        XCTAssertEqual(saved.words, segment.words)
        model.editText(saved, text: "Исправленный текст")
        let reopened = AppModel(isDemo: false, dataDirectory: root)
        let edited = try XCTUnwrap(reopened.segments.first { $0.id == segment.id })
        XCTAssertEqual(edited.text, "Исправленный текст")
        XCTAssertNil(edited.words)
    }
}
