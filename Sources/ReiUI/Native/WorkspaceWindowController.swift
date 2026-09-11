import AppKit
import ReiCore

final class WorkspaceViewController: NSSplitViewController {
    let sidebar: SidebarViewController
    let conversation: ConversationViewController
    let inspector: InspectorViewController
    let events: TrafficViewController
    let content = NSSplitViewController()
    let workbench = NSSplitViewController()
    let sidebarItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem
    let eventsItem: NSSplitViewItem
    var onEventsVisibilityChange: ((Bool) -> Void)?
    private let preferencesPrefix: String
    private var eventsVisibilityObservation: NSKeyValueObservation?

    var isEventsVisible: Bool { !eventsItem.isCollapsed }

    init(environment: AppEnvironment, showcase: ShowcaseSession?) {
        sidebar = SidebarViewController(environment: environment, showcase: showcase)
        conversation = ConversationViewController(environment: environment, showcase: showcase)
        inspector = InspectorViewController(environment: environment)
        events = TrafficViewController(environment: environment)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        eventsItem = NSSplitViewItem(viewController: events)
        preferencesPrefix = showcase == nil ? "workspace.native" : "showcase.native"
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = preferencesPrefix + ".sidebarSplit"
        sidebarItem.minimumThickness = 230
        sidebarItem.maximumThickness = 420
        sidebarItem.preferredThicknessFraction = 0.20
        sidebarItem.holdingPriority = NativeUI.paneHoldingPriority
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        let conversationItem = NSSplitViewItem(viewController: conversation)
        conversationItem.minimumThickness = 400
        inspectorItem.minimumThickness = 320
        inspectorItem.maximumThickness = 640
        inspectorItem.preferredThicknessFraction = 0.25
        inspectorItem.holdingPriority = .init(NativeUI.paneHoldingPriority.rawValue - 1)
        // This nested split shares its width with the console below it.
        // Resize through their shared constraints instead of window-level sizing.
        inspectorItem.collapseBehavior = .useConstraints
        inspectorItem.canCollapse = true
        inspectorItem.allowsFullHeightLayout = true
        content.splitView.isVertical = true
        content.splitView.dividerStyle = .thin
        content.splitView.autosaveName = preferencesPrefix + ".contentSplit"
        content.addSplitViewItem(conversationItem)
        content.addSplitViewItem(inspectorItem)

        workbench.splitView.isVertical = false
        workbench.splitView.dividerStyle = .thin
        workbench.splitView.autosaveName = preferencesPrefix + ".eventsSplit"
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 300
        eventsItem.minimumThickness = 220
        eventsItem.preferredThicknessFraction = 0.35
        eventsItem.holdingPriority = NativeUI.paneHoldingPriority
        eventsItem.canCollapse = true
        eventsItem.canCollapseFromWindowResize = false
        eventsItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        workbench.addSplitViewItem(contentItem)
        workbench.addSplitViewItem(eventsItem)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: workbench))
        restorePaneVisibility()
        events.onClose = { [weak self] in self?.setEventsVisible(false) }
        eventsVisibilityObservation = eventsItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UserDefaults.standard.set(self.isEventsVisible, forKey: self.preferencesPrefix + ".events")
                self.onEventsVisibilityChange?(self.isEventsVisible)
            }
        }
        sidebar.inspect = { [weak self] chat, section in
            self?.showInspector(chat: chat, section: section, environment: environment)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func restorePaneVisibility() {
        sidebarItem.isCollapsed =
            UserDefaults.standard.object(forKey: preferencesPrefix + ".sidebar") as? Bool == false
        inspectorItem.isCollapsed =
            UserDefaults.standard.object(forKey: preferencesPrefix + ".inspector") as? Bool != true
        eventsItem.isCollapsed =
            UserDefaults.standard.object(forKey: preferencesPrefix + ".events") as? Bool != true
    }

    func toggleSidebarPane() {
        NativeUI.animate { sidebarItem.animator().isCollapsed.toggle() }
        UserDefaults.standard.set(!sidebarItem.isCollapsed, forKey: preferencesPrefix + ".sidebar")
    }

    func toggleInspectorPane() { setInspectorVisible(inspectorItem.isCollapsed) }

    func setInspectorVisible(_ visible: Bool) {
        NativeUI.animate { inspectorItem.animator().isCollapsed = !visible }
        UserDefaults.standard.set(visible, forKey: preferencesPrefix + ".inspector")
    }

    func toggleEventsPane() { setEventsVisible(!isEventsVisible) }

    func setEventsVisible(_ visible: Bool) {
        NativeUI.animate { eventsItem.animator().isCollapsed = !visible }
    }

    private func showInspector(chat: Chat, section: ConversationInspectorSection, environment: AppEnvironment) {
        environment.selectChat(chat)
        inspector.show(section: section)
        setInspectorVisible(true)
    }
}

final class InspectorViewController: NSViewController {
    private let environment: AppEnvironment
    private let container = NSView()
    private let emptyState = NativeUI.column(spacing: 12)
    private var details: ConversationDetailsController?
    private var displayedChat: Chat?
    private var section: ConversationInspectorSection = .overview
    private var observation: ModelObservation?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let material = NSVisualEffectView()
        material.material = .contentBackground
        material.blendingMode = .withinWindow
        view = material
        let column = NativeUI.column([container], spacing: 0)
        NativeUI.embed(column, in: view, respectingSafeArea: true)
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        container.setContentHuggingPriority(.init(1), for: .vertical)
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 28, weight: .light)
        symbol.contentTintColor = .tertiaryLabelColor
        let heading = NativeUI.label("Conversation Details", style: .headline)
        let explanation = NativeUI.label(
            "Select a conversation to see its people, files and activity.", secondary: true)
        explanation.alignment = .center
        for child in [symbol, heading, explanation] { emptyState.addArrangedSubview(child) }
        emptyState.alignment = .centerX
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -24),
            emptyState.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -48),
            explanation.widthAnchor.constraint(equalTo: emptyState.widthAnchor),
        ])
        observation = ModelObservation { [weak self] in self?.refresh() }
    }

    func show(section: ConversationInspectorSection) {
        self.section = section
        loadViewIfNeeded()
        refresh()
    }

    private func refresh() {
        if environment.selectedChat != displayedChat {
            displayedChat = environment.selectedChat
            details?.view.removeFromSuperview()
            details?.removeFromParent()
            details = nil
            if let chat = displayedChat {
                let controller = ConversationDetailsController(environment: environment, chat: chat, section: section)
                addChild(controller)
                NativeUI.embed(controller.view, in: container)
                details = controller
            }
        }
        details?.section = section
        emptyState.isHidden = details != nil
    }
}

final class WorkspaceWindowController: NSWindowController, NSToolbarDelegate, NSMenuDelegate {
    let workspace: WorkspaceViewController
    let environment: AppEnvironment
    let showcase: ShowcaseSession?
    private var settingsController: SettingsWindowController?
    private weak var eventsButton: NSButton?
    private var observation: ModelObservation?
    private var displayedError: String?

    init(environment: AppEnvironment, showcase: ShowcaseSession?) {
        self.environment = environment
        self.showcase = showcase
        workspace = WorkspaceViewController(environment: environment, showcase: showcase)
        let window = NSWindow(contentViewController: workspace)
        window.styleMask.insert(.fullSizeContentView)
        window.title = "Rei"
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 1320, height: 820))
        window.minSize = NSSize(width: 980, height: 620)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setFrameAutosaveName(showcase == nil ? "ReiMainWindow" : "ReiShowcaseWindow")
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "Workspace")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        workspace.onEventsVisibilityChange = { [weak self] _ in self?.updateEventsButton() }
        // Restoring window geometry can also restore the split view's saved layout.
        workspace.restorePaneVisibility()
        updateEventsButton()
        workspace.sidebar.createUser = { [weak self] in self?.createUser() }
        workspace.sidebar.addFriend = { [weak self] in self?.addFriend() }
        workspace.sidebar.createGroup = { [weak self] in self?.createGroup() }
        workspace.sidebar.showSettings = { [weak self] in self?.showSettings() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(sheetDidEnd), name: NSWindow.didEndSheetNotification, object: window)
        observation = ModelObservation { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        window?.title = environment.selectedChat.map { environment.conversationTitle(for: $0) } ?? "Rei"
        showcase?.selectedChatChanged(environment.selectedChat)
        if let error = environment.lastError, displayedError == nil, let window, window.attachedSheet == nil {
            displayedError = error
            let alert = NSAlert(error: NativeActionError(message: error))
            alert.beginSheetModal(for: window) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if environment.lastError == error { environment.lastError = nil }
                    displayedError = nil
                    refresh()
                }
            }
        }
    }

    @objc private func sheetDidEnd(_ notification: Notification) { refresh() }

    func showSettings(_ tab: ReiSettingsTab = .connection) {
        if settingsController?.window?.isVisible != true {
            settingsController = SettingsWindowController(environment: environment, tab: tab)
        }
        settingsController?.select(tab)
        settingsController?.showWindow(nil)
    }

    func createUser() { if let window { PersonaForms.createUser(environment: environment, on: window) } }
    func createGroup() { if let window { PersonaForms.createGroup(environment: environment, on: window) } }
    func addFriend() {
        if let window { UserSelectionController(environment: environment, purpose: .friend).present(on: window) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
            .init("sidebar"), .sidebarTrackingSeparator, .flexibleSpace,
        ]
        if showcase != nil { identifiers.append(.init("demo")) }
        identifiers += [.init("inspectorSeparator"), .flexibleSpace, .init("events"), .init("inspector")]
        return identifiers
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "inspectorSeparator":
            return NSTrackingSeparatorToolbarItem(
                identifier: identifier, splitView: workspace.content.splitView, dividerIndex: 0)
        case "sidebar":
            item.label = "Toggle Sidebar"
            item.view = ActionButton("", symbol: "sidebar.leading") { [weak self] in self?.workspace.toggleSidebarPane()
            }
        case "inspector":
            item.label = "Toggle Inspector"
            item.view = ActionButton("", symbol: "sidebar.trailing") { [weak self] in
                self?.workspace.toggleInspectorPane()
            }
        case "events":
            item.label = "Toggle Events"
            let button = ActionButton("", symbol: "rectangle.bottomthird.inset.filled") { [weak self] in
                self?.workspace.toggleEventsPane()
            }
            button.setButtonType(.pushOnPushOff)
            eventsButton = button
            item.view = button
        case "demo":
            let demo = NSMenuToolbarItem(itemIdentifier: identifier)
            demo.label = "Demo"
            demo.title = "Demo"
            demo.toolTip = "Demo playback controls"
            demo.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Demo")
            demo.menu = NSMenu(title: "Demo")
            demo.menu.autoenablesItems = false
            demo.menu.delegate = self
            menuNeedsUpdate(demo.menu)
            return demo
        default: return nil
        }
        if let button = item.view as? NSButton {
            button.isBordered = false
            button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
            button.setAccessibilityLabel(item.label)
            button.toolTip = item.label
        }
        if identifier.rawValue == "events" { updateEventsButton() }
        return item
    }

    private func updateEventsButton() {
        let visible = workspace.isEventsVisible
        eventsButton?.state = visible ? .on : .off
        eventsButton?.toolTip = visible ? "Hide Events" : "Show Events"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let showcase else { return }
        let state = NSMenuItem(
            title: showcase.isPlaying ? "Demo Playing · Every 4 Seconds" : "Demo Paused", action: nil, keyEquivalent: ""
        )
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(
            ActionMenuItem(showcase.isPlaying ? "Pause Demo" : "Resume Demo") {
                if !showcase.isPlaying { showcase.resumeFollowing() }
                showcase.isPlaying.toggle()
            })
        let follow = ActionMenuItem("Auto-follow") {
            if showcase.isFollowing {
                showcase.isFollowing = false
                showcase.isPlaying = false
            } else {
                showcase.resumeFollowing()
            }
        }
        follow.state = showcase.isFollowing ? .on : .off
        menu.addItem(follow)
        if let error = showcase.errorMessage ?? showcase.connection.errorMessage {
            let item = menu.addItem(withTitle: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
    }
}
