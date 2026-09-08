import ReiCore
import SwiftUI

/// Conversation-scoped profile editing and request flows for the current persona.
struct ConversationManagementView: View {
    let environment: AppEnvironment
    let chat: Chat

    @State private var groupName = ""
    @State private var selectedMemberID: User.ID?
    @State private var card = ""
    @State private var title = ""
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var requestKind: ConversationRequestKind?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        LabeledContent(
                            "Speaking As", value: environment.displayName(for: environment.activeUserID ?? "", in: nil))
                    }
                    if chat.scene == .group {
                        groupProfile
                    }
                    requestActions
                    if !hasActions {
                        Section {
                            Text("There are no conversation settings available for this identity.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .disabled(isSubmitting)
            }
        }
        .task(id: chat) { await load() }
        .onChange(of: selectedMemberID) { _, _ in loadSelectedMember() }
        .onChange(of: environment.activeUserID) { _, _ in loadSelectedMember() }
        .sheet(item: $requestKind) { kind in
            ConversationManagementRequestSheet(environment: environment, chat: chat, kind: kind)
        }
        .alert("Unable to Update Conversation", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var groupProfile: some View {
        if environment.canRenameGroup(in: chat) {
            Section("Group Profile") {
                TextField("Group Name", text: $groupName)
                Button("Save Group Name") {
                    let name = groupName
                    submit { try await environment.renameGroup(in: chat, name: name) }
                }
                .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        if !editableMembers.isEmpty {
            Section("Member Profile") {
                Picker("Member", selection: $selectedMemberID) {
                    ForEach(editableMembers) { member in
                        Text(environment.displayName(for: member.userID, in: chat))
                            .tag(Optional(member.userID))
                    }
                }
                if let member = selectedMember {
                    if environment.canEditMemberCard(member, in: chat) {
                        TextField("Group Nickname", text: $card, prompt: Text("Use account nickname"))
                        Button("Save Nickname") {
                            let value = card
                            submit { try await environment.editMemberCard(member.userID, in: chat, card: value) }
                        }
                    }
                    if environment.canEditMemberTitle(member, in: chat) {
                        TextField("Custom Title", text: $title, prompt: Text("No title"))
                        Button("Save Title") {
                            let value = title
                            submit { try await environment.editMemberTitle(member.userID, in: chat, title: value) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var requestActions: some View {
        if canRequest {
            Section("Requests") {
                if environment.canSendFriendRequest(in: chat) {
                    Button("Send Friend Request…", systemImage: "person.badge.plus") { requestKind = .friend }
                }
                if environment.canRequestToJoinGroup(in: chat) {
                    Button("Request to Join Group…", systemImage: "person.3") { requestKind = .joinGroup }
                }
                if environment.canInviteBotToGroup(in: chat) {
                    Button("Invite Bot to Group…", systemImage: "envelope") { requestKind = .inviteBot }
                }
            }
        }
    }

    private var canRequest: Bool {
        environment.canSendFriendRequest(in: chat) || environment.canRequestToJoinGroup(in: chat)
            || environment.canInviteBotToGroup(in: chat)
    }

    private var hasActions: Bool {
        environment.canRenameGroup(in: chat) || !editableMembers.isEmpty || canRequest
    }

    private var editableMembers: [GroupMember] {
        environment.members.values.filter {
            $0.groupID == chat.peerID
                && (environment.canEditMemberCard($0, in: chat) || environment.canEditMemberTitle($0, in: chat))
        }.sorted {
            environment.displayName(for: $0.userID, in: chat)
                .localizedStandardCompare(environment.displayName(for: $1.userID, in: chat)) == .orderedAscending
        }
    }

    private var selectedMember: GroupMember? {
        guard let selectedMemberID else { return nil }
        return editableMembers.first { $0.userID == selectedMemberID }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if chat.scene == .group {
                _ = try await environment.groupMembers(in: chat.peerID)
                groupName = try await environment.store.group(id: chat.peerID)?.name ?? ""
                selectedMemberID =
                    editableMembers.first { $0.userID == environment.activeUserID }?.userID
                    ?? editableMembers.first?.userID
                loadSelectedMember()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSelectedMember() {
        if selectedMember == nil { selectedMemberID = editableMembers.first?.userID }
        card = selectedMember?.card ?? ""
        title = selectedMember?.title ?? ""
    }

    private func submit(_ operation: @escaping @MainActor () async throws -> Void) {
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
