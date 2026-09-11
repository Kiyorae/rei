import AppKit
import ReiCore
import ReiProtocol

private struct SidebarItem: Identifiable, Equatable {
    let id: String
    var title: String
    var detail = ""
    var chat: Chat?
    var request: PendingRequest?
    var avatar: String?
    var isHeader = false
}

private final class SidebarSectionView: NSView {
    init(title: String, count: String) {
        super.init(frame: .zero)
        let heading = NativeUI.label(title, secondary: true)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        let countLabel = NativeUI.label(count, secondary: true)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        let row = NativeUI.row([heading, NativeUI.spacer(), countLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class SidebarConversationRow: NSTableCellView {
    init(item: SidebarItem) {
        super.init(frame: .zero)
        let titleLabel = NativeUI.label(item.title)
        let previewLabel = NativeUI.label(item.detail, secondary: true)
        titleLabel.font = .systemFont(ofSize: 13)
        previewLabel.font = .systemFont(ofSize: 11)
        for label in [titleLabel, previewLabel] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        textField = titleLabel
        let avatar = AvatarImageView(name: item.title, path: item.avatar, group: item.chat?.scene == .group, size: 24)
        let labels = NativeUI.column([titleLabel, previewLabel], spacing: 3)
        titleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        previewLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        let row = NativeUI.row([avatar, labels], spacing: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(item.title + ". " + item.detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class SidebarViewController: NSViewController {
    private let environment: AppEnvironment
    private let showcase: ShowcaseSession?
    private let search = SearchField("Search conversations")
    private let connection = ActionButton("Not Connected", action: {})
    private let connectionIndicator = NSImageView()
    private let identity = ActionButton("Sending Identity", action: {})
    private let identityDetail = NativeUI.label("", style: .caption1, secondary: true)
    private let avatarContainer = NSView()
    private var displayedUser: User?
    private let emptyTitle = NativeUI.label("No conversations yet", secondary: true)
    private let emptyDetail = NativeUI.label(
        "Create a persona or group to get started.", style: .caption1, secondary: true)
    private lazy var emptyState = NativeUI.column([emptyTitle, emptyDetail], spacing: 6)
    private lazy var list = ItemListController<SidebarItem> { item in
        if item.isHeader { return SidebarSectionView(title: item.title, count: item.detail) }
        return SidebarConversationRow(item: item)
    }
    private var query = ""
    private var observation: ModelObservation?
    var createUser: (() -> Void)?
    var addFriend: (() -> Void)?
    var createGroup: (() -> Void)?
    var showSettings: (() -> Void)?
    var inspect: ((Chat, ConversationInspectorSection) -> Void)?

    init(environment: AppEnvironment, showcase: ShowcaseSession?) {
        self.environment = environment
        self.showcase = showcase
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // Let the split item supply the system glass without layering a
        // second window-background material over its native light response.
        view = NSView()
        let new = ActionButton("", symbol: "square.and.pencil") { [weak self] in self?.showNewMenu() }
        new.isBordered = false
        new.imagePosition = .imageOnly
        new.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        new.contentTintColor = .secondaryLabelColor
        new.toolTip = "New persona, friend or group"
        new.setAccessibilityLabel("New Persona, Friend or Group")
        NSLayoutConstraint.activate([
            new.widthAnchor.constraint(equalToConstant: 28),
            new.heightAnchor.constraint(equalToConstant: 28),
        ])
        let brand = NativeUI.label("Rei")
        brand.font = .systemFont(ofSize: 22, weight: .semibold)
        let heading = NativeUI.row([brand, NativeUI.spacer(), new])
        search.font = .systemFont(ofSize: 13)
        search.controlSize = .regular
        search.onChange = { [weak self] query in
            self?.query = query
            self?.refresh()
        }
        connection.onAction = { [weak self] in self?.toggleConnection() }
        connection.isBordered = false
        connection.alignment = .left
        connection.font = .systemFont(ofSize: 11)
        connection.contentTintColor = .secondaryLabelColor
        connection.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        connectionIndicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        connectionIndicator.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 6, weight: .regular)
        NSLayoutConstraint.activate([
            connectionIndicator.widthAnchor.constraint(equalToConstant: 8),
            connectionIndicator.heightAnchor.constraint(equalToConstant: 8),
        ])
        identity.onAction = { [weak self] in self?.showIdentityMenu() }
        identity.isBordered = false
        identity.alignment = .left
        identity.font = .systemFont(ofSize: 13, weight: .medium)
        identity.setAccessibilityLabel("Switch Sending Identity")
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        identity.setContentHuggingPriority(.defaultLow, for: .horizontal)
        identityDetail.font = .systemFont(ofSize: 11)
        identityDetail.maximumNumberOfLines = 1
        identityDetail.lineBreakMode = .byTruncatingTail
        avatarContainer.widthAnchor.constraint(equalToConstant: 32).isActive = true
        avatarContainer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let accountMenu = ActionButton("", symbol: "chevron.up.chevron.down") { [weak self] in
            self?.showIdentityMenu()
        }
        accountMenu.isBordered = false
        accountMenu.imagePosition = .imageOnly
        accountMenu.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        accountMenu.contentTintColor = .secondaryLabelColor
        accountMenu.setAccessibilityLabel("Account Menu")
        accountMenu.widthAnchor.constraint(equalToConstant: 24).isActive = true
        accountMenu.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let identityLabels = NativeUI.column([identity, identityDetail], spacing: 0)
        identity.widthAnchor.constraint(equalTo: identityLabels.widthAnchor).isActive = true
        identityDetail.widthAnchor.constraint(equalTo: identityLabels.widthAnchor).isActive = true
        let userStatus = NativeUI.row([avatarContainer, identityLabels, accountMenu], spacing: 8)
        userStatus.setAccessibilityLabel("Current User")
        let connectionStatus = NativeUI.row([connectionIndicator, connection, NativeUI.spacer()], spacing: 6)
        let separator = NSBox()
        separator.boxType = .separator
        let footer = NativeUI.column([separator, userStatus, connectionStatus], spacing: 10)
        footer.setCustomSpacing(14, after: separator)
        for child in footer.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }
        addChild(list)
        let column = NativeUI.column([heading, search, list.view, footer], spacing: 16)
        column.alignment = .centerX
        column.setCustomSpacing(20, after: heading)
        column.setCustomSpacing(8, after: search)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 0, bottom: 16, right: 0)
        NativeUI.embed(column, in: view, respectingSafeArea: true)
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor, constant: child === list.view ? 0 : -32)
                .isActive = true
        }
        list.view.setContentHuggingPriority(.init(1), for: .vertical)
        list.tableView.style = .sourceList
        list.tableView.intercellSpacing = NSSize(width: 0, height: 2)
        list.tableView.setAccessibilityLabel("Conversations")
        list.rowHeight = { $0.isHeader ? 34 : 48 }
        list.allowsSelection = { !$0.isHeader && $0.chat != nil }
        list.onSelect = { [weak self] item in
            guard let chat = item?.chat else { return }
            self?.environment.selectChat(chat)
        }
        list.menuForItem = { [weak self] item in self?.menu(for: item) ?? NSMenu() }
        emptyTitle.font = .systemFont(ofSize: 13, weight: .medium)
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        list.view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: list.view.leadingAnchor, constant: 8),
            emptyState.trailingAnchor.constraint(equalTo: list.view.trailingAnchor, constant: -8),
            emptyState.topAnchor.constraint(equalTo: list.view.topAnchor, constant: 24),
            emptyTitle.widthAnchor.constraint(equalTo: emptyState.widthAnchor),
            emptyDetail.widthAnchor.constraint(equalTo: emptyState.widthAnchor),
        ])
        observation = ModelObservation { [weak self] in self?.refresh() }
    }

    private func refresh() {
        var entries: [SidebarItem] = []
        let requests = environment.pendingRequests.filter {
            query.isEmpty || $0.comment.localizedCaseInsensitiveContains(query)
                || environment.displayName(for: $0.requesterID, in: nil).localizedCaseInsensitiveContains(query)
        }
        if !requests.isEmpty {
            entries.append(
                SidebarItem(id: "requests", title: "Requests", detail: String(requests.count), isHeader: true))
            entries += requests.map {
                SidebarItem(
                    id: "request:" + $0.id, title: environment.displayName(for: $0.requesterID, in: nil),
                    detail: $0.comment, request: $0)
            }
        }
        var chats = environment.conversations.map(\.chat)
        if let bot = environment.botUserID {
            for group in environment.groups {
                let chat = Chat(scene: .group, peerID: group.id, selfID: bot)
                if !chats.contains(chat) { chats.append(chat) }
            }
            for user in environment.users {
                if let chat = environment.privateChat(with: user.id), !chats.contains(chat) { chats.append(chat) }
            }
        }
        chats = chats.filter {
            query.isEmpty || environment.conversationTitle(for: $0).localizedCaseInsensitiveContains(query)
                || $0.peerID.localizedCaseInsensitiveContains(query)
        }
        for pinned in [true, false] {
            let values = chats.filter { environment.isPinned($0) == pinned }
            guard !values.isEmpty else { continue }
            entries.append(
                SidebarItem(
                    id: pinned ? "pinned" : "conversations", title: pinned ? "Pinned" : "Conversations",
                    detail: String(values.count), isHeader: true)
            )
            entries += values.map { chat in
                let summary = environment.conversations.first { $0.chat == chat }
                return SidebarItem(
                    id: chat.id, title: environment.conversationTitle(for: chat),
                    detail: summary.map(environment.conversationPreview) ?? "No messages yet", chat: chat,
                    avatar: environment.conversationAvatar(for: chat))
            }
        }
        list.update(entries, selection: environment.selectedChat?.id)
        emptyState.isHidden = !entries.isEmpty
        emptyTitle.stringValue = query.isEmpty ? "No conversations yet" : "No results"
        emptyDetail.stringValue =
            query.isEmpty ? "Create a persona or group to get started." : "Try a different name or ID."
        let user = environment.users.first { $0.id == environment.activeUserID }
        identity.title = user?.displayName ?? "Choose a Persona"
        identity.toolTip = user?.sign
        var status = user.map { [environment.botUserID == $0.id ? "Bot" : "Persona", $0.id] } ?? ["No active identity"]
        if let user, let chat = environment.selectedChat, chat.scene == .group,
            let role = environment.role(of: user.id, in: chat.peerID)
        {
            status.append(role.rawValue.capitalized)
        }
        identityDetail.stringValue = status.joined(separator: " · ")
        if displayedUser != user || avatarContainer.subviews.isEmpty {
            displayedUser = user
            for child in avatarContainer.subviews { child.removeFromSuperview() }
            NativeUI.embed(
                AvatarImageView(name: user?.displayName ?? "No active identity", path: user?.avatar, size: 32),
                in: avatarContainer)
        }
        if let showcase {
            connection.title =
                showcase.connection.isActive
                ? "Milky · " + (showcase.connection.roundTripTime.map(Self.duration) ?? "Connected")
                : "Milky · Not Connected"
            connection.toolTip = showcase.connection.errorMessage ?? "Local Milky demo client"
        } else {
            let protocolName = (environment.activeProtocolChoice ?? environment.selectedProtocol).shortDisplayName
            var status = environment.sessionState.displayName
            if case .measured(let duration) = environment.roundTripTimeState { status = Self.duration(duration) }
            connection.title = protocolName + " · " + status
            connection.toolTip = "Connect or disconnect (⇧⌘K)"
        }
        connectionIndicator.contentTintColor =
            (showcase?.connection.isActive ?? environment.sessionState.isActive) ? .systemGreen : .secondaryLabelColor
    }

    func toggleConnection() {
        Task {
            if let showcase {
                await showcase.connection.toggle()
            } else if environment.sessionState.isActive {
                await environment.disconnect()
            } else {
                await environment.connect()
            }
        }
    }

    private func showIdentityMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "Sending Identity", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for user in environment.users {
            let item = ActionMenuItem(user.displayName) { [environment] in environment.setActiveUser(user.id) }
            item.state = user.id == environment.activeUserID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let persona = ActionMenuItem("New Persona…") { [weak self] in self?.createUser?() }
        persona.image = NSImage(systemSymbolName: "person.badge.plus", accessibilityDescription: nil)
        menu.addItem(persona)
        let settings = ActionMenuItem("Settings…") { [weak self] in self?.showSettings?() }
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: identity.bounds.maxY), in: identity)
    }

    private static func duration(_ value: Duration) -> String {
        let parts = value.components
        let milliseconds = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        return "\(Int(milliseconds.rounded())) ms"
    }

    private func showNewMenu() {
        let menu = NSMenu()
        let persona = ActionMenuItem("New Persona…") { [weak self] in self?.createUser?() }
        persona.image = NSImage(systemSymbolName: "person.badge.plus", accessibilityDescription: nil)
        menu.addItem(persona)
        let friend = ActionMenuItem("Add Friend…") { [weak self] in self?.addFriend?() }
        friend.image = NSImage(systemSymbolName: "person.crop.circle.badge.plus", accessibilityDescription: nil)
        menu.addItem(friend)
        let group = ActionMenuItem("New Group…") { [weak self] in self?.createGroup?() }
        group.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        menu.addItem(group)
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.width - 35, y: view.bounds.height - 35), in: view)
    }

    private func menu(for item: SidebarItem) -> NSMenu {
        let menu = NSMenu()
        if let request = item.request {
            menu.addItem(
                ActionMenuItem("Accept") { [environment] in
                    Task { await environment.resolveRequest(request, approve: true) }
                })
            menu.addItem(
                ActionMenuItem("Decline") { [environment] in
                    Task { await environment.resolveRequest(request, approve: false) }
                })
        }
        guard let chat = item.chat else { return menu }
        menu.addItem(ActionMenuItem("Open Conversation") { [environment] in environment.selectChat(chat) })
        menu.addItem(ActionMenuItem("Conversation Details") { [weak self] in self?.inspect?(chat, .overview) })
        menu.addItem(ActionMenuItem("Shared Content") { [weak self] in self?.inspect?(chat, .files) })
        menu.addItem(ActionMenuItem("Conversation Settings") { [weak self] in self?.inspect?(chat, .settings) })
        menu.addItem(ActionMenuItem("Copy ID") { NativeUI.copy(chat.peerID) })
        if environment.effectiveProtocol == .milky {
            let pinned = environment.isPinned(chat)
            menu.addItem(
                ActionMenuItem(pinned ? "Unpin Conversation" : "Pin Conversation") { [environment] in
                    Task { await environment.setPinned(!pinned, in: chat) }
                })
        }
        if chat.scene == .group {
            menu.addItem(
                ActionMenuItem("Delete Group Chat…") { [weak self] in
                    guard let self else { return }
                    NativeUI.confirm(
                        "Delete \(item.title)?", detail: "This deletes the group, membership and saved history.",
                        button: "Delete Group", on: view.window
                    ) {
                        Task {
                            do { try await self.environment.deleteGroup(chat.peerID) } catch {
                                NativeUI.error(error, on: self.view.window)
                            }
                        }
                    }
                })
        } else if environment.isFriend(chat.peerID) {
            menu.addItem(
                ActionMenuItem("Remove Friend…") { [weak self] in
                    guard let self else { return }
                    NativeUI.confirm(
                        "Remove \(item.title)?",
                        detail: "This removes the friendship. The local persona remains available.",
                        button: "Remove Friend", on: view.window
                    ) {
                        Task {
                            do { try await self.environment.removeFriend(chat.peerID) } catch {
                                NativeUI.error(error, on: self.view.window)
                            }
                        }
                    }
                })
        }
        return menu
    }
}
