import Foundation
import ScribeCore

enum RecordingStorage {
    static func compressedURL(for track: AudioTrack, in directory: URL) -> URL {
        directory.appendingPathComponent(track.rawValue + ".m4a")
    }

    /// Prefer the original while a replacement is being encoded or verified.
    static func audioURL(for track: AudioTrack, in directory: URL) -> URL {
        let original = directory.appendingPathComponent(track.filename)
        return FileManager.default.fileExists(atPath: original.path) ? original : compressedURL(for: track, in: directory)
    }

    static func hasUncompressedAudio(in directory: URL) -> Bool {
        [AudioTrack.microphone, .system].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path)
        }
    }

    /// Both saved tracks belong to the recording, including imported media's extracted audio.
    static func audioByteCount(in directory: URL) -> Int64 {
        [AudioTrack.microphone, .system].reduce(0) { total, track in
            // Count both if an interrupted replacement left the verified archive and original.
            [directory.appendingPathComponent(track.filename), compressedURL(for: track, in: directory)].reduce(total) { count, url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                return count + Int64(values?.fileSize ?? 0)
            }
        }
    }
}
