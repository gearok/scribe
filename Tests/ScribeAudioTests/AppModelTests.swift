import XCTest
import ScribeCore
@testable import Scribe

@MainActor
final class AppModelTests: XCTestCase {
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
}
