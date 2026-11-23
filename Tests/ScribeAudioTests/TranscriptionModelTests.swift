import XCTest
import FluidAudio
@testable import Scribe

final class TranscriptionModelTests: XCTestCase {
    func testCatalogIncludesTheModelsAndParametersUsedByTheDiarizer() {
        let speakerComponents = TranscriptionModelComponent.allCases.filter { $0.phase == .speakers }
        XCTAssertEqual(speakerComponents.count, 4)
        let files = speakerComponents.map(\.files).joined(separator: ", ")
        for file in ModelNames.OfflineDiarizer.requiredModels {
            XCTAssertTrue(files.contains(file), "Missing downloaded component: \(file)")
        }
        XCTAssertTrue(TranscriptionModelComponent.whisper.files.contains(TranscriptionService.modelName))
        XCTAssertEqual(TranscriptionModelComponent.tokenizer.phase, .tokenizer)
        for component in TranscriptionModelComponent.allCases {
            XCTAssertFalse(component.purpose.isEmpty)
            XCTAssertEqual(component.source.host, "huggingface.co")
        }
    }

    func testComponentStatusesFollowSetupStagesAndPreserveCompletedDownloadsAfterFailure() {
        let whisper = TranscriptionModelComponent.whisper
        let tokenizer = TranscriptionModelComponent.tokenizer
        let speaker = TranscriptionModelComponent.embedding
        XCTAssertEqual(whisper.status(available: [], phase: .waiting, isPreparing: false), .notReady)
        XCTAssertEqual(speaker.status(available: [], phase: .transcription, isPreparing: true), .waiting)
        XCTAssertEqual(whisper.status(available: [], phase: .transcription, isPreparing: true), .preparing)
        XCTAssertEqual(whisper.status(available: [], phase: .tokenizer, isPreparing: true), .ready)
        XCTAssertEqual(tokenizer.status(available: [], phase: .tokenizer, isPreparing: true), .preparing)
        XCTAssertEqual(speaker.status(available: [], phase: .speakers, isPreparing: true), .preparing)
        XCTAssertEqual(whisper.status(available: [.whisper], phase: .speakers, isPreparing: false), .ready)
        XCTAssertEqual(speaker.status(available: [.whisper], phase: .speakers, isPreparing: false), .notReady)
        XCTAssertEqual(speaker.status(available: [.embedding], phase: .transcription, isPreparing: true), .ready)
        for component in TranscriptionModelComponent.allCases {
            XCTAssertEqual(component.status(available: [], phase: .ready, isPreparing: true), .ready)
        }
    }

    func testAvailabilityReadsExistingDownloadsWithoutLoadingOrDownloadingModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-model-inventory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = TranscriptionService(modelsDirectory: root)
        let empty = await service.availableModelComponents()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let whisper = root.appendingPathComponent("whisper/model")
        try FileManager.default.createDirectory(at: whisper, withIntermediateDirectories: true)
        try whisper.path.write(to: root.appendingPathComponent("whisper-path.txt"), atomically: true, encoding: .utf8)
        let emptyFolder = await service.availableModelComponents()
        XCTAssertTrue(emptyFolder.isEmpty)
        for file in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(at: whisper.appendingPathComponent(file + ".mlmodelc"), withIntermediateDirectories: true)
        }
        let partial = await service.availableModelComponents()
        XCTAssertEqual(partial, [.whisper])

        let tokenizer = root.appendingPathComponent("tokenizer/models/openai/whisper-large-v3")
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
        let incompleteTokenizer = await service.availableModelComponents()
        XCTAssertFalse(incompleteTokenizer.contains(.tokenizer))
        try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer_config.json"))
        try Data().write(to: root.appendingPathComponent("speakers-ready"))
        let speakers = root.appendingPathComponent("speakers/\(Repo.diarizer.folderName)")
        try FileManager.default.createDirectory(at: speakers, withIntermediateDirectories: true)
        for file in ModelNames.OfflineDiarizer.requiredModels {
            try Data().write(to: speakers.appendingPathComponent(file))
        }
        let complete = await service.availableModelComponents()
        XCTAssertEqual(complete, Set(TranscriptionModelComponent.allCases))
        let ready = await service.isPrepared()
        XCTAssertTrue(ready)

        try FileManager.default.removeItem(at: speakers.appendingPathComponent(ModelNames.OfflineDiarizer.pldaParameters))
        let missingParameters = await service.availableModelComponents()
        XCTAssertFalse(missingParameters.contains(.clustering))
        XCTAssertTrue(missingParameters.contains(.embedding))
        let noLongerReady = await service.isPrepared()
        XCTAssertFalse(noLongerReady)

        try FileManager.default.removeItem(at: whisper)
        let removed = await service.availableModelComponents()
        XCTAssertFalse(removed.contains(.whisper))
    }

    func testLegacySpeakerCachesAreRecognizedOnlyAfterSuccessfulPreparation() async throws {
        for layout in ["", "speaker-diarization", "speaker-diarization-offline"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-legacy-models-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = root.appendingPathComponent("speakers").appendingPathComponent(layout)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in ModelNames.OfflineDiarizer.requiredModels {
                try Data().write(to: folder.appendingPathComponent(file))
            }
            let service = TranscriptionService(modelsDirectory: root)
            let unfinished = await service.availableModelComponents()
            XCTAssertTrue(unfinished.isEmpty)
            try Data().write(to: root.appendingPathComponent("speakers-ready"))
            let prepared = await service.availableModelComponents()
            XCTAssertEqual(prepared, [.segmentation, .embedding, .filterbank, .clustering])
        }
    }

    func testDeletingModelCachePreservesRecordingsLibraryAndExternalModelPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-model-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("Models")
        let nested = cache.appendingPathComponent("speakers/partial-download")
        let recordings = root.appendingPathComponent("Recordings/meeting")
        let external = root.appendingPathComponent("shared-model")
        for folder in [nested, recordings, external] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let sentinel = Data("Keep this data".utf8)
        let library = root.appendingPathComponent("library.sqlite")
        let recording = recordings.appendingPathComponent("microphone.caf")
        let externalFile = external.appendingPathComponent("weights.bin")
        for file in [library, recording, externalFile, nested.appendingPathComponent("weights.partial")] {
            try sentinel.write(to: file)
        }
        try external.path.write(to: cache.appendingPathComponent("whisper-path.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: cache.appendingPathComponent("speakers-ready"))

        let service = TranscriptionService(modelsDirectory: cache)
        try await service.deleteDownloadedModels()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        let available = await service.availableModelComponents()
        XCTAssertTrue(available.isEmpty)
        let ready = await service.isPrepared()
        XCTAssertFalse(ready)
        for file in [library, recording, externalFile] {
            XCTAssertEqual(try Data(contentsOf: file), sentinel)
        }
        // A fresh installation or a repeated reset has no cache to remove.
        try await service.deleteDownloadedModels()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
}
