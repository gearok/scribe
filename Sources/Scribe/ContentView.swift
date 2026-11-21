import SwiftUI
import ScribeCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleteTarget: Recording?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var recordingsColumnWidth: CGFloat = 340

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { columnVisibility }, set: {
            // Only the folders column can collapse; keep recordings beside the transcript.
            columnVisibility = $0 == .detailOnly ? .doubleColumn : $0
        })) {
            FoldersSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            recordingsList
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { recordingsColumnWidth = $0 }
                .toolbar {
                    if #available(macOS 26, *) {
                        ToolbarItem(id: "folder-title", placement: .navigation) { folderTitle }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(id: "folder-title", placement: .navigation) { folderTitle }
                    }
                    // Keep library actions in this column even when the detail toolbar is empty.
                    ToolbarItem(id: "import-media", placement: .navigation) {
                        Button(L10n.text("Import Audio or Video"), systemImage: "square.and.arrow.down") { model.importMedia() }
                            .labelStyle(.iconOnly)
                            .help(L10n.text("Import Audio or Video"))
                            .disabled(model.isBusy || model.isDemo)
                    }
                    ToolbarItem(id: "new-recording", placement: .navigation) {
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
        .navigationTitle(model.selectedFolderTitle)
        .navigationSubtitle(recordingsSubtitle)
        .toolbar(removing: .title)
        .tint(.yellow)
        .frame(minWidth: 1080, minHeight: 560)
        .sheet(isPresented: $model.showNewRecording) { NewRecordingSheet() }
        .sheet(isPresented: $model.showNewFolder) { NewFolderSheet() }
        .sheet(isPresented: $model.showSettings) { SettingsSheet() }
        .sheet(isPresented: $model.showSpeakers) { SpeakersSheet() }
        .alert(L10n.text("Scribe needs your attention"), isPresented: Binding(get: {
            model.errorMessage != nil && !model.showSettings && !model.showNewRecording && !model.showNewFolder && !model.showSpeakers
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

    private var recordingsList: some View {
        List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
            ForEach(groups) { group in
                RecordingDateSeparator(day: group.day)
                    .listRowInsets(EdgeInsets(top: group.id == groups.first?.id ? 12 : 20,
                                             leading: 8, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                ForEach(group.recordings) { recording in
                    RecordingRow(recording: recording, interfaceLanguage: model.interfaceLanguage, folder: model.folder(for: recording))
                        .draggable(RecordingDragItem(id: recording.id))
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
                            RecordingFolderMenu(recording: recording)
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
        .background(Color(nsColor: .textBackgroundColor))
        .background(RecordingListSelectionAppearance())
        .overlay {
            if !model.search.isEmpty && model.filteredRecordings.isEmpty {
                ContentUnavailableView.search(text: model.search)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            RecordingSearchField(text: $model.search, focusRequest: $model.searchFocusRequest,
                                 placeholder: L10n.text("Search"))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color(nsColor: .textBackgroundColor))
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

    private var recordingsSubtitle: String {
        model.isDemo ? L10n.text("Sample library") : L10n.count(model.folderRecordings.count, noun: "recordings")
    }

    private var folderTitle: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.selectedFolderTitle).font(.headline).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(recordingsSubtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 0, maxWidth: 180, alignment: .leading)
        // Reserve the trailing native button group and toolbar margins within this column.
        .frame(width: columnVisibility == .all ? max(0, recordingsColumnWidth - 96) : nil, alignment: .leading)
        .help(model.selectedFolderTitle)
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
            Text(L10n.text("Record a meeting or import audio or video to create a private transcript on your Mac."))
        } actions: {
            Button(L10n.text("Start Recording"), systemImage: "mic") { model.showNewRecording = true }
                .primaryActionStyle().disabled(model.isBusy || model.isDemo)
            Button(L10n.text("Import Audio or Video")) { model.importMedia() }.disabled(model.isBusy || model.isDemo)
            if model.isImporting { ProgressView(L10n.text("Importing media…")) }
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
        VStack(alignment: .leading, spacing: 10) {
            Text(day, format: .dateTime.day().month(.wide).year())
                .font(.title3.bold())
                .foregroundStyle(.primary)
            Divider()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let interfaceLanguage: InterfaceLanguage
    let folder: RecordingFolder?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.title).font(.headline).lineLimit(1)
            HStack(spacing: 8) {
                Text(RecordingPresentation.dateAndTime(recording.createdAt))
                    .fixedSize(horizontal: true, vertical: false)
                Text(L10n.text(recording.status == .ready ? recording.sourceName : recording.status.label, language: interfaceLanguage))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineLimit(1)
            }.font(.subheadline)
            if let folder {
                Label(folder.name, systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recording.title), \(RecordingPresentation.dateAndTime(recording.createdAt)), \(L10n.text(recording.status.label)), \(TimeLabel.clock(recording.duration))\(folder.map { ", " + $0.name } ?? "")")
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
    @FocusState private var editorFocused: Bool

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
                Button(L10n.text("Copy Paragraph"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(editing ? editedText : segment.text, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help(L10n.text("Copy Paragraph"))
                Menu(L10n.text("Paragraph Actions"), systemImage: "ellipsis") {
                    Button(L10n.text("Edit Text"), systemImage: "pencil") { beginEditing() }
                    Menu(L10n.text("Assign Speaker")) {
                        ForEach(model.speakers) { speaker in Button(speaker.displayName) { model.reassign(segment, to: speaker) } }
                    }
                    Button(L10n.text("Play From Here"), systemImage: "play") { model.playback.playSegment(segment) }.disabled(!model.playback.hasAudio)
                }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        // Match the editor's line wrapping, including an empty final line.
                        Text(editedText + "\u{200B}")
                            .font(.body)
                            .padding(.horizontal, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden().accessibilityHidden(true)
                        TextEditor(text: $editedText)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .scrollDisabled(true)
                            .focused($editorFocused)
                            .accessibilityLabel(L10n.text("Edit Transcript"))
                            .onExitCommand { editing = false }
                            .task { editorFocused = true }
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(editorFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    HStack {
                        Spacer()
                        Button(L10n.text("Cancel"), role: .cancel) { editing = false }
                            .buttonStyle(.borderedProminent).tint(.gray)
                        Button(L10n.text("Save")) { saveEditing() }
                        .primaryActionStyle()
                        .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                // Keep Save and Cancel inside the editing region so Cancel never autosaves.
                .background(OutsideClickObserver(onOutsideClick: saveEditing))
            } else {
                Text(highlightedText).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture(count: 2).onEnded { beginEditing() })
                    .help(L10n.text("Double-click to edit this paragraph"))
            }
        }
        .overlay(alignment: .leading) {
            if isActive {
                Capsule().fill(.tint).frame(width: 3).offset(x: -14)
                    .accessibilityHidden(true)
            }
        }
        .onDisappear { saveEditing() }
        .alert(L10n.text("Rename Speaker"), isPresented: $rename) {
            TextField(L10n.text("Name"), text: $name)
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text("Save")) { if let speaker = model.speaker(for: segment.speakerID) { model.renameSpeaker(speaker, name: name) } }
        } message: { Text(L10n.text("This name will appear throughout this recording.")) }
    }

    private var highlightedText: AttributedString {
        var text = AttributedString(segment.text)
        let query = model.transcriptSearch
        guard !query.isEmpty else { return text }
        var remaining = segment.text.startIndex..<segment.text.endIndex
        while let match = segment.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                            range: remaining, locale: .current) {
            guard !match.isEmpty else { break }
            if let range = Range(match, in: text) {
                text[range].backgroundColor = .yellow.opacity(0.35)
            }
            remaining = match.upperBound..<segment.text.endIndex
        }
        return text
    }

    private func saveEditing() {
        guard editing else { return }
        editing = false
        if editedText.trimmingCharacters(in: .whitespacesAndNewlines) != segment.text {
            model.editText(segment, text: editedText)
        }
    }

    private func beginEditing() {
        model.playback.pause()
        editedText = segment.text
        editing = true
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
