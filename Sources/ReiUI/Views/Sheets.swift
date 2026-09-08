import ReiCore
import SwiftUI

// MARK: - New user

/// Creates a persona.
///
/// Personas are the people in the simulated platform: the operator speaks as one of
/// them, and one is the account the bot framework logs in as.
struct NewUserSheet: View {
    let environment: AppEnvironment
    @State private var name = ""
    @State private var nickname = ""
    @State private var sex: User.Sex = .unknown

    var body: some View {
        SheetScaffold(
            title: "New Persona",
            confirmTitle: "Create",
            isConfirmDisabled: trimmedName.isEmpty
        ) {
            Form {
                TextField("Name", text: $name)
                    .help("The persona’s account name on the simulated platform")
                TextField("Nickname", text: $nickname, prompt: Text("Defaults to the name when left blank"))
                Picker("Gender", selection: $sex) {
                    ForEach(User.Sex.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
            .formStyle(.grouped)
        } confirm: {
            let alias = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await environment.createUser(name: trimmedName, nickname: alias, sex: sex) }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - New group

/// Creates a group chat with a chosen owner.
///
/// The bot is added alongside the owner by `AppEnvironment`, since a group the bot is
/// not in cannot carry any traffic worth simulating.
struct NewGroupSheet: View {
    let environment: AppEnvironment
    @State private var name = ""
    @State private var ownerID: String?

    var body: some View {
        SheetScaffold(
            title: "New Group",
            confirmTitle: "Create",
            isConfirmDisabled: trimmedName.isEmpty || ownerID == nil
        ) {
            Form {
                TextField("Group Name", text: $name)

                Picker("Owner", selection: $ownerID) {
                    Text("Select…").tag(String?.none)
                    ForEach(environment.users) { user in
                        Text(user.displayName).tag(user.id as String?)
                    }
                }
                .help("The persona with the highest permissions in this group")

                if environment.users.isEmpty {
                    Text("No personas exist yet. Create a persona first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } confirm: {
            guard let ownerID else { return }
            Task { await environment.createGroup(name: trimmedName, ownerID: ownerID) }
        }
        // Default to whoever the operator is speaking as, which is the owner they
        // almost always want.
        .onAppear { ownerID = ownerID ?? environment.activeUserID ?? environment.users.first?.id }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - User selection

enum UserSelectionPurpose: Equatable {
    case friend
    case group(ReiCore.Group.ID)
}

/// Selects an existing simulated user for a relationship operation. The mutation
/// completes before the sheet closes, so a permission or capacity failure remains
/// attached to the action that caused it.
struct UserSelectionSheet: View {
    let environment: AppEnvironment
    let purpose: UserSelectionPurpose

    @Environment(\.dismiss) private var dismiss
    @State private var selectedUserID: User.ID?
    @State private var query = ""
    @State private var excludedUserIDs: Set<User.ID> = []
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var groupIsFull = false
    @State private var operatorCanInvite = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 10)

            NativeSearchField(
                text: $query,
                prompt: "Search personas",
                accessibilityLabel: "Search available personas"
            )
            .frame(height: 28)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            selectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)

                Button(confirmTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isConfirmDisabled)
            }
            .padding(12)
        }
        .frame(width: 460, height: 420)
        .task(id: purpose) { await loadContext() }
        .onChange(of: candidates.map(\.id)) { _, candidateIDs in
            if selectedUserID.map(candidateIDs.contains) != true {
                selectedUserID = candidateIDs.first
            }
        }
        .alert(
            "Operation Failed",
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

    @ViewBuilder
    private var selectionContent: some View {
        if isLoading {
            ProgressView()
        } else if candidates.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "person.badge.plus")
            } description: {
                Text(emptyDescription)
            } actions: {
                if environment.users.isEmpty {
                    SettingsLink {
                        Label("Open Persona Settings", systemImage: "gearshape")
                    }
                }
            }
        } else {
            List(candidates, selection: $selectedUserID) { user in
                HStack(spacing: 10) {
                    AvatarView(name: user.displayName, path: user.avatar, size: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName)
                            .lineLimit(1)
                        Text(user.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(user.id)
            }
            .listStyle(.inset)
            .disabled(isSubmitting)
        }
    }

    private var candidates: [User] {
        let base: [User]
        switch purpose {
        case .friend:
            base = environment.addableFriendUsers
        case .group:
            base = environment.users.filter { !excludedUserIDs.contains($0.id) }
        }

        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return base }
        return base.filter {
            $0.displayName.localizedCaseInsensitiveContains(normalized)
                || $0.id.localizedCaseInsensitiveContains(normalized)
        }
    }

    private var title: String {
        switch purpose {
        case .friend: return "Add Friend"
        case .group: return "Add Group Member"
        }
    }

    private var confirmTitle: String {
        switch purpose {
        case .friend: return "Add Friend"
        case .group: return "Add to Group"
        }
    }

    private var emptyTitle: String {
        switch purpose {
        case .friend: return "No Available Personas"
        case .group: return groupIsFull ? "Group Is Full" : "All Personas Are Already Members"
        }
    }

    private var emptyDescription: String {
        if environment.users.isEmpty { return "Create a persona first." }
        switch purpose {
        case .friend:
            return environment.botUserID == nil
                ? "Select a bot account first." : "No new friend candidates are available."
        case .group:
            if groupIsFull { return "This group has reached its member limit." }
            if !operatorCanInvite { return "The current sending identity is not a member of this group." }
            return "No personas can be added to this group."
        }
    }

    private var isConfirmDisabled: Bool {
        selectedUserID == nil
            || isLoading
            || isSubmitting
            || groupIsFull
            || !operatorCanInvite
    }

    private func loadContext() async {
        isLoading = true
        defer { isLoading = false }

        do {
            switch purpose {
            case .friend:
                break
            case .group(let groupID):
                let roster = try await environment.groupMembers(in: groupID)
                excludedUserIDs = Set(roster.map(\.userID))
                operatorCanInvite = environment.activeUserID.map(excludedUserIDs.contains) == true
                if let group = environment.groups.first(where: { $0.id == groupID }) {
                    groupIsFull = roster.count >= group.maxMemberCount
                }
            }
            selectedUserID = candidates.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submit() {
        guard let selectedUserID, !isConfirmDisabled else { return }
        isSubmitting = true

        Task {
            do {
                switch purpose {
                case .friend:
                    let chat = try await environment.addFriend(with: selectedUserID)
                    environment.selectChat(chat)
                case .group(let groupID):
                    try await environment.addGroupMember(selectedUserID, to: groupID)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

// MARK: - Group members

// MARK: - Shared chrome

/// Common sheet layout: a titled body over a Cancel / confirm bar.
///
/// Both sheets dismiss themselves on confirm, so callers pass only the work to do.
struct SheetScaffold<Content: View>: View {
    let title: String
    let confirmTitle: String
    var isConfirmDisabled = false
    @ViewBuilder let content: Content
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 4)

            content

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    confirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isConfirmDisabled)
            }
            .padding(12)
        }
        .frame(width: 380)
    }
}

// MARK: - Labels

extension User.Sex {
    /// Display label for the picker and the roles table.
    var label: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        case .unknown: return "Private"
        }
    }
}
