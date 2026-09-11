import AppKit
import ReiCore

final class ConversationManagementController: NSViewController {
    private let environment: AppEnvironment
    private let chat: Chat
    private let groupName = NativeUI.field("Group Name")
    private let card = NativeUI.field("Group Nickname")
    private let memberTitle = NativeUI.field("Custom Title")
    private let memberPicker = ChoiceButton([])
    private let status = NativeUI.label("", style: .caption1, secondary: true)
    private var editableMembers: [GroupMember] = []
    private var selectedMemberID: User.ID?
    private var observation: ModelObservation?
    private var didLoad = false
    private var working = false
    private let groupSection = NativeUI.column()
    private let memberSection = NativeUI.column()
    private let cardSection = NativeUI.column()
    private let titleSection = NativeUI.column()
    private let requestSection = NativeUI.column()

    init(environment: AppEnvironment, chat: Chat) {
        self.environment = environment
        self.chat = chat
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        memberPicker.onChange = { [weak self] index in
            guard let self, editableMembers.indices.contains(index) else { return }
            selectedMemberID = editableMembers[index].userID
            loadSelectedMember()
            refresh()
        }
        NativeUI.replace(
            groupSection,
            with: [
                NativeUI.label("Group Profile", style: .headline), groupName,
                ActionButton("Save Group Name") { [weak self] in
                    guard let self else { return }
                    let name = groupName.stringValue
                    submit { [environment, chat] in try await environment.renameGroup(in: chat, name: name) }
                },
            ])
        NativeUI.replace(
            cardSection,
            with: [
                card,
                ActionButton("Save Nickname") { [weak self] in
                    guard let self, let id = selectedMemberID else { return }
                    let value = card.stringValue
                    submit { [environment, chat] in try await environment.editMemberCard(id, in: chat, card: value) }
                },
            ])
        NativeUI.replace(
            titleSection,
            with: [
                memberTitle,
                ActionButton("Save Title") { [weak self] in
                    guard let self, let id = selectedMemberID else { return }
                    let value = memberTitle.stringValue
                    submit { [environment, chat] in try await environment.editMemberTitle(id, in: chat, title: value) }
                },
            ])
        NativeUI.replace(
            memberSection,
            with: [NativeUI.label("Member Profile", style: .headline), memberPicker, cardSection, titleSection])
        let column = NativeUI.column(
            [
                NativeUI.label("Conversation Settings", style: .headline), groupSection, memberSection, requestSection,
                status,
            ], spacing: 18)
        column.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28).isActive = true
        }
        view = NativeUI.scroll(column)
        observation = ModelObservation { [weak self] in self?.refresh() }
        if chat.scene == .group {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await environment.groupMembers(in: chat.peerID)
                    refresh()
                } catch { status.stringValue = error.localizedDescription }
            }
        }
    }

    private func refresh() {
        if !didLoad, let group = environment.groups.first(where: { $0.id == chat.peerID }) {
            groupName.stringValue = group.name
            didLoad = true
        }
        groupSection.isHidden = !environment.canRenameGroup(in: chat)
        let members = environment.members.values.filter {
            $0.groupID == chat.peerID
                && (environment.canEditMemberCard($0, in: chat) || environment.canEditMemberTitle($0, in: chat))
        }.sorted { $0.userID < $1.userID }
        editableMembers = members
        let previous = selectedMemberID
        if !members.contains(where: { $0.userID == selectedMemberID }) {
            selectedMemberID = members.first { $0.userID == environment.activeUserID }?.userID ?? members.first?.userID
        }
        memberPicker.removeAllItems()
        memberPicker.addItems(withTitles: members.map { environment.displayName(for: $0.userID, in: chat) })
        memberPicker.selectItem(at: members.firstIndex { $0.userID == selectedMemberID } ?? 0)
        if previous != selectedMemberID { loadSelectedMember() }
        let member = members.first { $0.userID == selectedMemberID }
        memberSection.isHidden = members.isEmpty
        cardSection.isHidden = member.map { !environment.canEditMemberCard($0, in: chat) } ?? true
        titleSection.isHidden = member.map { !environment.canEditMemberTitle($0, in: chat) } ?? true
        var requests: [NSView] = []
        if environment.canSendFriendRequest(in: chat) {
            requests.append(ActionButton("Send Friend Request…") { [weak self] in self?.request(.friend) })
        }
        if environment.canRequestToJoinGroup(in: chat) {
            requests.append(ActionButton("Request to Join Group…") { [weak self] in self?.request(.joinGroup) })
        }
        if environment.canInviteBotToGroup(in: chat) {
            requests.append(ActionButton("Invite Bot to Group…") { [weak self] in self?.request(.inviteBot) })
        }
        NativeUI.replace(requestSection, with: requests)
        if groupSection.isHidden && memberSection.isHidden && requests.isEmpty {
            status.stringValue = "No conversation settings are available for this identity."
        }
    }

    private func loadSelectedMember() {
        let member = editableMembers.first { $0.userID == selectedMemberID }
        card.stringValue = member?.card ?? ""
        memberTitle.stringValue = member?.title ?? ""
    }

    private func submit(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        status.stringValue = "Saving…"
        Task { [weak self] in
            guard let self else { return }
            defer { working = false }
            do {
                try await operation()
                status.stringValue = "Saved"
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    private func request(_ kind: ConversationRequestKind) {
        guard let window = view.window else { return }
        let comment = NativeUI.field("Comment")
        FormSheetController(
            title: kind.rawValue,
            fields: [
                NativeUI.label(
                    "Speaking as " + environment.displayName(for: environment.activeUserID ?? "", in: nil),
                    secondary: true), comment,
            ], submit: "Send Request"
        ) { [environment, chat] in
            switch kind {
            case .friend: try await environment.sendFriendRequest(in: chat, comment: comment.stringValue)
            case .joinGroup: try await environment.requestToJoinGroup(in: chat, comment: comment.stringValue)
            case .inviteBot: try await environment.inviteBotToGroup(in: chat, comment: comment.stringValue)
            }
        }.present(on: window)
    }
}
