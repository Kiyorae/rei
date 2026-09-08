import ReiCore
import SwiftUI

enum ConversationRequestKind: String, Identifiable {
    case friend, joinGroup, inviteBot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friend: return "Send Friend Request"
        case .joinGroup: return "Request to Join Group"
        case .inviteBot: return "Invite Bot to Group"
        }
    }
}

struct ConversationManagementRequestSheet: View {
    let environment: AppEnvironment
    let chat: Chat
    let kind: ConversationRequestKind

    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(kind.title).font(.headline).padding(16)
            Form {
                LabeledContent("From", value: environment.displayName(for: environment.activeUserID ?? "", in: nil))
                LabeledContent("To", value: environment.displayName(for: chat.selfID, in: nil))
                if chat.scene == .group {
                    LabeledContent("Group", value: environment.conversationTitle(for: chat))
                }
                TextField("Message", text: $comment, axis: .vertical).lineLimit(3...5)
                Text("The request stays pending until the bot or a reviewer responds.")
                    .font(.callout).foregroundStyle(.secondary)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .disabled(isSubmitting)
            Divider()
            HStack {
                if isSubmitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("Send Request", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || !canSubmit)
            }
            .padding(12)
        }
        .frame(width: 440, height: 360)
    }

    private var canSubmit: Bool {
        switch kind {
        case .friend: return environment.canSendFriendRequest(in: chat)
        case .joinGroup: return environment.canRequestToJoinGroup(in: chat)
        case .inviteBot: return environment.canInviteBotToGroup(in: chat)
        }
    }

    private func submit() {
        isSubmitting = true
        let message = comment
        Task {
            defer { isSubmitting = false }
            do {
                switch kind {
                case .friend:
                    try await environment.sendFriendRequest(in: chat, comment: message)
                case .joinGroup:
                    try await environment.requestToJoinGroup(in: chat, comment: message)
                case .inviteBot:
                    try await environment.inviteBotToGroup(in: chat, comment: message)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
