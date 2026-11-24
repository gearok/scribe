import AVFoundation
import ScribeCore

enum AudioCompressor {
    /// Stream one track at a time off the main thread; keep each original until its
    /// replacement is fully decoded and verified. An interrupted run is safe to retry.
    static func compress(in directory: URL) throws {
        try Task.checkCancellation()
        // A hard quit can bypass defer. These are only this compressor's abandoned
        // staging files; final M4As and original CAFs must never be treated as scratch.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for file in files where file.pathExtension == "m4a" && file.lastPathComponent.hasPrefix(".compress-") {
                let suffix = file.deletingPathExtension().lastPathComponent.dropFirst(".compress-".count)
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if UUID(uuidString: String(suffix)) != nil, values.isRegularFile == true, values.isSymbolicLink != true {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
        for track in [AudioTrack.system, .microphone] {
            try Task.checkCancellation()
            let source = directory.appendingPathComponent(track.filename)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = RecordingStorage.compressedURL(for: track, in: directory)
            let temporary = directory.appendingPathComponent(".compress-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try encode(source: source, destination: temporary)
            try verify(source: source, compressed: temporary)
            let originalSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let compressedSize = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard compressedSize > 0, compressedSize < originalSize else { continue }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            // Until here the complete PCM track remains available, even after a crash.
            try FileManager.default.removeItem(at: source)
        }
    }

    private static func encode(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        defer { input.close() }
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: input.processingFormat.channelCount,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        defer { output.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else {
            throw ScribeError.message("Could not read the recorded audio.")
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw ScribeError.message("Could not read the recorded audio.") }
            try output.write(from: buffer)
        }
    }

    private static func verify(source: URL, compressed: URL) throws {
        let original = try AVAudioFile(forReading: source)
        let archive = try AVAudioFile(forReading: compressed)
        defer { original.close(); archive.close() }
        guard archive.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              archive.processingFormat.sampleRate == original.processingFormat.sampleRate,
              archive.processingFormat.channelCount == original.processingFormat.channelCount,
              archive.length == original.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: archive.processingFormat, frameCapacity: 8192) else {
            throw ScribeError.message("The compressed audio could not be verified.")
        }
        // Validate the full file, rather than trusting its header or checking only the start.
        var decoded: AVAudioFramePosition = 0
        while archive.framePosition < archive.length {
            try Task.checkCancellation()
            try archive.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw ScribeError.message("The compressed audio could not be verified.")
            }
            for channel in 0..<Int(buffer.format.channelCount) {
                guard UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)).allSatisfy(\.isFinite) else {
                    throw ScribeError.message("The compressed audio could not be verified.")
                }
            }
            decoded += Int64(buffer.frameLength)
        }
        guard decoded == original.length else {
            throw ScribeError.message("The compressed audio could not be verified.")
        }
    }
}
