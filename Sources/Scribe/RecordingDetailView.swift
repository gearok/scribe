import SwiftUI
import ScribeCore

struct RecordingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var confirmRetranscription = false

    var body: some View {
        Group {
            if recording.status == .recording { RecordingInProgressView(recording: recording, activity: model.recordingActivity) }
            else if recording.status == .processing { processing }
            else if !model.segments.isEmpty { transcript }
            else { unprocessed }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.compressionID == recording.id && recording.status != .processing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Compressing audio…")).font(.callout).foregroundStyle(.secondary)
                }.padding(8)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if recording.status != .recording { PlaybackBar(player: model.playback, interfaceLanguage: model.interfaceLanguage).padding() }
        }
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            } else {
                ToolbarItem(placement: .automatic) { Spacer() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(L10n.text("Speakers"), systemImage: "person.2") { model.showSpeakers = true }
                    .disabled(model.speakers.isEmpty).help(L10n.text("Manage Speakers"))
                Button(L10n.text("Export Transcript"), systemImage: "square.and.arrow.up") { model.exportTranscript() }
                    .disabled(model.segments.isEmpty).help(L10n.text("Export Transcript"))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu(L10n.text("Recording Actions"), systemImage: "ellipsis") {
                    Button(L10n.text("Rename Recording"), systemImage: "pencil") { titleFocused = true }
                    if recording.status != .recording && recording.status != .processing {
                        if model.uncompressedRecordingIDs.contains(recording.id) {
                            Button(L10n.text("Compress Audio"), systemImage: "archivebox") { model.compressRecording(recording) }
                                .disabled(model.isBusy || model.isDemo)
                        }
                        Button(L10n.text("Transcribe Again"), systemImage: "arrow.clockwise") {
                            if model.segments.isEmpty { model.process(recording) } else { confirmRetranscription = true }
                        }.disabled(model.isBusy || model.isDemo)
                    }
                }.menuIndicator(.hidden)
            }
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(id: "transcript-search", placement: .primaryAction) {
                RecordingSearchField(text: $model.transcriptSearch, focusRequest: $model.transcriptSearchFocusRequest,
                                     placeholder: L10n.text("Search Transcript"), shortcutHint: "⌘F", usesToolbarBackground: true)
                    .frame(width: 260)
                    .disabled(model.segments.isEmpty)
            }
        }
        .onAppear { title = recording.title }
        .onChange(of: titleFocused) { _, focused in if !focused { model.renameRecording(recording, title: title) } }
        .onChange(of: recording.title) { _, value in if !titleFocused { title = value } }
        .confirmationDialog(L10n.text("Transcribe this recording again?"), isPresented: $confirmRetranscription) {
            Button(L10n.text("Replace Transcript")) { model.process(recording) }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("The new transcript will replace text corrections, speaker assignments, and custom names. Your original audio will be kept."))
        }
    }

    private var documentHeading: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(recording.createdAt, format: .dateTime.day().month(.wide).year().hour().minute())
                .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            TextField(L10n.text("Meeting Title"), text: $title)
                .textFieldStyle(.plain).font(.largeTitle.bold()).focused($titleFocused)
                .onSubmit { model.renameRecording(recording, title: title); titleFocused = false }
                .accessibilityLabel(L10n.text("Meeting title"))
        }
    }

    private var transcript: some View {
        PlaybackTranscriptView(player: model.playback, segments: model.filteredSegments,
                               search: model.transcriptSearch, heading: documentHeading)
    }

    private var processing: some View {
        VStack(spacing: 16) {
            Text(L10n.text("Preparing Transcript")).font(.title2)
            Text(L10n.text(model.processingStep)).foregroundStyle(.secondary)
            if let progress = model.processingProgress { ProgressView(value: progress).frame(maxWidth: 280) }
            else { ProgressView().controlSize(.small) }
            Text(L10n.text("Processing on your Mac. Your recording is saved.")).font(.callout).foregroundStyle(.secondary)
            Button(L10n.text("Cancel Processing")) { model.cancelProcessing() }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unprocessed: some View {
        ContentUnavailableView {
            Label(L10n.text(recording.status == .ready ? "No Speech Detected" : "Recording Saved"), systemImage: "waveform")
        } description: {
            Text(L10n.text(recording.errorMessage ?? (recording.status == .ready
                 ? "Try another language or check the captured audio."
                 : "Create a transcript with individual speaker labels.")))
        } actions: {
            Picker(L10n.text("Language"), selection: Binding(get: { recording.language }, set: { model.changeLanguage(recording, to: $0) })) {
                ForEach(MeetingLanguage.allCases, id: \.self) { Text(L10n.text($0.label)).tag($0) }
            }.fixedSize()
            Button(L10n.text(model.modelsReady ? "Transcribe Recording" : "Set Up Transcription"), systemImage: "text.bubble") { model.process(recording) }
                .primaryActionStyle().disabled(model.isBusy || model.isDemo)
        }
    }
}
