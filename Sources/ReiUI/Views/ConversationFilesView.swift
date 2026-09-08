import ReiCore
import SwiftUI

struct ConversationFilesView: View {
    @Bindable var model: ConversationContentModel
    @State private var editing: ConversationEntryEdit?
    @State private var moving: SharedFile?
    @State private var deleting: ConversationEntryDeletion?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if model.capabilities.supportsGroupContent {
                    Picker("Folder", selection: $model.selectedFolderID) {
                        Text("All Root Files").tag("/")
                        ForEach(model.folders) { folder in Text(folder.name).tag(folder.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    if model.capabilities.canManageGroupContent {
                        Menu("Folder", systemImage: "folder.badge.gearshape") {
                            Button("New Folder…") { editing = .newFolder }
                            if let folder = model.folders.first(where: { $0.id == model.selectedFolderID }) {
                                Button("Rename Folder…") { editing = .renameFolder(folder) }
                                Button("Delete Folder…", role: .destructive) { deleting = .folder(folder) }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Manage folders")
                    }
                }
                if !model.capabilities.supportsGroupContent { Spacer() }
                if model.capabilities.canInteract {
                    Button("Upload File…", systemImage: "square.and.arrow.up") {
                        Task {
                            guard let url = await ConversationContentPicker.chooseFile() else { return }
                            model.run { try await model.uploadFile(at: url) }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .help("Upload a file")
                }
            }
            .padding(12)
            Divider()
            if let files = model.visibleFiles {
                if files.isEmpty {
                    ContentUnavailableView("No Shared Files", systemImage: "folder")
                } else {
                    List(files) { file in
                        fileRow(file).padding(.vertical, 6)
                    }.listStyle(.inset)
                        .scrollContentBackground(.hidden)
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .task { await model.observeFiles() }
        .task { if model.chat.scene == .group { await model.observeFolders() } }
        .sheet(item: $editing) { edit in ConversationEntryEditor(model: model, edit: edit) }
        .sheet(item: $moving) { file in ConversationFileMoveSheet(model: model, file: file) }
        .confirmationDialog(
            "Delete Shared Content?",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), presenting: deleting
        ) { entry in
            Button("Delete", role: .destructive) {
                model.run {
                    switch entry {
                    case .file(let file): try await model.deleteFile(file)
                    case .folder(let folder): try await model.deleteFolder(folder)
                    }
                }
            }
        } message: { entry in
            switch entry {
            case .file(let file): Text("“\(file.name)” will be removed from the group's shared files.")
            case .folder(let folder):
                Text("“\(folder.name)” and every shared file in it will be removed from the group.")
            }
        }
    }

    private func fileRow(_ file: SharedFile) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc").font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(file.name).font(.callout.weight(.medium)).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.asset.byteCount), countStyle: .file))
                    Text(file.uploadedAt, style: .date)
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(model.environment.displayName(for: file.uploaderID, in: model.chat))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let expiry = file.expiresAt {
                    Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                AttachmentActionsView(
                    asset: namedAsset(file), environment: model.environment,
                    onAccess: { try await model.download(file) },
                    onError: { model.errorMessage = $0.localizedDescription }
                )
                .id(file.name)
                .disabled(!model.capabilities.canInteract)
            }
            Spacer(minLength: 8)
            if model.canEdit(file) {
                Menu("File Actions", systemImage: "ellipsis") {
                    Button("Rename…") { editing = .renameFile(file) }
                    Button("Move…") { moving = file }
                    if file.expiresAt != nil {
                        Button("Keep Permanently") { model.run { try await model.keepFile(file) } }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = .file(file) }
                }.labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private func namedAsset(_ file: SharedFile) -> Asset {
        var asset = file.asset
        asset.name = file.name
        return asset
    }
}

private enum ConversationEntryDeletion {
    case file(SharedFile)
    case folder(GroupFolder)
}
