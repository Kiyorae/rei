import ReiCore
import SwiftUI

struct GroupMembersView: View {
    let environment: AppEnvironment
    let groupID: ReiCore.Group.ID

    @State private var query = ""
    @State private var showingAddMember = false
    @State private var pendingRemoval: GroupMember?
    @State private var workingUserIDs: Set<User.ID> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Members")
                        .font(.headline)
                }

                Spacer()

                Button("Add Member", systemImage: "person.badge.plus") {
                    showingAddMember = true
                }
                .labelStyle(.iconOnly)
                .disabled(!canInviteMember)
                .help(addMemberHelp)
            }
            .padding(14)

            NativeSearchField(
                text: $query,
                prompt: "Search group members",
                accessibilityLabel: "Search group members"
            )
            .frame(height: 28)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            List(filteredRoster) { member in
                HStack(spacing: 10) {
                    AvatarView(
                        name: user(for: member)?.displayName ?? member.userID,
                        path: user(for: member)?.avatar, size: 32
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(environment.displayName(for: member.userID, in: chat))
                            .font(.callout.weight(.medium)).lineLimit(1)
                        Text(member.userID).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        if member.isMuted, let until = member.mutedUntil {
                            Text("Timeout until \(until, style: .time)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if member.role != .member {
                        Text(member.role.label).font(.caption).foregroundStyle(.secondary)
                    }
                    memberActions(member).fixedSize()
                }
                .padding(.vertical, 5)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                if let chat, environment.supportsGroupModeration,
                    let activeUserID = environment.activeUserID,
                    let role = environment.role(of: activeUserID, in: groupID), role > .member
                {
                    Button(group?.wholeMuted == true ? "Unmute Group" : "Mute Group", systemImage: "speaker.slash") {
                        Task { await environment.setWholeMute(in: chat, muted: group?.wholeMuted != true) }
                    }
                    .disabled(!environment.canInteract(in: chat))
                }
                Text("\(roster.count) / \(group?.maxMemberCount ?? 0) members")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
        .sheet(isPresented: $showingAddMember) {
            UserSelectionSheet(environment: environment, purpose: .group(groupID))
        }
        .confirmationDialog(
            "Remove Member from Group?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { member in
            Button("Remove \(user(for: member)?.displayName ?? member.userID)", role: .destructive) {
                remove(member)
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { member in
            Text("This member will be removed from “\(groupName)”.")
        }
        .alert(
            "Unable to Update Group Members",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func memberActions(_ member: GroupMember) -> some View {
        Menu {
            if let chat, environment.supportsGroupModeration {
                if canRemove(member) {
                    if member.isMuted {
                        Button("Remove Timeout") {
                            Task { await environment.muteMember(member, in: chat, duration: 0) }
                        }
                    } else {
                        Menu("Timeout") {
                            Button("60 Seconds") {
                                Task { await environment.muteMember(member, in: chat, duration: 60) }
                            }
                            Button("10 Minutes") {
                                Task { await environment.muteMember(member, in: chat, duration: 600) }
                            }
                            Button("1 Hour") {
                                Task { await environment.muteMember(member, in: chat, duration: 3600) }
                            }
                            Button("1 Day") {
                                Task { await environment.muteMember(member, in: chat, duration: 86400) }
                            }
                        }
                    }
                }
                if let activeUserID = environment.activeUserID,
                    environment.role(of: activeUserID, in: groupID) == .owner, member.role != .owner
                {
                    Button(member.role == .admin ? "Remove Administrator" : "Make Administrator") {
                        Task {
                            await environment.setAdmin(member, in: chat, granted: member.role != .admin)
                        }
                    }
                }
            }
            Button("Remove from Group", systemImage: "person.badge.minus", role: .destructive) {
                pendingRemoval = member
            }
            .disabled(!canRemove(member))
        } label: {
            Label("Member Actions", systemImage: "ellipsis").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .disabled(
            workingUserIDs.contains(member.userID) || chat.map { !environment.canInteract(in: $0) } != false
        )
        .help("Member actions")
    }

    private var group: ReiCore.Group? {
        environment.groups.first { $0.id == groupID }
    }

    private var chat: Chat? {
        environment.botUserID.map { Chat(scene: .group, peerID: groupID, selfID: $0) }
    }

    private var groupName: String {
        group?.name ?? groupID
    }

    private var roster: [GroupMember] {
        environment.members
            .filter { $0.key.groupID == groupID }
            .map(\.value)
            .sorted {
                if $0.joinedAt != $1.joinedAt { return $0.joinedAt < $1.joinedAt }
                return $0.userID < $1.userID
            }
    }

    private var memberUserIDs: Set<User.ID> {
        Set(roster.map(\.userID))
    }

    private var filteredRoster: [GroupMember] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return roster }
        return roster.filter { member in
            member.userID.localizedCaseInsensitiveContains(normalized)
                || user(for: member)?.displayName.localizedCaseInsensitiveContains(normalized) == true
        }
    }

    private var canInviteMember: Bool {
        guard environment.activeUserID.map(memberUserIDs.contains) == true else { return false }
        guard roster.count < (group?.maxMemberCount ?? 0) else { return false }
        return environment.users.contains { !memberUserIDs.contains($0.id) }
    }

    private var addMemberHelp: String {
        guard environment.activeUserID.map(memberUserIDs.contains) == true else {
            return "The current sending identity is not a member of this group"
        }
        if roster.count >= (group?.maxMemberCount ?? 0) { return "The group is full" }
        if !environment.users.contains(where: { !memberUserIDs.contains($0.id) }) {
            return "All personas are already members"
        }
        return "Add an existing persona to the group"
    }

    private func user(for member: GroupMember) -> User? {
        environment.users.first { $0.id == member.userID }
    }

    private func canRemove(_ member: GroupMember) -> Bool {
        guard let activeUserID = environment.activeUserID, activeUserID != member.userID,
            let actor = roster.first(where: { $0.userID == activeUserID })
        else { return false }
        return actor.role > .member && actor.role > member.role
    }

    private func remove(_ member: GroupMember) {
        pendingRemoval = nil
        guard workingUserIDs.insert(member.userID).inserted else { return }

        Task {
            defer { workingUserIDs.remove(member.userID) }
            do {
                try await environment.removeGroupMember(member.userID, from: groupID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension GroupMember.Role {
    fileprivate var label: String {
        switch self {
        case .owner: return "Owner"
        case .admin: return "Admin"
        case .member: return "Member"
        }
    }
}
