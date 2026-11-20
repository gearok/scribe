import AVFoundation
import ScribeCore

enum AudioImporter {
    /// Run off the main thread. Conversion completes for each block before the next
    /// read, keeping memory bounded even when disk reads outpace resampling.
    static func convert(source: URL, directory: URL) throws -> Double {
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writer = try AudioTrackWriter(url: directory.appendingPathComponent(AudioTrack.system.filename),
                                          startHostTime: 1, meter: { _ in })
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32_768) else {
            throw ScribeError.message("Could not open this audio file.")
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            let offset = Double(input.framePosition) / input.processingFormat.sampleRate
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else {
                throw ScribeError.message("Could not read the recorded audio.")
            }
            try writer.appendSynchronously(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: offset))
        }
        let duration = Double(input.length) / input.processingFormat.sampleRate
        try writer.finish(duration: duration)
        return duration
    }
}
