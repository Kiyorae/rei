import AppKit
import ReiCore
import ReiProtocol

final class SettingsWindowController: NSWindowController {
    private let environment: AppEnvironment
    private let sidebar = SettingsSidebarController()
    private let detail: SettingsDetailController
    private let connection: ConnectionPreferencesController
    private let roles: PersonaPreferencesController
    private var isSaving = false

    init(environment: AppEnvironment, tab: ReiSettingsTab) {
        self.environment = environment
        connection = ConnectionPreferencesController(environment: environment)
        roles = PersonaPreferencesController(environment: environment)
        detail = SettingsDetailController(pages: [connection, roles, AboutViewController(environment: environment)])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 560)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        super.init(window: window)
        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "settings.native.split"
        let navigation = NSSplitViewItem(sidebarWithViewController: sidebar)
        navigation.minimumThickness = 200
        navigation.maximumThickness = 320
        navigation.holdingPriority = NativeUI.paneHoldingPriority
        navigation.canCollapse = false
        split.addSplitViewItem(navigation)
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 480
        split.addSplitViewItem(detailItem)
        window.contentViewController = split
        sidebar.onSelectionChange = { [weak detail] page in detail?.select(page) }
        detail.onCancel = { [weak self] in self?.close() }
        detail.onSave = { [weak self] in self?.save() }
        select(tab)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ tab: ReiSettingsTab) {
        let page: SettingsPage = tab == .connection ? .connection : tab == .roles ? .personas : .about
        sidebar.select(page)
        detail.select(page)
    }

    private func save() {
        if detail.selectedPage == .about {
            close()
            return
        }
        guard !isSaving else { return }
        do {
            let settings = try connection.validatedSettings()
            isSaving = true
            detail.setSaving(true)
            detail.statusMessage = "Saving…"
            Task {
                defer {
                    isSaving = false
                    detail.setSaving(false)
                }
                environment.settings = settings
                environment.selectedProtocol = connection.protocolChoice
                if let user = roles.activeUserID, user != environment.activeUserID { environment.setActiveUser(user) }
                var changed = true
                if let user = roles.botUserID, user != environment.botUserID {
                    changed = await environment.setBotUser(user)
                }
                if environment.saveSettings() && changed {
                    close()
                } else {
                    detail.statusMessage = environment.lastError ?? "Unable to save settings"
                }
            }
        } catch { detail.statusMessage = error.localizedDescription }
    }
}

private enum SettingsPage: Int, CaseIterable {
    case connection, personas, about

    var title: String {
        switch self {
        case .connection: "Connection"
        case .personas: "Personas"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .connection: "network"
        case .personas: "person.crop.circle"
        case .about: "info.circle"
        }
    }

    var summary: String {
        switch self {
        case .connection: "Choose a protocol and configure how your bot connects to Rei."
        case .personas: "Choose the identities used for your messages and your bot."
        case .about: "App information, local storage, and open source acknowledgements."
        }
    }
}

private final class SettingsSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectionChange: ((SettingsPage) -> Void)?
    private let table = NSTableView()

    override func loadView() {
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        view = material

        let heading = SettingsForm.label("Settings", size: 17, weight: .semibold)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settingsPage"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Settings Pages")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        for child in [heading, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
        table.reloadData()
    }

    func select(_ page: SettingsPage) {
        loadViewIfNeeded()
        table.selectRowIndexes(IndexSet(integer: page.rawValue), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SettingsPage.allCases.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let page = SettingsPage(rawValue: row) else { return nil }
        let cell = NSTableCellView()
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
        image.contentTintColor = .secondaryLabelColor
        let title = SettingsForm.label(page.title)
        cell.imageView = image
        cell.textField = title
        for child in [image, title] {
            child.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(child)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let page = SettingsPage(rawValue: table.selectedRow) else { return }
        onSelectionChange?(page)
    }
}

private final class SettingsDetailController: NSViewController {
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    private(set) var selectedPage: SettingsPage?
    private let pages: [NSViewController]
    private let heading = SettingsForm.label("", size: 24, weight: .semibold)
    private let summary = SettingsForm.label("", size: 12, secondary: true)
    private let status = SettingsForm.label("", size: 12, secondary: true)
    private let pageContainer = NSView()
    private let cancel = ActionButton("Cancel") {}
    private let save = ActionButton("Save") {}

    var statusMessage: String {
        get { status.stringValue }
        set { status.stringValue = newValue }
    }

    init(pages: [NSViewController]) {
        self.pages = pages
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        cancel.keyEquivalent = "\u{1b}"
        cancel.onAction = { [weak self] in self?.onCancel?() }
        save.keyEquivalent = "\r"
        save.onAction = { [weak self] in self?.onSave?() }
        let header = NativeUI.column([heading, summary], spacing: 8)
        let footer = NativeUI.row([status, NativeUI.spacer(), cancel, save])
        let separator = NSBox()
        separator.boxType = .separator
        for child in [header, pageContainer, separator, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            pageContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            pageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            heading.widthAnchor.constraint(equalTo: header.widthAnchor),
            summary.widthAnchor.constraint(equalTo: header.widthAnchor),
        ])
    }

    func select(_ page: SettingsPage) {
        loadViewIfNeeded()
        guard selectedPage != page else { return }
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        let controller = pages[page.rawValue]
        addChild(controller)
        NativeUI.embed(controller.view, in: pageContainer)
        selectedPage = page
        heading.stringValue = page.title
        summary.stringValue = page.summary
        save.title = page == .about ? "Done" : "Save"
        cancel.isHidden = page == .about
        status.stringValue = ""
    }

    func setSaving(_ saving: Bool) {
        save.isEnabled = !saving
        cancel.isEnabled = !saving
    }
}

@MainActor
private enum SettingsForm {
    static func label(
        _ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func row(_ title: String, _ control: NSControl, description: String? = nil) -> NSView {
        let name = label(title)
        let caption = NativeUI.column([name], spacing: 4)
        if let description { caption.addArrangedSubview(label(description, size: 12, secondary: true)) }
        for child in caption.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: caption.widthAnchor).isActive = true
        }
        control.font = .systemFont(ofSize: 13)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        control.setAccessibilityLabel(title)
        let row = NativeUI.row([caption, control], spacing: 16)
        NSLayoutConstraint.activate([
            control.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.55),
            control.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        return row
    }

    static func fieldRow(_ title: String, _ field: NSTextField, width: CGFloat = 220) -> NSView {
        let preferredWidth = field.widthAnchor.constraint(equalToConstant: width)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        let row = row(title, field)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    static func section(_ title: String, _ rows: [NSView]) -> NSView {
        let content = NativeUI.column(rows, spacing: 16)
        for row in rows { row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderColor = .separatorColor
        box.borderWidth = 0.5
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 12
        box.contentViewMargins = NSSize(width: 16, height: 16)
        box.contentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
        ])
        let section = NativeUI.column([label(title, weight: .semibold), box], spacing: 12)
        box.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    static func page(_ sections: [NSView]) -> NSScrollView {
        let column = NativeUI.column(sections, spacing: 24)
        column.edgeInsets = NSEdgeInsets(top: 0, left: 28, bottom: 24, right: 28)
        for section in sections {
            section.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -56).isActive = true
        }
        return NativeUI.scroll(column)
    }
}

private final class ConnectionPreferencesController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    private var settings: ConnectionSettings
    private var selectedProtocol: ProtocolChoice
    private let protocols = ChoiceButton(ProtocolChoice.allCases.map(\.shortDisplayName))
    private let transport = ChoiceButton([])
    private let host = NativeUI.field("Host")
    private let port = NativeUI.field("Port")
    private let path = NativeUI.field("Path")
    private let resourceHost = NativeUI.field("Resource Host")
    private let token = NSSecureTextField()
    private let reconnect = NSSwitch()
    private let reconnectDelay = NativeUI.field("Reconnect Delay")
    private let echo = NSSwitch()
    private let webhooks = NSTextView.scrollableTextView()
    private let endpoint = SettingsForm.label("", size: 12, secondary: true)
    private var pathRow: NSView!
    private var resourceRow: NSView!
    private var webhookRow: NSView!
    private var reconnectRow: NSStackView!

    var protocolChoice: ProtocolChoice { selectedProtocol }

    init(environment: AppEnvironment) {
        settings = environment.settings
        selectedProtocol = environment.selectedProtocol
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        host.stringValue = settings.host
        port.stringValue = String(settings.port)
        path.stringValue = settings.path
        resourceHost.stringValue = settings.resourceHost
        token.stringValue = settings.accessToken
        token.placeholderString = "Access Token"
        token.setAccessibilityLabel("Access Token")
        token.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reconnect.state = settings.autoReconnect ? .on : .off
        reconnectDelay.stringValue = String(Int(settings.reconnectInterval))
        echo.state = settings.postSelfEvents ? .on : .off
        reconnect.controlSize = .small
        echo.controlSize = .small
        let text = webhooks.documentView as! NSTextView
        text.isRichText = false
        text.string = settings.milkyWebhookURLs.joined(separator: "\n")
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.setAccessibilityLabel("WebHook URLs, one per line")
        text.delegate = self
        webhooks.borderType = .bezelBorder
        webhooks.heightAnchor.constraint(equalToConstant: 90).isActive = true
        protocols.selectItem(at: ProtocolChoice.allCases.firstIndex(of: selectedProtocol) ?? 0)
        protocols.onChange = { [weak self] index in
            guard let self else { return }
            selectedProtocol = ProtocolChoice.allCases[index]
            updateTransport()
        }
        transport.onChange = { [weak self] index in
            guard let self else { return }
            settings.transport = selectedProtocol.supportedTransports[index]
            updateTransport()
        }
        for field in [host, port, path, resourceHost, reconnectDelay] { field.delegate = self }
        pathRow = SettingsForm.fieldRow("Path", path)
        resourceRow = SettingsForm.section("Resources", [SettingsForm.fieldRow("Resource Host", resourceHost)])
        webhookRow = SettingsForm.section(
            "Event WebHooks",
            [SettingsForm.label("Deliver events to these URLs, one per line.", size: 12, secondary: true), webhooks])
        reconnectRow = NativeUI.column(
            [
                SettingsForm.row(
                    "Reconnect Automatically", reconnect, description: "Reconnect if the connection is interrupted."),
                SettingsForm.fieldRow("Delay (seconds)", reconnectDelay, width: 80),
            ], spacing: 16)
        for child in reconnectRow.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: reconnectRow.widthAnchor).isActive = true
        }
        view = SettingsForm.page([
            SettingsForm.section(
                "Protocol",
                [
                    SettingsForm.row(
                        "Protocol Standard", protocols, description: "The protocol used by your bot framework."),
                    SettingsForm.row(
                        "Connection Mode", transport, description: "How Rei connects to your bot framework."),
                ]),
            SettingsForm.section(
                "Address",
                [
                    SettingsForm.fieldRow("Host", host), SettingsForm.fieldRow("Port", port, width: 80), pathRow,
                    endpoint,
                ]),
            resourceRow, webhookRow,
            SettingsForm.section(
                "Authentication",
                [
                    SettingsForm.fieldRow("Access Token", token),
                    SettingsForm.label(
                        "An empty token disables authentication. Use a token when accepting connections beyond this Mac. Milky uses it for API, event WebSocket and WebHook deliveries.",
                        size: 12, secondary: true),
                ]),
            SettingsForm.section(
                "Behavior",
                [
                    reconnectRow,
                    SettingsForm.row(
                        "Echo Bot-Generated Events", echo,
                        description: "Include the bot's own actions in events. This can create event loops."),
                ]),
        ])
        updateTransport()
    }

    func controlTextDidChange(_ notification: Notification) { updateEndpoint() }
    func textDidChange(_ notification: Notification) { updateEndpoint() }

    private func updateTransport() {
        let modes = selectedProtocol.supportedTransports
        if !modes.contains(settings.transport) { settings.transport = modes[0] }
        transport.removeAllItems()
        transport.addItems(
            withTitles: modes.map { mode in
                switch mode {
                case .webSocketServer: "WebSocket Server"
                case .webSocketClient: "WebSocket Client"
                case .milkyService: "Milky Service"
                }
            })
        transport.selectItem(at: modes.firstIndex(of: settings.transport) ?? 0)
        transport.toolTip = settings.transport.displayName
        if settings.transport == .webSocketClient {
            path.stringValue = selectedProtocol.resolvingWebSocketClientPath(path.stringValue)
        }
        pathRow.isHidden = settings.transport != .webSocketClient
        resourceRow.isHidden = selectedProtocol == .milky
        webhookRow.isHidden = selectedProtocol != .milky
        reconnectRow.isHidden = settings.transport != .webSocketClient
        updateEndpoint()
    }

    private func updateEndpoint() {
        guard let value = try? validatedSettings() else {
            endpoint.stringValue = "Enter a valid port and WebHook URLs"
            return
        }
        if value.transport == .milkyService {
            endpoint.stringValue =
                "API: http://\(value.host):\(value.port)/api/\nEvents: \(value.eventStreamURL?.absoluteString ?? "")"
        } else {
            endpoint.stringValue =
                value.webSocketURL(defaultPath: selectedProtocol.webSocketClientDefaultPath ?? "/")?.absoluteString
                ?? "Invalid endpoint"
        }
        endpoint.isSelectable = true
    }

    func validatedSettings() throws -> ConnectionSettings {
        loadViewIfNeeded()
        var result = settings
        let value = port.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt16(value), number > 0
        else { throw NativeActionError(message: "Port must be a decimal integer between 1 and 65535") }
        result.port = number
        result.host = host.stringValue
        result.path = path.stringValue
        result.resourceHost = resourceHost.stringValue
        result.accessToken = token.stringValue
        result.autoReconnect = reconnect.state == .on
        guard let delay = Double(reconnectDelay.stringValue), delay >= 1, delay <= 60 else {
            throw NativeActionError(message: "Reconnect delay must be between 1 and 60 seconds")
        }
        result.reconnectInterval = delay
        result.postSelfEvents = echo.state == .on
        result.milkyWebhookURLs = (webhooks.documentView as! NSTextView).string.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        if selectedProtocol == .milky, result.milkyWebhookEndpoints == nil {
            throw NativeActionError(message: "WebHook destinations must be absolute HTTP or HTTPS URLs")
        }
        return result
    }
}

private final class PersonaPreferencesController: NSViewController {
    private let environment: AppEnvironment
    private let sender = ChoiceButton([])
    private let bot = ChoiceButton([])
    private var users: [User] = []
    private(set) var activeUserID: User.ID?
    private(set) var botUserID: User.ID?
    private var observation: ModelObservation?

    init(environment: AppEnvironment) {
        self.environment = environment
        activeUserID = environment.activeUserID
        botUserID = environment.botUserID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        sender.onChange = { [weak self] index in
            guard let self else { return }
            activeUserID = index > 0 ? users[index - 1].id : nil
        }
        bot.onChange = { [weak self] index in
            guard let self else { return }
            botUserID = index > 0 ? users[index - 1].id : nil
        }
        let create = ActionButton("New Persona…", symbol: "person.badge.plus") { [weak self] in
            guard let self, let window = view.window else { return }
            PersonaForms.createUser(environment: environment, on: window)
        }
        view = SettingsForm.page([
            SettingsForm.section(
                "Identity Assignment",
                [
                    SettingsForm.row(
                        "Sending Identity", sender, description: "The identity used for your messages and actions."),
                    SettingsForm.row("Bot Account", bot, description: "The account represented by the bot framework."),
                ]),
            SettingsForm.section(
                "Manage Personas",
                [
                    SettingsForm.row(
                        "Local Identities", create,
                        description: "Create a local identity for conversations and events.")
                ]),
        ])
        observation = ModelObservation { [weak self] in self?.refresh() }
    }

    private func refresh() {
        users = environment.users
        if activeUserID == nil { activeUserID = environment.activeUserID }
        if botUserID == nil { botUserID = environment.botUserID }
        for (control, id) in [(sender, activeUserID), (bot, botUserID)] {
            control.removeAllItems()
            control.addItems(withTitles: ["Not Set"] + users.map { $0.displayName + " · " + $0.id })
            control.selectItem(at: users.firstIndex { $0.id == id }.map { $0 + 1 } ?? 0)
        }
    }
}
