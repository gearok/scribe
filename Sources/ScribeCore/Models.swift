import Foundation

public enum RecordingStatus: String, Codable, Sendable {
    case recording, captured, processing, ready, failed, interrupted
    public var label: String {
        switch self {
        case .recording: return "Recording"
        case .captured: return "Ready to transcribe"
        case .processing: return "Processing"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        case .interrupted: return "Recording interrupted"
        }
    }
}

public enum MeetingLanguage: String, Codable, CaseIterable, Sendable {
    case russian = "ru", english = "en", automatic = "auto"
    public var label: String {
        switch self {
        case .russian: return "Russian"
        case .english: return "English"
        case .automatic: return "Russian + English (auto)"
        }
    }
}

public struct Recording: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var duration: Double
    public var status: RecordingStatus
    public var language: MeetingLanguage
    public var sourceName: String
    public var hasMicrophone: Bool
    public var hasSystemAudio: Bool
    public var errorMessage: String?

    public init(id: String = UUID().uuidString, title: String, createdAt: Date = Date(), duration: Double = 0,
                status: RecordingStatus = .captured, language: MeetingLanguage = .russian,
                sourceName: String = "All system audio", hasMicrophone: Bool = true, hasSystemAudio: Bool = true,
                errorMessage: String? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.duration = duration
        self.status = status; self.language = language; self.sourceName = sourceName
        self.hasMicrophone = hasMicrophone; self.hasSystemAudio = hasSystemAudio; self.errorMessage = errorMessage
    }
}

public struct Speaker: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var recordingID: String
    public var name: String
    public var colorIndex: Int
    public var isLocal: Bool
    public var isNameCustomized: Bool?
    public init(id: String = UUID().uuidString, recordingID: String, name: String, colorIndex: Int, isLocal: Bool = false,
                isNameCustomized: Bool? = nil) {
        self.id = id; self.recordingID = recordingID; self.name = name; self.colorIndex = colorIndex; self.isLocal = isLocal
        self.isNameCustomized = isNameCustomized
    }
}

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var recordingID: String
    public var speakerID: String
    public var start: Double
    public var end: Double
    public var text: String
    public var track: AudioTrack
    public init(id: String = UUID().uuidString, recordingID: String, speakerID: String, start: Double,
                end: Double, text: String, track: AudioTrack) {
        self.id = id; self.recordingID = recordingID; self.speakerID = speakerID
        self.start = start; self.end = end; self.text = text; self.track = track
    }
}

public enum AudioTrack: String, Codable, Sendable {
    case microphone, system
    public var filename: String { rawValue + ".caf" }
}

public struct SpeakerTurn: Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker; self.start = start; self.end = end
    }
}

public struct TimedWord: Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public struct SpeechWindow: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public enum SpeechWindowBuilder {
    /// Keep speaker changes and longer pauses as language-detection boundaries. Overlap is recognized once.
    public static func windows(turns: [SpeakerTurn], duration: Double, maximumDuration: Double = 22) -> [SpeechWindow] {
        guard duration > 0, maximumDuration > 0 else { return [] }
        var ranges: [(speaker: String, start: Double, end: Double)] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) where turn.end > turn.start {
            let start = max(0, turn.start), end = min(duration, turn.end)
            guard end > start else { continue }
            if let last = ranges.last, start <= last.end || (last.speaker == turn.speaker && start - last.end < 0.65) {
                ranges[ranges.count - 1].end = max(last.end, end)
            } else { ranges.append((turn.speaker, start, end)) }
        }
        var windows: [SpeechWindow] = []
        for index in ranges.indices {
            let range = ranges[index]
            let previousEnd = index > 0 ? (ranges[index - 1].end + range.start) / 2 : 0
            let nextStart = index + 1 < ranges.count ? (range.end + ranges[index + 1].start) / 2 : duration
            var start = max(previousEnd, range.start - 0.18)
            let end = min(nextStart, range.end + 0.18)
            while start < end {
                let stop = min(end, start + maximumDuration)
                windows.append(SpeechWindow(start: start, end: stop))
                start = stop
            }
        }
        return windows
    }
}

/// Match words to the largest overlapping speaker turn, then join adjacent words from the same speaker.
/// Words with no matching turn remain explicitly unassigned instead of guessing a person's identity.
public enum TranscriptAssembler {
    public static func assemble(words: [TimedWord], turns: [SpeakerTurn], recordingID: String,
                                speakerIDs: [String: String], unknownID: String, track: AudioTrack) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        let sortedTurns = turns.sorted { $0.start < $1.start }
        var firstCandidate = 0
        for word in words.sorted(by: { $0.start < $1.start }) where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            while firstCandidate < sortedTurns.count && sortedTurns[firstCandidate].end <= word.start {
                firstCandidate += 1
            }
            var winner: String?
            var bestOverlap = 0.0
            for turn in sortedTurns.dropFirst(firstCandidate) {
                if turn.start >= word.end { break }
                let overlap = max(0, min(turn.end, word.end) - max(turn.start, word.start))
                if overlap > bestOverlap { bestOverlap = overlap; winner = turn.speaker }
            }
            let speakerID = winner.flatMap { speakerIDs[$0] } ?? unknownID
            if let last = result.last, last.speakerID == speakerID, word.start - last.end < 1.8,
               word.end - last.start < 35 {
                result[result.count - 1].text += word.text
                result[result.count - 1].end = max(last.end, word.end)
            } else {
                result.append(TranscriptSegment(recordingID: recordingID, speakerID: speakerID,
                                                start: max(0, word.start), end: max(word.start, word.end),
                                                text: word.text, track: track))
            }
        }
        for index in result.indices { result[index].text = result[index].text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return result
    }
}

public enum TimeLabel {
    public static func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(seconds)) : 0
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
