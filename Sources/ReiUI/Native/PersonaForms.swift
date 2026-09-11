import AppKit
import ReiCore

struct NativeActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum PersonaForms {
    static func createUser(environment: AppEnvironment, on window: NSWindow) {
        let name = NativeUI.field("Name")
        let nickname = NativeUI.field("Nickname")
        let sexes = User.Sex.allCases
        let gender = ChoiceButton(sexes.map { $0.rawValue.capitalized })
        FormSheetController(
            title: "New Persona",
            fields: [
                NativeUI.labeled("Name", name), NativeUI.labeled("Nickname", nickname),
                NativeUI.labeled("Gender", gender),
            ], submit: "Create"
        ) {
            let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw NativeActionError(message: "Enter a name") }
            await environment.createUser(
                name: value, nickname: nickname.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                sex: sexes[gender.indexOfSelectedItem])
            if let error = environment.lastError { throw NativeActionError(message: error) }
        }.present(on: window)
    }

    static func createGroup(environment: AppEnvironment, on window: NSWindow) {
        let name = NativeUI.field("Group Name")
        let users = environment.users
        let owner = ChoiceButton(
            users.map { $0.displayName }, selected: users.firstIndex { $0.id == environment.activeUserID } ?? 0)
        FormSheetController(
            title: "New Group", fields: [NativeUI.labeled("Group Name", name), NativeUI.labeled("Owner", owner)],
            submit: "Create"
        ) {
            let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, users.indices.contains(owner.indexOfSelectedItem) else {
                throw NativeActionError(message: "Enter a group name and select an owner")
            }
            await environment.createGroup(name: value, ownerID: users[owner.indexOfSelectedItem].id)
            if let error = environment.lastError { throw NativeActionError(message: error) }
        }.present(on: window)
    }
}

final class UserSelectionController: NSViewController {
    private let environment: AppEnvironment
    private let purpose: UserSelectionPurpose
    private let search = SearchField("Search personas")
    private let errorLabel = NativeUI.label("", secondary: true)
    private let list = ItemListController<User> { user in
        NativeUI.row([
            AvatarImageView(name: user.displayName, path: user.avatar),
            NativeUI.column(
                [NativeUI.label(user.displayName), NativeUI.label(user.id, style: .caption1, secondary: true)],
                spacing: 2),
        ])
    }
    private var selectedID: User.ID?
    private var roster: [GroupMember] = []
    private var query = ""
    private var observation: ModelObservation?
    private var isWorking = false
    private lazy var submitButton = ActionButton("Add") { [weak self] in self?.submit() }

    init(environment: AppEnvironment, purpose: UserSelectionPurpose) {
        self.environment = environment
        self.purpose = purpose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let title: String = {
            if case .friend = purpose { return "Add Friend" }
            return "Add Group Member"
        }()
        let cancel = ActionButton("Cancel") { [weak self] in self?.dismiss() }
        cancel.keyEquivalent = "\u{1b}"
        submitButton.keyEquivalent = "\r"
        addChild(list)
        list.view.heightAnchor.constraint(equalToConstant: 280).isActive = true
        let column = NativeUI.column([
            NativeUI.label(title, style: .headline), search, list.view, errorLabel,
            NativeUI.row([NativeUI.spacer(), cancel, submitButton]),
        ])
        column.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        view = column
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36).isActive = true
        }
        search.onChange = { [weak self] in
            self?.query = $0
            self?.refresh()
        }
        list.onSelect = { [weak self] in
            self?.selectedID = $0?.id
            self?.refresh()
        }
        observation = ModelObservation { [weak self] in self?.refresh() }
        if case .group(let id) = purpose {
            Task { [weak self] in
                guard let self else { return }
                do {
                    roster = try await environment.groupMembers(in: id)
                    refresh()
                } catch { errorLabel.stringValue = error.localizedDescription }
            }
        }
        preferredContentSize = NSSize(width: 480, height: 430)
    }

    func present(on parent: NSWindow) {
        let panel = NSPanel(contentViewController: self)
        panel.setContentSize(preferredContentSize)
        parent.beginSheet(panel)
    }

    private func refresh() {
        let users: [User]
        switch purpose {
        case .friend: users = environment.addableFriendUsers
        case .group: users = environment.users.filter { user in !roster.contains { $0.userID == user.id } }
        }
        let candidates = users.filter {
            query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
        if !candidates.contains(where: { $0.id == selectedID }) { selectedID = candidates.first?.id }
        list.update(candidates, selection: selectedID)
        var canAdd = selectedID != nil && !isWorking
        if case .group(let id) = purpose {
            canAdd =
                canAdd && roster.contains { $0.userID == environment.activeUserID }
                && roster.count < (environment.groups.first { $0.id == id }?.maxMemberCount ?? 0)
        }
        submitButton.isEnabled = canAdd
    }

    private func submit() {
        guard let selectedID, !isWorking else { return }
        isWorking = true
        refresh()
        Task { [weak self] in
            guard let self else { return }
            defer {
                isWorking = false
                refresh()
            }
            do {
                switch purpose {
                case .friend: environment.selectChat(try await environment.addFriend(with: selectedID))
                case .group(let id): try await environment.addGroupMember(selectedID, to: id)
                }
                dismiss()
            } catch { errorLabel.stringValue = error.localizedDescription }
        }
    }

    private func dismiss() {
        guard let window = view.window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
