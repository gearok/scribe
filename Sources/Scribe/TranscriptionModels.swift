import Foundation
import FluidAudio

enum ModelSetupPhase: Int, Sendable {
    case waiting, transcription, tokenizer, speakers, ready

    var message: String {
        switch self {
        case .waiting: "Preparing downloads"
        case .transcription: "Downloading transcription model"
        case .tokenizer: "Preparing the transcription tokenizer"
        case .speakers: "Preparing speaker detection models"
        case .ready: "Models ready"
        }
    }
}

enum TranscriptionModelComponent: String, CaseIterable, Identifiable, Sendable {
    case whisper, tokenizer, segmentation, embedding, filterbank, clustering

    var id: String { rawValue }

    var name: String {
        switch self {
        case .whisper: "Whisper large-v3"
        case .tokenizer: "Whisper Tokenizer"
        case .segmentation: "Segmentation"
        case .embedding: "Embedding"
        case .filterbank: "FBank"
        case .clustering: "PLDA"
        }
    }

    var purpose: String {
        switch self {
        case .whisper: "Turns speech into text in Russian, English, and automatic language mode."
        case .tokenizer: "Vocabulary and text rules used by Whisper to read and write words."
        case .segmentation: "Finds speech regions and changes between speakers in meeting audio."
        case .embedding: "Compares voice characteristics to distinguish individual speakers."
        case .filterbank: "Prepares audio features for speaker recognition."
        case .clustering: "Groups voice samples belonging to the same speaker. Includes clustering parameters."
        }
    }

    var files: String {
        switch self {
        case .whisper: "\(TranscriptionService.modelName) · MelSpectrogram, AudioEncoder, TextDecoder"
        case .tokenizer: "openai/whisper-large-v3 · tokenizer.json, tokenizer_config.json"
        default: speakerFiles.joined(separator: ", ")
        }
    }

    var speakerFiles: [String] {
        switch self {
        case .segmentation: [ModelNames.OfflineDiarizer.segmentationFile]
        case .embedding: [ModelNames.OfflineDiarizer.embeddingFile]
        case .filterbank: [ModelNames.OfflineDiarizer.fbankFile]
        case .clustering: [ModelNames.OfflineDiarizer.pldaRhoFile, ModelNames.OfflineDiarizer.pldaParameters]
        default: []
        }
    }

    var source: URL {
        switch self {
        case .whisper: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml")!
        case .tokenizer: URL(string: "https://huggingface.co/openai/whisper-large-v3")!
        default: URL(string: "https://huggingface.co/\(Repo.diarizer.rawValue)")!
        }
    }

    var phase: ModelSetupPhase {
        switch self {
        case .whisper: .transcription
        case .tokenizer: .tokenizer
        default: .speakers
        }
    }

    func status(available: Set<Self>, phase: ModelSetupPhase, isPreparing: Bool) -> ModelComponentStatus {
        if isPreparing {
            if self.phase == phase { return .preparing }
            if self.phase.rawValue < phase.rawValue { return .ready }
            if available.contains(self) { return .ready }
            return .waiting
        }
        return available.contains(self) ? .ready : .notReady
    }
}

enum ModelComponentStatus: Equatable, Sendable {
    case notReady, waiting, preparing, ready

    var label: String {
        switch self {
        case .notReady: "Not Ready"
        case .waiting: "Waiting"
        case .preparing: "Downloading or Preparing"
        case .ready: "Ready to Use Offline"
        }
    }
}
