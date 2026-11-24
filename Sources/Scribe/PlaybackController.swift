import AVFoundation
import Combine
import ScribeCore

@MainActor
final class PlaybackController: ObservableObject {
    @Published var isPlaying = false
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var rate: Float = 1 {
        didSet { players.forEach { $0.rate = rate } }
    }
    private var players: [AVAudioPlayer] = []
    private var timer: Timer?
    private var recordingID: String?

    deinit { timer?.invalidate() }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func load(_ recording: Recording?, directory: URL?) throws {
        guard recording?.id != recordingID else { return }
        pause(); players = []; position = 0; duration = recording?.duration ?? 0; recordingID = nil
        guard let recording, let directory else { return }
        var loaded: [AVAudioPlayer] = []
        for track in [AudioTrack.system, .microphone] {
            let url = RecordingStorage.audioURL(for: track, in: directory)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true; player.rate = rate; player.prepareToPlay()
            loaded.append(player)
        }
        players = loaded
        duration = max(duration, players.map(\.duration).max() ?? 0)
        recordingID = recording.id
    }

    var hasAudio: Bool { !players.isEmpty }

    func toggle() { isPlaying ? pause() : play() }
    func play() {
        guard let first = players.first else { return }
        if position >= duration - 0.1 { seek(to: 0) }
        // All players use the same device clock so microphone and system tracks start together.
        let when = first.deviceCurrentTime + 0.08
        players.forEach { _ = $0.play(atTime: when) }
        isPlaying = true
        startTimer()
    }
    func pause() {
        timer?.invalidate(); timer = nil
        players.forEach { $0.pause() }
        isPlaying = false
    }
    func seek(to value: Double) {
        position = min(max(0, value), duration)
        let playing = isPlaying
        pause()
        players.forEach { $0.currentTime = min(position, $0.duration) }
        if playing { play() }
    }
    func playSegment(_ segment: TranscriptSegment) { seek(to: segment.start); if !isPlaying { play() } }
    private func tick() {
        guard isPlaying else { return }
        position = players.map(\.currentTime).max() ?? 0
        if !players.contains(where: \.isPlaying) { pause(); position = duration }
    }
}
