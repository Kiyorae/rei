import ReiCore
import SwiftUI

/// The conversation pane: transcript above, composer below.
struct ChatView: View {
    let environment: AppEnvironment
    let inspect: (Chat, ConversationInspectorSection) -> Void
    let showingInspector: Bool
    let toggleInspector: () -> Void
    var showcase: ShowcaseSession? = nil
    @State private var drafts: [ComposerDraftKey: ComposerDraft] = [:]
    @State private var pendingHistoryClear: PendingHistoryClear?
    @State private var historyClearError: String?

    var body: some View {
        if let chat = environment.selectedChat {
            let draftKey = ComposerDraftKey(chat: chat, senderID: environment.activeUserID)
            VStack(spacing: 0) {
                header
                Divider()
                transcript(for: chat)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Composer(
                    environment: environment,
                    chat: chat,
                    senderID: draftKey.senderID,
                    draft: draftBinding(for: draftKey)
                )
                .id(draftKey)
                .frame(maxWidth: 900)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .navigationTitle(title(for: chat))
            .navigationSubtitle(subtitle(for: chat))
            .confirmationDialog(
                pendingHistoryClear.map { "Clear all messages in \($0.title)?" }
                    ?? "Clear Chat History?",
                isPresented: historyClearConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Clear Chat History", role: .destructive) {
                    guard let request = pendingHistoryClear else { return }
                    pendingHistoryClear = nil
                    Task { await clearHistory(request.chat) }
                }
                Button("Cancel", role: .cancel) {
                    pendingHistoryClear = nil
                }
            } message: {
                Text(
                    "This permanently deletes every message saved in this conversation. "
                        + "The friend or group chat will not be deleted."
                )
            }
            .alert("Unable to Clear Chat History", isPresented: historyClearErrorPresented) {
                Button("OK") { historyClearError = nil }
            } message: {
                Text(historyClearError ?? "Unknown error")
            }
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                ContentUnavailableView(
                    "No Conversation Selected", systemImage: "bubble.left.and.bubble.right",
                    description: Text(
                        "Select a conversation in the sidebar, or create a persona to start simulating a chat.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        ChatPaneHeader(
            environment: environment, inspect: inspect,
            showingInspector: showingInspector, toggleInspector: toggleInspector
        )
        .id(environment.selectedChat)
    }

    private func transcript(for chat: Chat) -> some View {
        ChatTranscript(
            environment: environment, chat: chat, showcase: showcase,
            reply: { reply(to: $0, in: chat) }, reveal: { reveal($0, in: chat) },
            clearHistory: {
                pendingHistoryClear = PendingHistoryClear(chat: chat, title: environment.conversationTitle(for: chat))
            }
        )
        .id(chat)
    }

    private func reply(to message: Message, in chat: Chat) {
        guard !message.isRecalled, environment.canInteract(in: chat) else { return }
        let key = ComposerDraftKey(chat: chat, senderID: environment.activeUserID)
        var draft = drafts[key] ?? ComposerDraft()
        guard !draft.isSending else { return }
        draft.replyTo = message.id
        draft.focusRequest = UUID()
        drafts[key] = draft
    }

    private func reveal(_ id: Message.ID, in chat: Chat) {
        Task {
            await environment.revealMessage(id: id, in: chat)
        }
    }

    /// Drafts are window-local and keyed by the stable conversation identity, so
    /// switching chats never moves unfinished text into another recipient.
    private func draftBinding(for key: ComposerDraftKey) -> Binding<ComposerDraft> {
        Binding(
            get: { drafts[key] ?? ComposerDraft() },
            set: { value in
                if value.isEmpty {
                    drafts.removeValue(forKey: key)
                } else {
                    drafts[key] = value
                }
            }
        )
    }

    private var historyClearConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingHistoryClear != nil },
            set: { if !$0 { pendingHistoryClear = nil } }
        )
    }

    private var historyClearErrorPresented: Binding<Bool> {
        Binding(
            get: { historyClearError != nil },
            set: { if !$0 { historyClearError = nil } }
        )
    }

    private func clearHistory(_ chat: Chat) async {
        do {
            try await environment.clearMessageHistory(in: chat)
            historyClearError = nil
        } catch {
            historyClearError = error.localizedDescription
        }
    }

    private func title(for chat: Chat) -> String {
        environment.conversationTitle(for: chat)
    }

    private func subtitle(for chat: Chat) -> String {
        switch chat.scene {
        case .group: return "Group \(chat.peerID)"
        case .friend:
            let peerID = environment.displayedPeerID(for: chat) ?? chat.peerID
            return environment.isFriend(chat.peerID)
                ? "Friend \(peerID)"
                : "Not a Friend \(peerID)"
        case .temp:
            return "Temporary Chat \(environment.displayedPeerID(for: chat) ?? chat.peerID)"
        }
    }
}

private struct PendingHistoryClear {
    let chat: Chat
    let title: String
}

struct ComposerDraftKey: Hashable {
    let chat: Chat
    let senderID: User.ID?
}
