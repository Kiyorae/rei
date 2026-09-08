import ReiCore
import SwiftUI

/// One message bubble.
///
/// The transcript is rendered from the selected speaking identity's perspective:
/// its messages stay on the right and every other participant stays on the left.
/// `Message.direction` remains protocol-origin metadata and is deliberately not a
/// layout flag.
struct MessageRow: View {
    let message: Message
    let chat: Chat
    let environment: AppEnvironment
    var onReply: () -> Void = {}
    var onReveal: (Message.ID) -> Void = { _ in }
    @State private var isHovered = false
    @State private var showingReactionPicker = false
    @State private var confirmingRecall = false
    @State private var nudgeSent = false

    private var isFromActiveUser: Bool {
        guard let activeUserID = environment.activeUserID else { return false }
        return message.senderID == activeUserID
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isFromActiveUser { Spacer(minLength: 60) }

            if !isFromActiveUser {
                AvatarView(name: senderName, path: senderAvatar, size: 32)
            }

            VStack(alignment: isFromActiveUser ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message.time, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let badge = roleBadge {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .rect(cornerRadius: 3))
                    }
                }

                bubble

                if nudgeSent {
                    Text("Nudge sent").font(.caption).foregroundStyle(.secondary)
                }

                if !message.isRecalled, environment.supportsReactions(in: chat) {
                    MessageReactionsView(message: message, environment: environment)
                }
            }
            .frame(maxWidth: 640, alignment: isFromActiveUser ? .trailing : .leading)

            if isFromActiveUser {
                AvatarView(name: senderName, path: senderAvatar, size: 32)
            }
            if !isFromActiveUser { Spacer(minLength: 60) }
        }
        .onHover { isHovered = $0 }
        .overlay(alignment: isFromActiveUser ? .topLeading : .topTrailing) {
            if isHovered && !message.isRecalled {
                HStack(spacing: 8) {
                    Button(action: onReply) {
                        Label("Reply", systemImage: "arrowshape.turn.up.left").labelStyle(.iconOnly)
                    }
                    .help("Reply")
                    .disabled(!environment.canInteract(in: chat))
                    if environment.supportsReactions(in: chat) {
                        Button {
                            showingReactionPicker = true
                        } label: {
                            Label("Add Reaction", systemImage: "face.smiling").labelStyle(.iconOnly)
                        }
                        .help("Add reaction")
                        .disabled(!environment.canInteract(in: chat))
                    }
                    if environment.canRecall(message) {
                        Button {
                            confirmingRecall = true
                        } label: {
                            Label("Recall Message", systemImage: "trash").labelStyle(.iconOnly)
                        }
                        .help("Recall message")
                    }
                }
                .buttonStyle(.borderless)
                .padding(8)
                .background(.regularMaterial, in: .rect(cornerRadius: 8))
            }
        }
        .popover(isPresented: $showingReactionPicker) {
            ReactionPicker { reaction in
                showingReactionPicker = false
                Task { await environment.setReaction(reaction, on: message, added: true) }
            }
        }
        .onChange(of: environment.effectiveProtocol) { _, _ in
            if !environment.supportsReactions(in: chat) { showingReactionPicker = false }
        }
        .onChange(of: message.isRecalled) { _, recalled in
            if recalled { showingReactionPicker = false }
        }
        .confirmationDialog("Recall this message?", isPresented: $confirmingRecall, titleVisibility: .visible) {
            Button("Recall Message", role: .destructive) {
                Task { await environment.recall(message) }
            }
        } message: {
            Text("The message will be marked as recalled for everyone in this conversation.")
        }
        .contextMenu {
            if environment.supportsNudges(in: chat) {
                Button("Nudge \(senderName)", systemImage: "hand.point.right") {
                    Task {
                        nudgeSent = await environment.nudge(message.senderID, in: chat)
                        try? await Task.sleep(for: .seconds(2))
                        nudgeSent = false
                    }
                }
                .disabled(!environment.canInteract(in: chat))
            }
            if !message.isRecalled {
                Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
                    .disabled(!environment.canInteract(in: chat))
                if environment.supportsReactions(in: chat) {
                    Button("Add Reaction…", systemImage: "face.smiling") { showingReactionPicker = true }
                        .disabled(!environment.canInteract(in: chat))
                }
                Divider()
            }
            if canAddSenderAsFriend {
                Button("Add Friend", systemImage: "person.badge.plus") {
                    addSenderAsFriend()
                }
            }

            if privateConversation != nil {
                Button("Start Conversation", systemImage: "bubble.left") {
                    startConversationWithSender()
                }
            }

            if canAddSenderAsFriend || privateConversation != nil {
                Divider()
            }

            if environment.canRecall(message) {
                Button("Recall Message…", systemImage: "trash", role: .destructive) { confirmingRecall = true }
            }

            if !message.isRecalled {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content.plainText, forType: .string)
                }
            }

            Button("Copy Message ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.id, forType: .string)
            }
        }
    }

    private var senderActionsAvailable: Bool {
        guard chat.scene == .group,
            environment.botUserID == chat.selfID
        else {
            return false
        }
        return environment.users.contains { $0.id == message.senderID }
    }

    private var privateConversation: Chat? {
        guard senderActionsAvailable else { return nil }
        return environment.privateChat(with: message.senderID)
    }

    private var canAddSenderAsFriend: Bool {
        guard let privateConversation else { return false }
        return !environment.isFriend(privateConversation.peerID)
    }

    private func addSenderAsFriend() {
        guard canAddSenderAsFriend else { return }
        Task {
            do {
                try await environment.addFriend(with: message.senderID)
            } catch {
                environment.lastError = error.localizedDescription
            }
        }
    }

    private func startConversationWithSender() {
        guard privateConversation != nil else { return }
        environment.openPrivateChat(with: message.senderID)
    }

    @ViewBuilder
    private var bubble: some View {
        if message.isRecalled {
            Text(
                "Message recalled by \(environment.displayName(for: message.recalledBy ?? message.senderID, in: chat))"
            )
            .font(.callout)
            .italic()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: .rect(cornerRadius: 10))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, segment in
                    SegmentView(segment: segment, environment: environment, chat: chat, onReveal: onReveal)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isFromActiveUser
                    ? AnyShapeStyle(.tint.opacity(0.18))
                    : AnyShapeStyle(.quaternary),
                in: .rect(cornerRadius: 10)
            )
            .textSelection(.enabled)
        }
    }

    private var senderName: String {
        environment.displayName(for: message.senderID, in: chat)
    }

    private var senderAvatar: String? {
        environment.users.first { $0.id == message.senderID }?.avatar
    }

    /// Owner and admin labels, from the roster loaded when the chat opened.
    private var roleBadge: String? {
        guard message.scene == .group else { return nil }
        switch environment.role(of: message.senderID, in: message.peerID) {
        case .owner: return "Owner"
        case .admin: return "Admin"
        case .member, nil: return nil
        }
    }
}
