import AVFoundation
import ScribeCore

enum AudioActivityScanner {
    /// A conservative silence gate, not a speech classifier. Whisper makes the speech decision.
    /// Stream 100 ms blocks so long recordings never need to be loaded into memory at once.
    static func windows(in url: URL) throws -> [SpeechWindow] {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / sampleRate
        let capacity = AVAudioFrameCount(sampleRate / 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            throw ScribeError.message("Could not read the recorded audio.")
        }
        var ranges: [SpeakerTurn] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let start = Double(file.framePosition) / sampleRate
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw ScribeError.message("The recorded audio has an unsupported format.")
            }
            let active = (0..<Int(buffer.format.channelCount)).contains { channel in
                UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
                    .contains { abs($0) > 0.00001 }
            }
            guard active else { continue }
            let end = Double(file.framePosition) / sampleRate
            if let last = ranges.last, start - last.end < 0.65 {
                ranges[ranges.count - 1].end = end
            } else {
                ranges.append(SpeakerTurn(speaker: "activity", start: start, end: end))
            }
        }
        return SpeechWindowBuilder.windows(turns: ranges, duration: duration)
    }
}
