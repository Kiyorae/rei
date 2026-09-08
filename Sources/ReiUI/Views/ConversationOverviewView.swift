import ReiCore
import SwiftUI

struct ConversationOverviewView: View {
    let model: ConversationContentModel
    @State private var likeCount = 1

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    AvatarView(
                        name: model.environment.conversationTitle(for: model.chat),
                        path: model.environment.conversationAvatar(for: model.chat),
                        isGroup: model.chat.scene == .group, size: 56
                    )
                    Text(model.environment.conversationTitle(for: model.chat))
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    Text(
                        model.chat.scene == .group
                            ? "Group Conversation"
                            : model.chat.scene == .temp ? "Temporary Conversation" : "Direct Conversation"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                LabeledContent(model.chat.scene == .group ? "Group ID" : "Account ID") {
                    Text(model.environment.displayedPeerID(for: model.chat) ?? model.chat.peerID)
                        .font(.callout.monospaced()).textSelection(.enabled)
                }
                if model.chat.scene == .group {
                    LabeledContent(
                        "Members",
                        value: "\(model.environment.members.values.filter { $0.groupID == model.chat.peerID }.count)")
                }
            }

            if model.capabilities.supportsState {
                Section("Conversation") {
                    Toggle(
                        "Pin Conversation",
                        isOn: Binding(
                            get: { model.state.isPinned },
                            set: { pinned in model.run { try await model.setPinned(pinned) } }
                        )
                    )
                    .disabled(!model.capabilities.canInteract)
                    LabeledContent("Read Status", value: readStatus)
                    Button("Mark All Messages as Read", systemImage: "checkmark.message") {
                        model.run { try await model.markRead() }
                    }
                    .disabled(!model.capabilities.canInteract || model.recentMessages.isEmpty)
                }
            }
            if model.capabilities.supportsProfileLikes, let target = model.profileUserID {
                Section("Profile Likes") {
                    LabeledContent("Profile", value: model.environment.displayName(for: target, in: model.chat))
                    LabeledContent("Total Likes") {
                        if let likes = model.profileLikes {
                            Text("\(likes.reduce(Int64(0), { $0 + $1.count }))")
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Stepper("Send \(likeCount) \(likeCount == 1 ? "Like" : "Likes")", value: $likeCount, in: 1...10)
                    Button("Send Likes", systemImage: "hand.thumbsup") {
                        let count = likeCount
                        model.run { try await model.likeProfile(count: count) }
                    }
                    .disabled(!model.capabilities.canInteract)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: model.profileUserID) { await model.observeLikes(for: model.profileUserID) }
    }

    private var readStatus: String {
        guard let latest = model.recentMessages.last else { return "No messages" }
        return model.state.lastReadSequence >= latest.seq ? "All messages read" : "Unread messages"
    }
}

struct ConversationContentError: View {
    let model: ConversationContentModel

    var body: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top, spacing: 6) {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                Button("Dismiss Error", systemImage: "xmark") { model.errorMessage = nil }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
    }
}
