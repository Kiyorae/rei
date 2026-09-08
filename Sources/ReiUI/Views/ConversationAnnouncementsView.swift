import AppKit
import ReiCore
import SwiftUI
import UniformTypeIdentifiers

struct ConversationAnnouncementsView: View {
    let model: ConversationContentModel
    @State private var isComposing = false
    @State private var deleting: GroupAnnouncement?

    var body: some View {
        VStack(spacing: 0) {
            if model.capabilities.canManageGroupContent {
                HStack {
                    Spacer()
                    Button("New Announcement…", systemImage: "plus") { isComposing = true }
                }.padding(12)
            }
            if let announcements = model.announcements {
                if announcements.isEmpty {
                    ContentUnavailableView("No Announcements", systemImage: "megaphone")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(announcements) { announcement in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(model.environment.displayName(for: announcement.senderID, in: model.chat))
                                            .font(.headline).lineLimit(1)
                                        Text(announcement.time, style: .date).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        if model.capabilities.canManageGroupContent {
                                            Button("Delete Announcement", systemImage: "trash", role: .destructive) {
                                                deleting = announcement
                                            }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                        }
                                    }
                                    if !announcement.content.isEmpty {
                                        Text(announcement.content).textSelection(.enabled)
                                    }
                                    if let image = announcement.image {
                                        ImageSegmentView(asset: image, environment: model.environment)
                                    }
                                }
                                Divider()
                            }
                        }.padding(16)
                    }
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .task { await model.observeAnnouncements() }
        .sheet(isPresented: $isComposing) { ConversationAnnouncementEditor(model: model) }
        .confirmationDialog(
            "Delete Announcement?",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), presenting: deleting
        ) { announcement in
            Button("Delete Announcement", role: .destructive) {
                model.run { try await model.deleteAnnouncement(announcement) }
            }
        } message: { _ in
            Text("This announcement will be removed from the group.")
        }
    }
}

private struct ConversationAnnouncementEditor: View {
    let model: ConversationContentModel
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var image: Asset?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Announcement").font(.headline)
            TextEditor(text: $content).frame(height: 150).border(Color(nsColor: .separatorColor))
                .accessibilityLabel("Announcement Text")
            if let image {
                HStack(alignment: .top) {
                    ImageSegmentView(asset: image, environment: model.environment)
                    Button("Remove Image", systemImage: "xmark.circle") { self.image = nil }
                }
            } else {
                Button("Add Image…", systemImage: "photo.badge.plus") {
                    Task {
                        guard let url = await ConversationContentPicker.chooseFile(imagesOnly: true) else { return }
                        model.run { image = try await model.importImage(at: url) }
                    }
                }
            }
            ConversationContentError(model: model)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Post Announcement") {
                    let text = content
                    let attachment = image
                    model.run {
                        try await model.postAnnouncement(content: text, image: attachment)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .disabled(model.isWorking)
    }
}

@MainActor
enum ConversationContentPicker {
    static func chooseFile(imagesOnly: Bool = false) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if imagesOnly { panel.allowedContentTypes = [.image] }
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
}
