import Combine

/// High-frequency capture updates belong to the meter/clock views, rather than
/// invalidating the library, transcript, settings, and updater on every audio buffer.
@MainActor
final class RecordingActivity: ObservableObject {
    @Published var elapsed = 0.0
    @Published var microphoneLevel: Float = 0
    @Published var systemLevel: Float = 0

    func reset() {
        elapsed = 0
        microphoneLevel = 0
        systemLevel = 0
    }
}
