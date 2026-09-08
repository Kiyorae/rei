import ReiCore
import SwiftUI

enum ConversationEntryEdit: Identifiable {
    case newFolder
    case renameFolder(GroupFolder)
    case renameFile(SharedFile)

    var id: String {
        switch self {
        case .newFolder: return "new-folder"
        case .renameFolder(let folder): return "folder:\(folder.id)"
        case .renameFile(let file): return "file:\(file.id)"
        }
    }
    var title: String {
        switch self {
        case .newFolder: return "New Folder"
        case .renameFolder: return "Rename Folder"
        case .renameFile: return "Rename File"
        }
    }
    var name: String {
        switch self {
        case .newFolder: return ""
        case .renameFolder(let folder): return folder.name
        case .renameFile(let file): return file.name
        }
    }
}

struct ConversationEntryEditor: View {
    let model: ConversationContentModel
    let edit: ConversationEntryEdit
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(model: ConversationContentModel, edit: ConversationEntryEdit) {
        self.model = model
        self.edit = edit
        _name = State(initialValue: edit.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(edit.title).font(.headline)
            TextField("Name", text: $name)
            ConversationContentError(model: model)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let value = name
                    model.run {
                        switch edit {
                        case .newFolder: try await model.createFolder(name: value)
                        case .renameFolder(let folder): try await model.renameFolder(folder, to: value)
                        case .renameFile(let file): try await model.renameFile(file, to: value)
                        }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 390).disabled(model.isWorking)
    }
}

struct ConversationFileMoveSheet: View {
    let model: ConversationContentModel
    let file: SharedFile
    @State private var folderID: String
    @Environment(\.dismiss) private var dismiss

    init(model: ConversationContentModel, file: SharedFile) {
        self.model = model
        self.file = file
        _folderID = State(initialValue: file.folderID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move “\(file.name)”").font(.headline)
            Picker("Destination", selection: $folderID) {
                Text("Root Folder").tag("/")
                ForEach(model.folders) { folder in Text(folder.name).tag(folder.id) }
            }
            ConversationContentError(model: model)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move") {
                    let target = folderID
                    model.run {
                        try await model.moveFile(file, to: target)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderID == file.folderID)
            }
        }
        .padding(20).frame(width: 390).disabled(model.isWorking)
    }
}
