import XCTest
import ScribeCore
@testable import Scribe

final class LocalizationTests: XCTestCase {
    func testBothLanguagesCoverTheSameKeysAndKeepFormatArguments() throws {
        func table(_ language: InterfaceLanguage) throws -> [String: String] {
            let url = try XCTUnwrap(L10n.bundle(for: language).url(forResource: "Localizable", withExtension: "strings"))
            let contents = try String(contentsOf: url, encoding: .utf8)
            return try XCTUnwrap((contents as NSString).propertyListFromStringsFileFormat() as? [String: String])
        }
        let english = try table(.english), russian = try table(.russian)
        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        let placeholders = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:ld|d|@)"#)
        func arguments(_ value: String) -> [String] {
            placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                (value as NSString).substring(with: $0.range)
            }
        }
        for key in english.keys {
            XCTAssertFalse(russian[key]!.isEmpty, key)
            XCTAssertEqual(arguments(english[key]!), arguments(russian[key]!), key)
            XCTAssertEqual(L10n.text(key, language: .russian), russian[key], key)
        }
        XCTAssertEqual(L10n.text("Start Recording", language: .russian), "Начать запись")
        XCTAssertEqual(L10n.text("Start Recording", language: .english), "Start Recording")
        XCTAssertEqual(L10n.format("Rename %@", "Александр", language: .russian), "Переименовать: Александр")
    }

    func testRussianCountsHandleTeensAndCompoundNumbers() {
        for (value, expected) in [(0, "0 записей"), (1, "1 запись"), (2, "2 записи"), (5, "5 записей"),
                                  (11, "11 записей"), (21, "21 запись"), (22, "22 записи"), (111, "111 записей")] {
            XCTAssertEqual(L10n.count(value, noun: "recordings", language: .russian), expected)
        }
        XCTAssertEqual(L10n.count(1, noun: "recordings", language: .english), "1 recording")
        XCTAssertEqual(L10n.count(2, noun: "recordings", language: .english), "2 recordings")
    }

    func testInterfacePreferencePersistsWithoutChangingTranscriptionPreference() throws {
        let suite = "scribe-language-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("auto", forKey: "defaultLanguage")
        XCTAssertEqual(InterfaceLanguage.saved(in: defaults), .russian)
        InterfaceLanguage.english.save(in: defaults)
        XCTAssertEqual(InterfaceLanguage.saved(in: try XCTUnwrap(UserDefaults(suiteName: suite))), .english)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
        InterfaceLanguage.russian.save(in: defaults)
        XCTAssertEqual(InterfaceLanguage.saved(in: defaults), .russian)
        XCTAssertEqual(defaults.string(forKey: "defaultLanguage"), "auto")
    }

    func testTranscriptTextSizePersistsAndStaysWithinItsSupportedRange() throws {
        let suite = "scribe-text-size-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(TranscriptTextSize.saved(in: defaults), TranscriptTextSize.defaultValue)

        TranscriptTextSize.save(21, in: defaults)
        XCTAssertEqual(TranscriptTextSize.saved(in: defaults), 21)

        TranscriptTextSize.save(100, in: defaults)
        XCTAssertEqual(TranscriptTextSize.saved(in: defaults), TranscriptTextSize.maximum)

        TranscriptTextSize.save(1, in: defaults)
        XCTAssertEqual(TranscriptTextSize.saved(in: defaults), TranscriptTextSize.minimum)
    }

    func testGeneratedSpeakerLabelsSwitchButCustomNamesRemainVerbatim() throws {
        var speaker = Speaker(recordingID: "test", name: "Speaker 2", colorIndex: 2)
        XCTAssertEqual(speaker.displayName(in: .russian), "Участник 2")
        XCTAssertEqual(speaker.displayName(in: .english), "Speaker 2")
        speaker.name = "You"; speaker.isLocal = true
        XCTAssertEqual(speaker.displayName(in: .russian), "Вы")
        speaker.isNameCustomized = true
        let restored = try JSONDecoder().decode(Speaker.self, from: JSONEncoder().encode(speaker))
        XCTAssertEqual(restored.displayName(in: .russian), "You")
        speaker.name = "Екатерина"
        XCTAssertEqual(speaker.displayName(in: .english), "Екатерина")
    }

    func testLegacySpeakerPayloadDecodesWithoutCustomizationFlag() throws {
        let data = Data(#"{"id":"speaker","recordingID":"recording","name":"You","colorIndex":0,"isLocal":true}"#.utf8)
        let speaker = try JSONDecoder().decode(Speaker.self, from: data)
        XCTAssertNil(speaker.isNameCustomized)
        XCTAssertEqual(speaker.displayName(in: .russian), "Вы")
        XCTAssertEqual(speaker.displayName(in: .english), "You")
    }
}
