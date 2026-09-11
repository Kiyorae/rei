import AppKit
import ReiCore

final class ConversationDetailsController: NSViewController {
    let model: ConversationContentModel
    private let sectionPicker = ChoiceButton([])
    private let content = NSView()
    private let status = NativeUI.label("", style: .caption1, secondary: true)
    private let statusRow = NativeUI.row([])
    private var sections: [ConversationInspectorSection] = []
    private var displayedSection: ConversationInspectorSection?
    private var sectionController: NSViewController?
    private var observation: ModelObservation?
    private var tasks: [Task<Void, Never>] = []
    var section: ConversationInspectorSection { didSet { if isViewLoaded { refresh() } } }

    init(environment: AppEnvironment, chat: Chat, section: ConversationInspectorSection = .overview) {
        model = ConversationContentModel(environment: environment, chat: chat)
        self.section = section
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for task in tasks { task.cancel() }
    }

    override func loadView() {
        view = NSView()
        let dismiss = ActionButton("", symbol: "xmark.circle") { [weak self] in self?.model.errorMessage = nil }
        dismiss.setAccessibilityLabel("Dismiss Error")
        let header = NativeUI.row([
            NativeUI.label("Section", style: .caption1, secondary: true), NativeUI.spacer(), sectionPicker,
        ])
        sectionPicker.setAccessibilityLabel("Conversation Section")
        header.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 12, right: 16)
        NativeUI.replace(statusRow, with: [status, dismiss])
        let column = NativeUI.column([header, content, statusRow], spacing: 0)
        NativeUI.embed(column, in: view)
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        content.setContentHuggingPriority(.init(1), for: .vertical)
        sectionPicker.onChange = { [weak self] index in
            guard let self, sections.indices.contains(index) else { return }
            section = sections[index]
        }
        observation = ModelObservation { [weak self] in self?.refresh() }
        tasks = [
            Task { [model] in await model.observeState() }, Task { [model] in await model.observeMessages() },
            Task { [model] in await model.observeFiles() },
        ]
        if model.chat.scene == .group {
            tasks += [
                Task { [model] in await model.environment.loadMembers(groupID: model.chat.peerID) },
                Task { [model] in await model.observeAnnouncements() },
                Task { [model] in await model.observeFolders() }, Task { [model] in await model.observeHighlights() },
            ]
        }
    }

    private func refresh() {
        let available = ConversationInspectorSection.available(
            capabilities: model.capabilities,
            supportsSettings: model.environment.supportsGroupProfiles || model.environment.supportsRequestEvents)
        if sections != available {
            sections = available
            sectionPicker.removeAllItems()
            sectionPicker.addItems(withTitles: sections.map(\.rawValue))
        }
        let selected = sections.contains(section) ? section : .overview
        sectionPicker.selectItem(at: sections.firstIndex(of: selected) ?? 0)
        status.stringValue = model.errorMessage ?? (model.isWorking ? "Working…" : "")
        statusRow.isHidden = status.stringValue.isEmpty
        guard displayedSection != selected else { return }
        displayedSection = selected
        sectionController?.view.removeFromSuperview()
        sectionController?.removeFromParent()
        let child: NSViewController
        if selected == .settings {
            child = ConversationManagementController(environment: model.environment, chat: model.chat)
        } else {
            child = ConversationContentPane(model: model, section: selected)
        }
        addChild(child)
        NativeUI.embed(child.view, in: content)
        sectionController = child
        child.view.wantsLayer = true
        child.view.alphaValue = 0
        NativeUI.animate { child.view.animator().alphaValue = 1 }
    }
}

final class ConversationContentPane: NSViewController {
    let model: ConversationContentModel
    let section: ConversationInspectorSection
    private let column = NativeUI.column()
    private var observation: ModelObservation?
    private var likesTask: Task<Void, Never>?
    private var likesUserID: User.ID?
    private var memberQuery = ""
    private let memberSearch = SearchField("Search group members")

    init(model: ConversationContentModel, section: ConversationInspectorSection) {
        self.model = model
        self.section = section
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { likesTask?.cancel() }

    override func loadView() {
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view = NativeUI.scroll(column)
        memberSearch.onChange = { [weak self] in
            self?.memberQuery = $0
            self?.refresh()
        }
        observation = ModelObservation { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let children: [NSView]
        switch section {
        case .overview: children = overview()
        case .members: children = members()
        case .files: children = files()
        case .announcements: children = announcements()
        case .highlights: children = highlights()
        case .settings: children = []
        }
        NativeUI.replace(column, with: children)
        for child in children {
            child.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32).isActive = true
        }
    }

    private func overview() -> [NSView] {
        let model = self.model
        let environment = model.environment
        let chat = model.chat
        let name = environment.conversationTitle(for: chat)
        var views: [NSView] = [
            NativeUI.row([
                AvatarImageView(
                    name: name, path: environment.conversationAvatar(for: chat), group: chat.scene == .group, size: 56),
                NativeUI.column([
                    NativeUI.label(name, style: .title2),
                    NativeUI.label(
                        chat.scene == .group ? "Group Conversation" : "Direct Conversation", style: .caption1,
                        secondary: true),
                ]),
            ]),
            NativeUI.labeled(
                chat.scene == .group ? "Group ID" : "Account ID",
                NativeUI.label(environment.displayedPeerID(for: chat) ?? chat.peerID)),
        ]
        if chat.scene == .group {
            views.append(
                NativeUI.labeled(
                    "Members",
                    NativeUI.label(String(environment.members.values.filter { $0.groupID == chat.peerID }.count))))
        }
        if model.capabilities.supportsState {
            let pin = ActionButton(model.state.isPinned ? "Unpin" : "Pin") { [model] in
                model.run { try await model.setPinned(!model.state.isPinned) }
            }
            pin.setAccessibilityLabel(model.state.isPinned ? "Unpin Conversation" : "Pin Conversation")
            pin.isEnabled = model.capabilities.canInteract
            let read = ActionButton("Mark as Read") { [model] in model.run { try await model.markRead() } }
            read.setAccessibilityLabel("Mark All Messages as Read")
            read.isEnabled = model.capabilities.canInteract && !model.recentMessages.isEmpty
            let readStatus =
                model.recentMessages.last.map {
                    model.state.lastReadSequence >= $0.seq ? "All messages read" : "Unread messages"
                } ?? "No messages"
            views.append(
                contentSection(
                    "Conversation",
                    [
                        contentRow(
                            "Sidebar", detail: model.state.isPinned ? "Pinned conversation" : "Not pinned", control: pin
                        ),
                        contentRow("Read status", detail: readStatus, control: read),
                    ]))
        }
        if model.capabilities.supportsProfileLikes, let id = model.profileUserID {
            if likesUserID != id {
                likesUserID = id
                likesTask?.cancel()
                likesTask = Task { [model] in await model.observeLikes(for: id) }
            }
            let likes = model.profileLikes?.reduce(Int64(0)) { $0 + $1.count } ?? 0
            let send = ActionButton("Send Likes…", symbol: "hand.thumbsup") { [weak self] in
                self?.prompt("Send Profile Likes", value: "1", submit: "Send") { [model] text in
                    guard let count = Int(text), (1...10).contains(count) else {
                        throw NativeActionError(message: "Choose 1 to 10 likes")
                    }
                    try await model.likeProfile(count: count)
                }
            }
            send.isEnabled = model.capabilities.canInteract
            views.append(contentRow("Profile likes", detail: "\(likes) total likes", control: send))
        }
        return views
    }

    private func members() -> [NSView] {
        let environment = model.environment
        let chat = model.chat
        let roster = environment.members.values.filter { $0.groupID == chat.peerID }.sorted {
            $0.role != $1.role ? $0.role > $1.role : $0.userID < $1.userID
        }
        let add = ActionButton("Add Member…", symbol: "person.badge.plus") { [weak self] in
            guard let self, let window = view.window else { return }
            UserSelectionController(environment: environment, purpose: .group(chat.peerID)).present(on: window)
        }
        add.isEnabled = environment.activeUserID.map { id in roster.contains { $0.userID == id } } == true
        var views: [NSView] = [
            NativeUI.row([NativeUI.label("Members", style: .headline), NativeUI.spacer(), add]), memberSearch,
        ]
        for member in roster
        where memberQuery.isEmpty
            || environment.displayName(for: member.userID, in: chat).localizedCaseInsensitiveContains(memberQuery)
            || member.userID.contains(memberQuery)
        {
            let name = environment.displayName(for: member.userID, in: chat)
            let menu = NSMenu()
            if environment.supportsGroupModeration, environment.canRemoveGroupMember(member, from: chat.peerID) {
                for seconds in [0, 60, 600, 3600, 86400] {
                    menu.addItem(
                        ActionMenuItem(seconds == 0 ? "Remove Timeout" : "Timeout \(seconds) Seconds") {
                            Task { await environment.muteMember(member, in: chat, duration: TimeInterval(seconds)) }
                        })
                }
            }
            if environment.supportsGroupModeration,
                environment.activeUserID.flatMap({ environment.role(of: $0, in: chat.peerID) }) == .owner,
                member.role != .owner
            {
                menu.addItem(
                    ActionMenuItem(member.role == .admin ? "Remove Administrator" : "Make Administrator") {
                        Task { await environment.setAdmin(member, in: chat, granted: member.role != .admin) }
                    })
            }
            if environment.canRemoveGroupMember(member, from: chat.peerID) {
                menu.addItem(
                    ActionMenuItem("Remove from Group…") { [weak self] in
                        self?.confirm("Remove \(name)?", detail: "The member will be removed from this group.") {
                            try await environment.removeGroupMember(member.userID, from: chat.peerID)
                        }
                    })
            }
            var details = member.userID + (member.role == .owner ? " · Owner" : member.role == .admin ? " · Admin" : "")
            if member.isMuted, let until = member.mutedUntil {
                details += " · Timeout until " + until.formatted(date: .omitted, time: .shortened)
            }
            views.append(
                NativeUI.row([
                    AvatarImageView(name: name, path: environment.users.first { $0.id == member.userID }?.avatar),
                    NativeUI.column(
                        [NativeUI.label(name), NativeUI.label(details, style: .caption1, secondary: true)], spacing: 3),
                    NativeUI.spacer(), menuButton("Actions", menu),
                ]))
        }
        if model.capabilities.role.map({ $0 > .member }) == true, environment.supportsGroupModeration {
            let muted = environment.groups.first { $0.id == chat.peerID }?.wholeMuted == true
            views.append(
                contentRow(
                    "Group messaging", detail: muted ? "Muted for members" : "Members can send messages",
                    control: ActionButton(muted ? "Unmute Group" : "Mute Group") {
                        Task { await environment.setWholeMute(in: chat, muted: !muted) }
                    }))
        }
        views.append(
            NativeUI.label(
                "\(roster.count) / \(environment.groups.first { $0.id == chat.peerID }?.maxMemberCount ?? 0) members",
                style: .caption1, secondary: true))
        return views
    }

    private func files() -> [NSView] {
        let model = self.model
        var views: [NSView] = []
        if model.capabilities.supportsGroupContent {
            let folders = model.folders
            let choice = ChoiceButton(
                ["All Root Files"] + folders.map(\.name),
                selected: folders.firstIndex { $0.id == model.selectedFolderID }.map { $0 + 1 } ?? 0)
            choice.onChange = { [model] index in model.selectedFolderID = index == 0 ? "/" : folders[index - 1].id }
            choice.lineBreakMode = .byTruncatingMiddle
            choice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(contentRow("Folder", control: choice))
            if model.capabilities.canManageGroupContent {
                let menu = NSMenu()
                menu.addItem(
                    ActionMenuItem("New Folder…") { [weak self] in
                        self?.prompt("New Folder", submit: "Create") { [model] in try await model.createFolder(name: $0)
                        }
                    })
                if let folder = folders.first(where: { $0.id == model.selectedFolderID }) {
                    menu.addItem(
                        ActionMenuItem("Rename Folder…") { [weak self] in
                            self?.prompt("Rename Folder", value: folder.name, submit: "Rename") { [model] in
                                try await model.renameFolder(folder, to: $0)
                            }
                        })
                    menu.addItem(
                        ActionMenuItem("Delete Folder…") { [weak self] in
                            self?.confirm(
                                "Delete \(folder.name)?", detail: "The folder and its shared files will be removed."
                            ) { [model] in try await model.deleteFolder(folder) }
                        })
                }
                views.append(trailingActions([menuButton("Manage Folders", menu)]))
            }
        }
        if model.capabilities.canInteract {
            views.append(
                contentRow(
                    "Shared files",
                    control: ActionButton("Upload File…", symbol: "square.and.arrow.up") { [weak self] in
                        self?.chooseFile { [model] in try await model.uploadFile(at: $0) }
                    }))
        }
        guard let files = model.visibleFiles else { return views + [NativeUI.label("Loading files…", secondary: true)] }
        if files.isEmpty { views.append(NativeUI.label("No Shared Files", secondary: true)) }
        for file in files {
            var asset = file.asset
            asset.name = file.name
            let attachment = AttachmentContentView(asset: asset, environment: model.environment, kind: .file)
            attachment.onAccess = { [model] in try await model.download(file) }
            views.append(attachment)
            views.append(
                NativeUI.label(
                    model.environment.displayName(for: file.uploaderID, in: model.chat) + " · "
                        + file.uploadedAt.formatted(date: .abbreviated, time: .omitted), style: .caption1,
                    secondary: true))
            if let expires = file.expiresAt {
                views.append(NativeUI.label("Expires " + expires.formatted(), style: .caption1, secondary: true))
            }
            if model.canEdit(file) {
                let menu = NSMenu()
                menu.addItem(
                    ActionMenuItem("Rename…") { [weak self] in
                        self?.prompt("Rename File", value: file.name, submit: "Rename") { [model] in
                            try await model.renameFile(file, to: $0)
                        }
                    })
                menu.addItem(ActionMenuItem("Move…") { [weak self] in self?.move(file) })
                menu.addItem(
                    ActionMenuItem("Keep Permanently") { [model] in model.run { try await model.keepFile(file) } })
                menu.addItem(
                    ActionMenuItem("Delete…") { [weak self] in
                        self?.confirm(
                            "Delete \(file.name)?", detail: "The file will be removed from the group's shared files."
                        ) { [model] in try await model.deleteFile(file) }
                    })
                views.append(trailingActions([menuButton("File Actions", menu)]))
            }
        }
        return views
    }

    private func announcements() -> [NSView] {
        let model = self.model
        var views: [NSView] = []
        if model.capabilities.canManageGroupContent {
            views.append(
                trailingActions([
                    ActionButton("New Announcement…", symbol: "plus") { [weak self] in self?.newAnnouncement() }
                ]))
        }
        guard let announcements = model.announcements else {
            return views + [NativeUI.label("Loading announcements…", secondary: true)]
        }
        if announcements.isEmpty { views.append(NativeUI.label("No Announcements", secondary: true)) }
        for announcement in announcements {
            views.append(
                NativeUI.label(
                    model.environment.displayName(for: announcement.senderID, in: model.chat) + " · "
                        + announcement.time.formatted(), style: .caption1, secondary: true))
            views.append(MarkdownMessageView(source: announcement.content))
            if let image = announcement.image {
                views.append(AttachmentContentView(asset: image, environment: model.environment, kind: .image))
            }
            if model.capabilities.canManageGroupContent {
                views.append(
                    trailingActions([
                        ActionButton("Delete Announcement…") { [weak self] in
                            self?.confirm(
                                "Delete announcement?", detail: "This announcement will be removed from the group."
                            ) { [model] in try await model.deleteAnnouncement(announcement) }
                        }
                    ]))
            }
        }
        return views
    }

    private func highlights() -> [NSView] {
        var views: [NSView] = []
        if model.capabilities.canManageGroupContent {
            views.append(
                trailingActions([
                    ActionButton("Add Highlight…", symbol: "star") { [weak self] in
                        guard let self, let window = view.window else { return }
                        let existing = Set(model.highlightedMessages?.map(\.id) ?? [])
                        let messages = model.recentMessages.reversed().filter {
                            !$0.isRecalled && !existing.contains($0.id)
                        }
                        SelectionSheetController(
                            title: "Highlight a Recent Message", items: messages,
                            description: { $0.content.textPreview }
                        ) { [model] in try await model.setHighlight($0, enabled: true) }.present(on: window)
                    }
                ]))
        }
        guard let messages = model.highlightedMessages else {
            return views + [NativeUI.label("Loading highlights…", secondary: true)]
        }
        if messages.isEmpty { views.append(NativeUI.label("No Highlights", secondary: true)) }
        for message in messages {
            views.append(
                NativeUI.label(
                    model.environment.displayName(for: message.senderID, in: model.chat), style: .caption1,
                    secondary: true))
            views.append(MessageSegmentsContentView(message.content, environment: model.environment, chat: model.chat))
            var actions: [NSView] = [ActionButton("Go to Message") { [model] in Task { await model.reveal(message) } }]
            if model.capabilities.canManageGroupContent {
                actions.append(
                    ActionButton("Remove Highlight") { [model] in
                        model.run { try await model.setHighlight(message, enabled: false) }
                    })
            }
            views.append(trailingActions(actions))
        }
        return views
    }

    private func menuButton(_ title: String, _ menu: NSMenu) -> NSPopUpButton {
        let button = NSPopUpButton(title: title, pullDownMenu: menu)
        NativeUI.configureGlassButton(button)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setAccessibilityLabel(title)
        return button
    }

    private func contentRow(_ title: String, detail: String? = nil, control: NSView) -> NSView {
        let label = NativeUI.label(title)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let description = NativeUI.column([label], spacing: 3)
        if let detail { description.addArrangedSubview(NativeUI.label(detail, style: .caption1, secondary: true)) }
        description.setContentHuggingPriority(.init(1), for: .horizontal)
        description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in description.arrangedSubviews {
            label.widthAnchor.constraint(equalTo: description.widthAnchor).isActive = true
        }
        return NativeUI.row([description, control])
    }

    private func contentSection(_ title: String, _ rows: [NSView]) -> NSView {
        let section = NativeUI.column([NativeUI.label(title, style: .headline)] + rows, spacing: 12)
        section.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        for row in rows { row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true }
        return section
    }

    private func trailingActions(_ controls: [NSView]) -> NSView {
        NativeUI.row([NativeUI.spacer()] + controls)
    }

    private func prompt(
        _ title: String, value: String = "", submit: String,
        operation: @escaping @MainActor (String) async throws -> Void
    ) {
        guard let window = view.window else { return }
        let field = NativeUI.field(title, value: value)
        FormSheetController(title: title, fields: [field], submit: submit) { try await operation(field.stringValue) }
            .present(on: window)
    }

    private func confirm(_ title: String, detail: String, operation: @escaping @MainActor () async throws -> Void) {
        NativeUI.confirm(title, detail: detail, button: "Delete", on: view.window) { [model] in model.run(operation) }
    }

    private func chooseFile(operation: @escaping @MainActor (URL) async throws -> Void) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [model] result in
            if result == .OK, let url = panel.url { model.run { try await operation(url) } }
        }
    }

    private func move(_ file: SharedFile) {
        guard let window = view.window else { return }
        let folders = model.folders.filter { $0.id != file.folderID }
        let choice = ChoiceButton(["Root"] + folders.map(\.name))
        choice.lineBreakMode = .byTruncatingMiddle
        choice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        FormSheetController(title: "Move File", fields: [contentRow("Destination", control: choice)], submit: "Move") {
            [model] in
            try await model.moveFile(
                file, to: choice.indexOfSelectedItem == 0 ? "/" : folders[choice.indexOfSelectedItem - 1].id)
        }.present(on: window)
    }

    private func newAnnouncement() {
        guard let window = view.window else { return }
        let scroll = NSTextView.scrollableTextView()
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false
        editor.setAccessibilityLabel("Announcement Text")
        let imageName = NativeUI.label("No image", secondary: true)
        var image: Asset?
        let choose = ActionButton("Add Image…", symbol: "photo.badge.plus") { [model] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.canChooseDirectories = false
            panel.begin { result in
                if result == .OK, let url = panel.url {
                    model.run {
                        image = try await model.importImage(at: url)
                        imageName.stringValue = image?.name ?? "No image"
                    }
                }
            }
        }
        let remove = ActionButton("Remove Image") {
            image = nil
            imageName.stringValue = "No image"
        }
        FormSheetController(
            title: "New Announcement", fields: [scroll, NativeUI.row([choose, remove, NativeUI.spacer()]), imageName],
            submit: "Post Announcement"
        ) { [model] in
            guard !model.isWorking else { throw NativeActionError(message: "Wait for image import to finish") }
            guard !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil else {
                throw NativeActionError(message: "Enter announcement text or add an image")
            }
            try await model.postAnnouncement(content: editor.string, image: image)
        }.present(on: window)
    }
}
