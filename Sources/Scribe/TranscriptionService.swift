import Foundation
import AVFoundation
import WhisperKit
import FluidAudio
import ScribeCore

actor TranscriptionService {
    static let modelName = "large-v3-v20240930_626MB"
    let modelsDirectory: URL
    private var whisperFolder: URL { modelsDirectory.appendingPathComponent("whisper") }
    private var diarizerFolder: URL { modelsDirectory.appendingPathComponent("speakers") }
    private var tokenizerFolder: URL { modelsDirectory.appendingPathComponent("tokenizer") }
    private var modelPointer: URL { modelsDirectory.appendingPathComponent("whisper-path.txt") }

    init(modelsDirectory: URL) { self.modelsDirectory = modelsDirectory }

    func isPrepared() -> Bool {
        guard let path = try? String(contentsOf: modelPointer, encoding: .utf8) else { return false }
        return FileManager.default.fileExists(atPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            && FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent("speakers-ready").path)
    }

    func prepare(progress: @Sendable @escaping (String, Double?) async -> Void) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        await progress("Downloading transcription model", nil)
        let folder = try await WhisperKit.download(variant: Self.modelName, downloadBase: whisperFolder) { value in
            Task { await progress("Downloading transcription model", value.fractionCompleted) }
        }
        try Task.checkCancellation()
        try folder.path.write(to: modelPointer, atomically: true, encoding: .utf8)
        await progress("Preparing the transcription tokenizer", nil)
        _ = try await ModelUtilities.loadTokenizer(for: .largev3, tokenizerFolder: tokenizerFolder)
        await progress("Preparing speaker detection models", nil)
        ModelHub.offlineMode = false
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels(directory: diarizerFolder)
        try Task.checkCancellation()
        try Data().write(to: modelsDirectory.appendingPathComponent("speakers-ready"))
        await progress("Models ready", 1)
    }

    func process(recording: Recording, directory: URL,
                 progress: @Sendable @escaping (String, Double?) async -> Void) async throws -> ([ScribeCore.Speaker], [ScribeCore.TranscriptSegment]) {
        guard isPrepared(), let path = try? String(contentsOf: modelPointer, encoding: .utf8) else {
            throw ScribeError.message("Download the local models in Settings before transcribing.")
        }
        var wordsByTrack: [AudioTrack: [TimedWord]] = [:]
        var turnsByTrack: [AudioTrack: [SpeakerTurn]] = [:]
        var windowsByTrack: [AudioTrack: [SpeechWindow]] = [:]
        let tracks: [AudioTrack] = [.system, .microphone].filter {
            $0 == .system ? recording.hasSystemAudio : recording.hasMicrophone
        }
        // Check each source independently. Microphone speech already belongs to "You" and does
        // not need speaker clustering (which can reject short, otherwise transcribable clips).
        for track in tracks {
            try Task.checkCancellation()
            windowsByTrack[track] = try AudioActivityScanner.windows(in: directory.appendingPathComponent(track.filename))
        }
        // Release speaker models before loading Whisper. Each speech window gets a fresh
        // language decision, so English turns are not translated into Russian.
        ModelHub.offlineMode = true
        if !(windowsByTrack[.system] ?? []).isEmpty {
            await progress("Loading speaker detection models", nil)
            let diarizer = OfflineDiarizerManager()
            let models = try await OfflineDiarizerModels.load(from: diarizerFolder)
            diarizer.initialize(models: models)
            try Task.checkCancellation()
            let message = "Identifying individual speakers"
            await progress(message, nil)
            do {
                let result = try await diarizer.process(directory.appendingPathComponent(AudioTrack.system.filename)) { done, total in
                    Task { await progress(message, total > 0 ? Double(done) / Double(total) : nil) }
                }
                let turns = result.segments.map {
                    SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
                }
                turnsByTrack[.system] = turns
                if !turns.isEmpty {
                    let file = try AVAudioFile(forReading: directory.appendingPathComponent(AudioTrack.system.filename))
                    windowsByTrack[.system] = SpeechWindowBuilder.windows(turns: turns, duration: Double(file.length) / file.processingFormat.sampleRate)
                }
            } catch OfflineDiarizationError.noSpeechDetected {
                // Clustering can miss short/quiet speech. Let Whisper decide, retaining the
                // activity windows and leaving any resulting system words unassigned.
            }
        }
        try Task.checkCancellation()
        guard windowsByTrack.values.contains(where: { !$0.isEmpty }) else {
            await progress("No speech detected", 1)
            return ([], [])
        }
        await progress("Loading transcription model", nil)
        let whisper = try await WhisperKit(WhisperKitConfig(modelFolder: path.trimmingCharacters(in: .whitespacesAndNewlines), tokenizerFolder: tokenizerFolder,
                                                           verbose: false, prewarm: true, load: true, download: false))
        do {
            for track in tracks {
                try Task.checkCancellation()
                let file = try AVAudioFile(forReading: directory.appendingPathComponent(track.filename))
                let duration = Double(file.length) / file.processingFormat.sampleRate
                let windows = windowsByTrack[track] ?? []
                for (index, window) in windows.enumerated() {
                    try Task.checkCancellation()
                    let message = track == .microphone ? "Transcribing your microphone" : "Transcribing meeting audio"
                    await progress(message, Double(index) / Double(max(1, windows.count)))
                    let contextStart = max(0, window.start - 0.2)
                    let contextEnd = min(duration, window.end + 0.2)
                    file.framePosition = AVAudioFramePosition(contextStart * file.processingFormat.sampleRate)
                    let frameCount = AVAudioFrameCount((contextEnd - contextStart) * file.processingFormat.sampleRate)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { continue }
                    try file.read(into: buffer, frameCount: frameCount)
                    guard let channel = buffer.floatChannelData?[0] else { continue }
                    let audio = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                    let options = DecodingOptions(language: recording.language == .automatic ? nil : recording.language.rawValue,
                                                  usePrefillPrompt: recording.language != .automatic,
                                                  detectLanguage: recording.language == .automatic, skipSpecialTokens: true,
                                                  wordTimestamps: true, concurrentWorkerCount: 1)
                    let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
                    let words = results.flatMap(\.segments).filter { $0.noSpeechProb < 0.85 }.flatMap { segment -> [TimedWord] in
                        let words = (segment.words ?? []).map {
                            TimedWord(text: $0.word, start: contextStart + Double($0.start), end: contextStart + Double($0.end))
                        }
                        let fallback = TimedWord(text: segment.text, start: contextStart + Double(segment.start),
                                                 end: contextStart + Double(segment.end))
                        return TranscriptTiming.recognitionWords(words, fallback: fallback,
                                                                 within: SpeechWindow(start: contextStart, end: contextEnd))
                    }
                    wordsByTrack[track, default: []] += words.filter {
                        let middle = ($0.start + $0.end) / 2
                        return middle >= window.start && middle < window.end
                    }.map {
                        TimedWord(text: $0.text, start: max(window.start, $0.start), end: min(window.end, $0.end))
                    }
                }
            }
        } catch {
            await whisper.unloadModels()
            throw error
        }
        await whisper.unloadModels()
        try Task.checkCancellation()

        wordsByTrack = TranscriptDeduplicator.clean(wordsByTrack: wordsByTrack, turnsByTrack: turnsByTrack)
        try Task.checkCancellation()
        var speakers: [ScribeCore.Speaker] = []
        var segments: [ScribeCore.TranscriptSegment] = []
        if let micWords = wordsByTrack[.microphone], !micWords.isEmpty {
            let local = ScribeCore.Speaker(recordingID: recording.id, name: "You", colorIndex: 0, isLocal: true)
            speakers.append(local)
            segments += TranscriptAssembler.assemble(words: micWords, turns: [], recordingID: recording.id,
                                                      speakerIDs: [:], unknownID: local.id, track: .microphone)
        }
        if let remoteWords = wordsByTrack[.system], !remoteWords.isEmpty {
            let turns = turnsByTrack[.system] ?? []
            var speakerIDs: [String: String] = [:]
            for turn in turns.sorted(by: { $0.start < $1.start }) where speakerIDs[turn.speaker] == nil {
                let speaker = ScribeCore.Speaker(recordingID: recording.id, name: "Speaker \(speakerIDs.count + 1)", colorIndex: speakerIDs.count + 1)
                speakerIDs[turn.speaker] = speaker.id
                speakers.append(speaker)
            }
            let unassigned = ScribeCore.Speaker(recordingID: recording.id, name: "Unassigned", colorIndex: 5)
            let remoteSegments = TranscriptAssembler.assemble(words: remoteWords, turns: turns, recordingID: recording.id,
                                                               speakerIDs: speakerIDs, unknownID: unassigned.id, track: .system)
            if remoteSegments.contains(where: { $0.speakerID == unassigned.id }) { speakers.append(unassigned) }
            segments += remoteSegments
        }
        await progress("Finishing your transcript", 1)
        return (speakers, TranscriptInterleaver.interleave(segments))
    }
}

enum ScribeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return L10n.text(message) }; return nil }
}
