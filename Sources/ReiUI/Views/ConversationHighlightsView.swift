import ReiCore
import SwiftUI

struct ConversationHighlightsView: View {
    let model: ConversationContentModel
    var didReveal: () -> Void
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            if model.capabilities.canManageGroupContent {
                HStack {
                    Spacer()
                    Button("Add Highlight…", systemImage: "star") { isAdding = true }
                }.padding(12)
            }
            if let messages = model.highlightedMessages {
                if messages.isEmpty {
                    ContentUnavailableView("No Highlighted Messages", systemImage: "star")
                } else {
                    List(messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(model.environment.displayName(for: message.senderID, in: model.chat)).font(
                                    .headline
                                )
                                .lineLimit(1)
                                Text(message.time, style: .date).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            Text(message.content.textPreview).lineLimit(4).textSelection(.enabled)
                            HStack {
                                Button("Go to Message", systemImage: "arrow.up.message") {
                                    Task { if await model.reveal(message) { didReveal() } }
                                }
                                if model.capabilities.canManageGroupContent {
                                    Button("Remove Highlight", systemImage: "star.slash") {
                                        model.run { try await model.setHighlight(message, enabled: false) }
                                    }
                                    .labelStyle(.iconOnly)
                                    .help("Remove highlight")
                                }
                            }.buttonStyle(.borderless).font(.caption)
                        }.padding(.vertical, 8)
                    }.listStyle(.inset)
                        .scrollContentBackground(.hidden)
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .task { await model.observeHighlights() }
        .sheet(isPresented: $isAdding) { ConversationHighlightPicker(model: model) }
    }
}

private struct ConversationHighlightPicker: View {
    let model: ConversationContentModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Message.ID?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlight a Recent Message").font(.headline)
            TextField("Search Messages", text: $search)
            List(candidates, selection: $selection) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.environment.displayName(for: message.senderID, in: model.chat)).font(
                        .caption.weight(.semibold))
                    Text(message.content.textPreview).lineLimit(3)
                }.tag(message.id).padding(.vertical, 4)
            }
            ConversationContentError(model: model)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Highlight") {
                    guard let message = candidates.first(where: { $0.id == selection }) else { return }
                    model.run {
                        try await model.setHighlight(message, enabled: true)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20).frame(width: 480, height: 430).disabled(model.isWorking)
    }

    private var candidates: [Message] {
        let existing = Set(model.highlightedMessages?.map(\.id) ?? [])
        return model.recentMessages.reversed().filter {
            !$0.isRecalled && !existing.contains($0.id)
                && (search.isEmpty || $0.content.textPreview.localizedCaseInsensitiveContains(search))
        }
    }
}
