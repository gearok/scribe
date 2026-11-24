import Foundation
import ScribeCore

enum RecordingStorage {
    /// Both saved tracks belong to the recording, including imported media's extracted audio.
    static func audioByteCount(in directory: URL) -> Int64 {
        [AudioTrack.microphone, .system].reduce(0) { total, track in
            let values = try? directory.appendingPathComponent(track.filename)
                .resourceValues(forKeys: [.fileSizeKey])
            return total + Int64(values?.fileSize ?? 0)
        }
    }
}
