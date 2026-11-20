import SwiftUI
import ScribeCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleteTarget: Recording?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
                .toolbar {
                    ToolbarItem(id: "import-audio") {
                        Button(L10n.text("Import Audio"), systemImage: "square.and.arrow.down") { model.importAudio() }
                            .labelStyle(.iconOnly)
                            .help(L10n.text("Import Audio"))
                            .disabled(model.isBusy || model.isDemo)
                    }
                    ToolbarItem(id: "new-recording", placement: .primaryAction) {
                        Button { model.showNewRecording = true } label: {
                            Image(nsImage: ScribeAssets.feather)
                        }
                        .accessibilityLabel(L10n.text("Start Recording"))
                        .help(L10n.text("Start Recording (⌘N)"))
                        .disabled(model.isBusy || model.isDemo)
                    }
                }
        } detail: {
            if let recording = model.selectedRecording {
                RecordingDetailView(recording: recording).id(recording.id)
            } else {
                welcome
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(L10n.text("Recordings"))
        .navigationSubtitle(model.isDemo ? L10n.text("Sample library") : L10n.count(model.recordings.count, noun: "recordings"))
        .tint(.yellow)
        .searchable(text: $model.search, placement: .toolbar, prompt: L10n.text("Search"))
        .frame(minWidth: 860, minHeight: 560)
        .sheet(isPresented: $model.showNewRecording) { NewRecordingSheet() }
        .sheet(isPresented: $model.showSettings) { SettingsSheet() }
        .sheet(isPresented: $model.showSpeakers) { SpeakersSheet() }
        .alert(L10n.text("Scribe needs your attention"), isPresented: Binding(get: {
            model.errorMessage != nil && !model.showSettings && !model.showNewRecording && !model.showSpeakers
        }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(L10n.text("OK")) { model.errorMessage = nil }
        } message: { Text(L10n.text(model.errorMessage ?? "")) }
        .alert(L10n.text("Delete recording?"), isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button(L10n.text("Cancel"), role: .cancel) { deleteTarget = nil }
            Button(L10n.text("Delete"), role: .destructive) {
                if let recording = deleteTarget { model.delete(recording) }
                deleteTarget = nil
            }
        } message: { Text(L10n.text("The recording, audio, and transcript will be permanently removed from this Mac.")) }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
            ForEach(groups) { group in
                if group.id != groups.first?.id {
                    RecordingDateSeparator(day: group.day)
                        .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                }
                ForEach(group.recordings) { recording in
                    RecordingRow(recording: recording, interfaceLanguage: model.interfaceLanguage)
                        .tag(recording.id)
                        .listRowInsets(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 16))
                        .listRowBackground(Group {
                            if recording.id == model.selectedID {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.yellow.opacity(0.4))
                                    .padding(.horizontal, 8)
                            }
                        })
                        .listRowSeparator(.hidden, edges: .top)
                        .listRowSeparator(recording.id == group.recordings.last?.id ? .hidden : .visible, edges: .bottom)
                        .listRowSeparatorTint(Color(nsColor: .separatorColor))
                        .contextMenu {
                            Button(L10n.text("Open")) { model.select(recording.id) }
                            Button(L10n.text("Show Audio in Finder"), systemImage: "folder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.directory(for: recording).path)
                            }.disabled(model.isDemo)
                            Divider()
                            Button(L10n.text("Delete Recording"), systemImage: "trash", role: .destructive) { deleteTarget = recording }
                                .disabled(recording.id == model.recordingID || recording.id == model.processingID)
                        }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.white)
        .background(RecordingListSelectionAppearance())
        .environment(\.colorScheme, .light)
        .overlay {
            if !model.search.isEmpty && model.filteredRecordings.isEmpty {
                ContentUnavailableView.search(text: model.search)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.modelsReady && !model.isDemo {
                Button { model.showSettings = true } label: {
                    Label(L10n.text(model.isPreparingModels ? "Preparing Models…" : "Set Up Transcription"), systemImage: "arrow.down.circle")
                }.padding()
            }
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) { Divider() }
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .vertical)
                .allowsHitTesting(false)
        }
    }

    private var groups: [RecordingGroup] {
        let calendar = Calendar.current
        return Dictionary(grouping: model.filteredRecordings) { calendar.startOfDay(for: $0.createdAt) }
            .map { RecordingGroup(day: $0.key, recordings: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label { Text(L10n.text("No Recording Selected")) } icon: { FeatherSymbol().frame(width: 48, height: 48) }
        } description: {
            Text(L10n.text("Record a meeting or import audio to create a private transcript on your Mac."))
        } actions: {
            Button(L10n.text("Start Recording"), systemImage: "mic") { model.showNewRecording = true }
                .primaryActionStyle().disabled(model.isBusy || model.isDemo)
            Button(L10n.text("Import Audio")) { model.importAudio() }.disabled(model.isBusy || model.isDemo)
            if model.isImporting { ProgressView(L10n.text("Importing audio…")) }
        }
    }

}

private struct RecordingGroup: Identifiable {
    var id: Date { day }
    let day: Date
    let recordings: [Recording]
}

private struct RecordingDateSeparator: View {
    let day: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(day, format: .dateTime.day().month(.wide).year())
                .font(.caption)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize()
            VStack { Divider() }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let interfaceLanguage: InterfaceLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.title).font(.headline).lineLimit(1)
            HStack(spacing: 8) {
                Text(RecordingPresentation.dateAndTime(recording.createdAt))
                    .fixedSize(horizontal: true, vertical: false)
                Text(L10n.text(recording.status == .ready ? recording.sourceName : recording.status.label, language: interfaceLanguage))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineLimit(1)
            }.font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recording.title), \(RecordingPresentation.dateAndTime(recording.createdAt)), \(L10n.text(recording.status.label)), \(TimeLabel.clock(recording.duration))")
    }
}

struct RecordingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var confirmRetranscription = false

    var body: some View {
        Group {
            if recording.status == .recording { RecordingInProgressView(recording: recording) }
            else if recording.status == .processing { processing }
            else if !model.segments.isEmpty { transcript }
            else { unprocessed }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if recording.status != .recording { PlaybackBar(player: model.playback, interfaceLanguage: model.interfaceLanguage).padding() }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(L10n.text("Speakers"), systemImage: "person.2") { model.showSpeakers = true }
                    .disabled(model.speakers.isEmpty).help(L10n.text("Manage Speakers"))
                Button(L10n.text("Export Transcript"), systemImage: "square.and.arrow.up") { model.exportTranscript() }
                    .disabled(model.segments.isEmpty).help(L10n.text("Export Transcript"))
            }
            ToolbarItem {
                Menu(L10n.text("Recording Actions"), systemImage: "ellipsis") {
                    Button(L10n.text("Rename Recording"), systemImage: "pencil") { titleFocused = true }
                    if recording.status != .recording && recording.status != .processing {
                        Button(L10n.text("Transcribe Again"), systemImage: "arrow.clockwise") {
                            if model.segments.isEmpty { model.process(recording) } else { confirmRetranscription = true }
                        }.disabled(model.isBusy || model.isDemo)
                    }
                }.menuIndicator(.hidden)
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

private struct PlaybackTranscriptView<Heading: View>: View {
    @ObservedObject var player: PlaybackController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let segments: [TranscriptSegment]
    let search: String
    let heading: Heading

    var body: some View {
        let playback = TranscriptPlaybackState(segments: segments, position: player.position, isPlaying: player.isPlaying)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    heading.padding(.bottom, 8)
                    ForEach(segments) { segment in
                        TranscriptParagraph(segment: segment, isActive: playback.activeSegmentIDs.contains(segment.id))
                            .id(segment.id)
                    }
                    if segments.isEmpty { ContentUnavailableView.search(text: search) }
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onChange(of: playback.followingSegmentID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

private struct TranscriptParagraph: View {
    @EnvironmentObject private var model: AppModel
    let segment: TranscriptSegment
    let isActive: Bool
    @State private var rename = false
    @State private var name = ""
    @State private var editing = false
    @State private var editedText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let speaker = model.speaker(for: segment.speakerID) {
                    Button(speaker.displayName) { name = speaker.displayName; rename = true }
                        .buttonStyle(.borderless).font(.headline).foregroundStyle(.primary)
                        .help(L10n.format("Rename %@", speaker.displayName))
                }
                Button(TimeLabel.clock(segment.start)) { model.playback.playSegment(segment) }
                    .buttonStyle(.borderless).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help(L10n.format("Play from %@", TimeLabel.clock(segment.start))).disabled(!model.playback.hasAudio)
                    .accessibilityValue(isActive ? L10n.text("Now Playing") : "")
                Spacer()
                Menu(L10n.text("Paragraph Actions"), systemImage: "ellipsis") {
                    Button(L10n.text("Edit Text"), systemImage: "pencil") { editedText = segment.text; editing = true }
                    Menu(L10n.text("Assign Speaker")) {
                        ForEach(model.speakers) { speaker in Button(speaker.displayName) { model.reassign(segment, to: speaker) } }
                    }
                    Button(L10n.text("Play From Here"), systemImage: "play") { model.playback.playSegment(segment) }.disabled(!model.playback.hasAudio)
                }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Text(segment.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .leading) {
            if isActive {
                Capsule().fill(.tint).frame(width: 3).offset(x: -14)
                    .accessibilityHidden(true)
            }
        }
        .alert(L10n.text("Rename Speaker"), isPresented: $rename) {
            TextField(L10n.text("Name"), text: $name)
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text("Save")) { if let speaker = model.speaker(for: segment.speakerID) { model.renameSpeaker(speaker, name: name) } }
        } message: { Text(L10n.text("This name will appear throughout this recording.")) }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("Edit Transcript")).font(.headline)
                TextEditor(text: $editedText).frame(minHeight: 180)
                HStack {
                    Spacer()
                    Button(L10n.text("Cancel"), role: .cancel) { editing = false }.keyboardShortcut(.cancelAction)
                    Button(L10n.text("Save")) { model.editText(segment, text: editedText); editing = false }.keyboardShortcut(.defaultAction)
                }
            }.padding().frame(width: 520)
        }
    }
}

struct PlaybackBar: View {
    @ObservedObject var player: PlaybackController
    let interfaceLanguage: InterfaceLanguage
    var body: some View {
        HStack(spacing: 16) {
            Button(L10n.text(player.isPlaying ? "Pause" : "Play", language: interfaceLanguage), systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large)
                .disabled(!player.hasAudio).help(L10n.text(player.isPlaying ? "Pause" : "Play Recording", language: interfaceLanguage))
            Text(TimeLabel.clock(player.position)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
                .disabled(!player.hasAudio).accessibilityLabel(L10n.text("Playback position"))
            Text(TimeLabel.clock(player.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("Playback Speed"), selection: $player.rate) {
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { value in
                    Text("\(value.formatted(.number.locale(interfaceLanguage.locale)))×").tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 62)
            .disabled(!player.hasAudio)
        }.padding().playbackSurface()
    }
}

private struct RecordingInProgressView: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording
    var body: some View {
        VStack(spacing: 24) {
            Label(L10n.text("Recording"), systemImage: "record.circle.fill").foregroundStyle(.red)
            Text(TimeLabel.clock(model.elapsed)).font(.largeTitle).monospacedDigit()
            Form {
                LabeledContent(L10n.text("Microphone")) {
                    ProgressView(value: Double(model.microphoneLevel)).accessibilityLabel(L10n.text("Microphone level"))
                }
                if recording.hasSystemAudio {
                    LabeledContent(L10n.text("Meeting Audio")) {
                        ProgressView(value: Double(model.systemLevel)).accessibilityLabel(L10n.text("Meeting audio level"))
                    }
                }
            }.formStyle(.grouped).scrollDisabled(true).frame(width: 360, height: 140)
            Button(L10n.text(model.modelsReady ? "Stop & Transcribe" : "Stop Recording"), systemImage: "stop.fill") { model.stopRecording() }
                .primaryActionStyle()
            Text(L10n.text(recording.sourceName)).font(.callout).foregroundStyle(.secondary)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
