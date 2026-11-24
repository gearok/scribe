import SwiftUI
import UniformTypeIdentifiers
import ScribeCore

extension UTType {
    static let scribeRecording = UTType(exportedAs: "app.scribe.recording", conformingTo: .data)
}

struct RecordingDragItem: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .scribeRecording)
    }
}

private enum FolderSelection: Hashable {
    case all, folder(String)
}

struct FoldersSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let counts = Dictionary(grouping: model.folderAssignments.values, by: { $0 }).mapValues(\.count)
        return List(selection: Binding<FolderSelection?>(get: {
            model.selectedFolderID.map(FolderSelection.folder) ?? .all
        }, set: { selection in
            switch selection {
            case .folder(let id): model.selectFolder(id)
            case .all: model.selectFolder(nil)
            case nil: break
            }
        })) {
            Section(L10n.text("Folders")) {
                HStack {
                    Label(L10n.text("All Recordings"), systemImage: "tray.full")
                    Spacer()
                    Text(model.recordings.count, format: .number).foregroundStyle(.secondary)
                }
                .tag(FolderSelection.all)
                ForEach(model.folders) { folder in
                    FolderRow(folder: folder, count: counts[folder.id] ?? 0)
                        .tag(FolderSelection.folder(folder.id))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct FolderRow: View {
    @EnvironmentObject private var model: AppModel
    let folder: RecordingFolder
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Label(folder.name, systemImage: "folder")
                .lineLimit(1)
            Spacer()
            Text(count, format: .number).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Let the native sidebar own drop highlighting. Rebuilding the row's
        // background on hover competes with List's own drop indication.
        .dropDestination(for: RecordingDragItem.self) { items, _ in
            model.moveRecordings(items.map(\.id), toFolder: folder.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(L10n.count(count, noun: "recordings"))")
    }
}

struct NewFolderSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("New Folder")).font(.headline)
            LabeledContent(L10n.text("Folder Name")) {
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text("Folder Name"))
                    .focused($nameFocused)
            }
            HStack {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("Create Folder")) {
                    if model.createFolder(name: name) { dismiss() }
                }
                .primaryActionStyle().keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .task { nameFocused = true }
        .alert(L10n.text("Scribe needs your attention"), isPresented: Binding(get: { model.errorMessage != nil }, set: {
            if !$0 { model.errorMessage = nil }
        })) {
            Button(L10n.text("OK")) { model.errorMessage = nil }
        } message: { Text(L10n.text(model.errorMessage ?? "")) }
    }
}

struct RecordingFolderMenu: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording

    var body: some View {
        Menu(L10n.text("Move to Folder"), systemImage: "folder") {
            ForEach(model.folders) { folder in
                Button {
                    model.moveRecordings([recording.id], toFolder: folder.id)
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
                .disabled(model.folderAssignments[recording.id] == folder.id)
            }
            if model.folderAssignments[recording.id] != nil {
                Divider()
                Button(L10n.text("Remove from Folder")) { model.moveRecordings([recording.id], toFolder: nil) }
            }
        }
        .disabled(model.folders.isEmpty)
    }
}
