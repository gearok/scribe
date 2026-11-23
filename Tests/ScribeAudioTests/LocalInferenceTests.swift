import XCTest
import AVFoundation
import ScribeCore
@testable import Scribe

/// Explicit opt-in: downloads public model weights, then processes locally synthesized speech.
/// Never opens the microphone or reads a user's recording library.
final class LocalInferenceTests: XCTestCase {
    func testRussianEnglishTranscriptionAndSpeakerDetection() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["SCRIBE_TEST_MODELS_DIR"] else {
            throw XCTSkip("Set SCRIBE_TEST_MODELS_DIR to run the local-model integration check.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-inference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let russian = directory.appendingPathComponent("russian.caf")
        let english = directory.appendingPathComponent("english.caf")
        try speak("Здравствуйте, коллеги. Сегодня мы обсуждаем наш новый проект. Нам нужно записать встречу и подготовить расшифровку разговора. Все данные остаются на компьютере.", voice: "Milena", to: russian)
        try speak("Thank you for joining this meeting. Let us discuss the project schedule and the next steps. We will review the design on Thursday and share our feedback.", voice: "Samantha", to: english)
        var duration = 0.0
        var writer: AudioTrackWriter? = try AudioTrackWriter(url: directory.appendingPathComponent("system.caf"), startHostTime: 1, meter: { _ in })
        for source in [russian, english] {
            let file = try AVAudioFile(forReading: source)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)!
            while file.framePosition < file.length {
                let offset = duration + Double(file.framePosition) / file.processingFormat.sampleRate
                try file.read(into: buffer)
                writer!.append(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: offset))
            }
            duration += Double(file.length) / file.processingFormat.sampleRate + 1
        }
        try writer!.finish(duration: duration)
        writer = nil
        // A silent microphone must not block the spoken system track.
        var silentWriter: AudioTrackWriter? = try AudioTrackWriter(url: directory.appendingPathComponent("microphone.caf"), startHostTime: 1, meter: { _ in })
        try silentWriter!.finish(duration: duration)
        silentWriter = nil
        let service = TranscriptionService(modelsDirectory: URL(fileURLWithPath: modelPath))
        if !(await service.isPrepared()) {
            try await service.prepare { phase, fraction in print("MODEL: \(phase.message) \(fraction.map { String(Int($0 * 100)) + "%" } ?? "")") }
        }
        let recording = Recording(title: "Synthetic integration fixture", duration: duration, language: .automatic,
                                  sourceName: "Generated test speech", hasMicrophone: true, hasSystemAudio: true)
        let (speakers, segments) = try await service.process(recording: recording, directory: directory) { message, _ in print("PROCESS: \(message)") }
        XCTAssertFalse(speakers.isEmpty)
        XCTAssertFalse(speakers.contains(where: \.isLocal))
        XCTAssertFalse(segments.isEmpty)
        let text = segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("проект") || text.contains("встреч"), "Expected Russian speech, received: \(text)")
        XCTAssertTrue(text.contains("meeting") || text.contains("project"), "Expected English speech, received: \(text)")
        XCTAssertTrue(segments.allSatisfy { $0.start >= 0 && $0.end <= duration + 1 })
        XCTAssertTrue(segments.allSatisfy { segment in speakers.contains { $0.id == segment.speakerID } })
        print("Local inference completed: \(speakers.count) speakers, \(segments.count) paragraphs, \(duration) seconds of synthesized audio.")

        // Reproduce the reported failure: silent system audio, speech on the Mac microphone.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("system.caf"))
        try FileManager.default.moveItem(at: directory.appendingPathComponent("microphone.caf"), to: directory.appendingPathComponent("system.caf"))
        try FileManager.default.copyItem(at: russian, to: directory.appendingPathComponent("microphone.caf"))
        let (localSpeakers, localSegments) = try await service.process(recording: recording, directory: directory) { _, _ in }
        XCTAssertEqual(localSpeakers.count, 1)
        XCTAssertEqual(localSpeakers.first?.isLocal, true)
        XCTAssertFalse(localSegments.isEmpty)
        XCTAssertTrue(localSegments.allSatisfy { $0.track == .microphone && $0.speakerID == localSpeakers.first?.id })
        XCTAssertTrue(localSegments.map(\.text).joined().lowercased().contains("проект"))

        // The explicit microphone-only source must also work without any system file.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("system.caf"))
        var micOnly = recording
        micOnly.hasSystemAudio = false
        let (_, micSegments) = try await service.process(recording: micOnly, directory: directory) { _, _ in }
        XCTAssertFalse(micSegments.isEmpty)

        // Entirely silent recordings finish normally with an empty transcript.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("microphone.caf"))
        silentWriter = try AudioTrackWriter(url: directory.appendingPathComponent("microphone.caf"), startHostTime: 1, meter: { _ in })
        try silentWriter!.finish(duration: 2)
        silentWriter = nil
        let (silentSpeakers, silentSegments) = try await service.process(recording: micOnly, directory: directory) { _, _ in }
        XCTAssertTrue(silentSpeakers.isEmpty)
        XCTAssertTrue(silentSegments.isEmpty)
    }

    private func speak(_ text: String, voice: String, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", destination.path, "--file-format=caff", "--data-format=LEF32@16000", text]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ScribeError.message("The \(voice) system voice is unavailable for the integration check.") }
    }
}
