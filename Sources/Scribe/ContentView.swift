import SwiftUI
import ScribeCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleteTarget: Recording?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { columnVisibility }, set: {
            // Only the folders column can collapse; keep recordings beside the transcript.
            columnVisibility = $0 == .detailOnly ? .doubleColumn : $0
        })) {
            FoldersSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
                .toolbar {
                    if columnVisibility == .all || columnVisibility == .automatic {
                        // Navigation placement moves custom items past the sidebar divider.
                        // Automatic keeps this button beside the native sidebar toggle.
                        ToolbarItem(id: "new-folder", placement: .automatic) {
                            Button(L10n.text("New Folder"), systemImage: "folder.badge.plus") {
                                model.showNewFolder = true
                            }
                            .labelStyle(.iconOnly)
                            .help(L10n.text("New Folder"))
                        }
                    }
                    if #available(macOS 26, *) {
                        DefaultToolbarItem(kind: .sidebarToggle, placement: .automatic)
                    }
                }
        } content: {
            recordingsList
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
                .toolbar {
                    if #available(macOS 26, *) {
                        ToolbarItem(id: "folder-title", placement: .navigation) { folderTitle }
                            .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.flexible, placement: .navigation)
                    } else {
                        ToolbarItem(id: "folder-title", placement: .navigation) { folderTitle }
                        ToolbarItem(id: "folder-title-spacer", placement: .navigation) { Spacer() }
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
        let recordingGroups = groups
        return List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
            ForEach(recordingGroups) { group in
                RecordingDateSeparator(day: group.day)
                    .listRowInsets(EdgeInsets(top: group.id == recordingGroups.first?.id ? 12 : 20,
                                             leading: 8, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                ForEach(group.recordings) { recording in
                    RecordingRow(recording: recording, interfaceLanguage: model.interfaceLanguage,
                                 byteCount: model.recordingByteCounts[recording.id] ?? 0, folder: model.folder(for: recording))
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
                            if model.uncompressedRecordingIDs.contains(recording.id), recording.status != .recording && recording.status != .processing {
                                Button(L10n.text("Compress Audio"), systemImage: "archivebox") { model.compressRecording(recording) }
                                    .disabled(model.isBusy || model.isDemo)
                            }
                            Divider()
                            Button(L10n.text("Delete Recording"), systemImage: "trash", role: .destructive) { deleteTarget = recording }
                                .disabled(recording.id == model.recordingID || recording.id == model.processingID || recording.id == model.compressionID)
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
                .multilineTextAlignment(.center)
        } actions: {
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Button(L10n.text("Start Recording"), systemImage: "mic") { model.showNewRecording = true }
                        .primaryActionStyle().disabled(model.isBusy || model.isDemo)
                    Button(L10n.text("Import Audio or Video")) { model.importMedia() }
                        .disabled(model.isBusy || model.isDemo)
                }
                if model.isImporting { ProgressView(L10n.text("Importing media…")) }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
    let byteCount: Int64
    let folder: RecordingFolder?
    private var fileSize: String {
        byteCount.formatted(.byteCount(style: .file, spellsOutZero: false).locale(interfaceLanguage.locale))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.title).font(.headline).lineLimit(1)
            HStack(spacing: 8) {
                Text(RecordingPresentation.dateAndTime(recording.createdAt))
                    .fixedSize(horizontal: true, vertical: false)
                Text(L10n.text(recording.status == .ready ? recording.sourceName : recording.status.label, language: interfaceLanguage))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineLimit(1)
            }.font(.subheadline)
            HStack(spacing: 8) {
                Text(fileSize).fixedSize(horizontal: true, vertical: false)
                if let folder {
                    Label(folder.name, systemImage: "folder").lineLimit(1)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recording.title), \(RecordingPresentation.dateAndTime(recording.createdAt)), \(L10n.text(recording.status.label)), \(TimeLabel.clock(recording.duration)), \(fileSize)\(folder.map { ", " + $0.name } ?? "")")
    }
}
