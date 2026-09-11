import AppKit
import ReiCore
import ReiProtocol
import Testing

@testable import ReiLogging
@testable import ReiUI

@Suite("Workspace Layout", .serialized)
@MainActor
struct WorkspaceLayoutTests {
    @Test("Inspector content stays inside its viewport in the actual toolbar window")
    func inspectorWindowGeometry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = WorkspaceWindowController(environment: fixture.environment, showcase: nil)
        let window = try #require(controller.window)
        controller.workspace.inspectorItem.isCollapsed = false
        controller.workspace.eventsItem.isCollapsed = true
        controller.showWindow(nil)
        defer { controller.close() }
        try await Task.sleep(for: .milliseconds(500))
        window.contentView?.layoutSubtreeIfNeeded()
        let details = try #require(
            controller.workspace.inspector.children.compactMap { $0 as? ConversationDetailsController }.first)
        let pane = try #require(details.children.first as? ConversationContentPane)
        let scroll = try #require(pane.view as? NSScrollView)
        let document = try #require(scroll.documentView)
        #expect(scroll.bounds.height > 300)
        #expect(abs(scroll.documentVisibleRect.minY) < 1)
        #expect(document.frame.minY >= 0)
        let column = try #require(document.subviews.first as? NSStackView)
        let first = try #require(column.arrangedSubviews.first)
        let firstFrame = first.convert(first.bounds, to: scroll.contentView)
        #expect(scroll.contentView.bounds.intersects(firstFrame))
        #expect(scroll.contentView.clipsToBounds)
        #expect(window.toolbar?.items.filter { $0.itemIdentifier.rawValue == "inspector" }.count == 1)
        let buttons = descendants(NSButton.self, in: controller.workspace.view)
        #expect(
            !buttons.contains {
                ["Settings", "Close Inspector", "Toggle Inspector"].contains($0.accessibilityLabel() ?? "")
            })
        let sidebar = controller.workspace.sidebar.view
        let connection = try #require(buttons.first { $0.title.hasPrefix("Milky") })
        let identity = try #require(buttons.first { $0.accessibilityLabel() == "Switch Sending Identity" })
        #expect(connection.convert(connection.bounds, to: sidebar).midY < 120)
        #expect(identity.convert(identity.bounds, to: sidebar).midY < 100)
    }

    @Test("The bottom events pane preserves its filters and leaves sidebar and inspector visibility independent")
    func fullHeightPanes() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = WorkspaceWindowController(environment: fixture.environment, showcase: nil)
        let window = try #require(controller.window)
        let workspace = controller.workspace
        let inspectorWasVisible = !workspace.inspectorItem.isCollapsed
        // Exercise real target/actions with deterministic layout in SwiftPM's
        // non-foreground host. Verify animated pointer interactions in the app.
        for item in [workspace.sidebarItem, workspace.inspectorItem, workspace.eventsItem] {
            item.animations = ["collapsed": NSNull()]
        }
        workspace.sidebarItem.isCollapsed = false
        workspace.inspectorItem.isCollapsed = false
        let eventsWereVisible = workspace.isEventsVisible
        workspace.setEventsVisible(false)
        controller.showWindow(nil)
        defer {
            workspace.setEventsVisible(eventsWereVisible)
            workspace.setInspectorVisible(inspectorWasVisible)
            controller.close()
        }
        let traffic = workspace.events
        let details = try #require(workspace.inspector.children.first { $0 is ConversationDetailsController })
        #expect(!details.view.isHidden)
        #expect(!workspace.inspector.children.contains { $0 is TrafficViewController })
        let toolbar = try #require(window.toolbar)
        let sidebarToggle = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "sidebar" }?.view as? NSButton)
        let inspectorToggle = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "inspector" }?.view as? NSButton)
        let eventsToggle = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "events" }?.view as? NSButton)
        #expect(eventsToggle.accessibilityLabel() == "Toggle Events")
        #expect(eventsToggle.image != nil)

        for width in [1320.0, 980.0] {
            window.setContentSize(NSSize(width: width, height: 780))
            try await settlePanes(workspace, eventsVisible: false)
            let sidebarFrame = workspace.sidebar.view.convert(workspace.sidebar.view.bounds, to: nil)
            let inspectorFrame = workspace.inspector.view.convert(workspace.inspector.view.bounds, to: nil)
            #expect(sidebarFrame.maxY > window.contentLayoutRect.maxY + 20)
            #expect(inspectorFrame.maxY > window.contentLayoutRect.maxY + 20)
            #expect(sidebarToggle.convert(sidebarToggle.bounds, to: nil).midX < sidebarFrame.maxX)
            #expect(inspectorToggle.convert(inspectorToggle.bounds, to: nil).midX > inspectorFrame.minX)
            try expectReadableConversation(workspace)
            let conversations = try #require(
                descendants(NSTableView.self, in: workspace.sidebar.view).first {
                    $0.accessibilityLabel() == "Conversations"
                })
            let scroll = try #require(conversations.enclosingScrollView)
            #expect(abs(scroll.bounds.width - workspace.sidebar.view.bounds.width) < 1)
            #expect(scroll.convert(scroll.bounds, to: nil).maxY <= window.contentLayoutRect.maxY + 1)
            let inspectorScroll = try #require(descendants(NSScrollView.self, in: details.view).first)
            #expect(inspectorScroll.convert(inspectorScroll.bounds, to: nil).maxY <= window.contentLayoutRect.maxY + 1)
            window.makeFirstResponder(conversations)
            let selectedRow = try #require(
                conversations.rowView(atRow: conversations.selectedRow, makeIfNecessary: true))
            #expect(!selectedRow.isEmphasized)
            let composer = try #require(
                workspace.conversation.children.compactMap { $0 as? ComposerViewController }.first)
            window.makeFirstResponder(composer.editor)
            #expect(!selectedRow.isEmphasized)

            let sidebarWidth = workspace.sidebar.view.bounds.width
            let windowFrame = window.frame
            try activate(eventsToggle)
            try await settlePanes(workspace, eventsVisible: true)
            #expect(workspace.isEventsVisible)
            #expect(eventsToggle.state == .on)
            #expect(abs(workspace.sidebar.view.bounds.width - sidebarWidth) < 1)
            #expect(window.frame == windowFrame)
            let eventsFrame = traffic.view.convert(traffic.view.bounds, to: nil)
            let conversationFrame = workspace.conversation.view.convert(workspace.conversation.view.bounds, to: nil)
            let detailsFrame = workspace.inspector.view.convert(workspace.inspector.view.bounds, to: nil)
            #expect(eventsFrame.minX >= sidebarFrame.maxX)
            #expect(abs(eventsFrame.minX - conversationFrame.minX) < 1)
            #expect(abs(eventsFrame.maxX - detailsFrame.maxX) < 1)
            #expect(eventsFrame.maxY <= conversationFrame.minY + 1)
            #expect(eventsFrame.maxY <= detailsFrame.minY + 1)
            #expect(eventsFrame.height > 150)
            #expect(eventsFrame.minY >= 0)
            try expectReadableConversation(workspace)

            let filters = try #require(
                descendants(NSPopUpButton.self, in: traffic.view).first { $0.accessibilityLabel() == "Filter Events" })
            let received = try #require(filters.menu?.items.first { $0.title == "Received" })
            let filterAction = try #require(received.action)
            #expect(NSApp.sendAction(filterAction, to: received.target, from: received))
            let search = try #require(descendants(SearchField.self, in: traffic.view).first)
            search.stringValue = "protocol"
            search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))

            let eventsWidth = traffic.view.bounds.width
            try activate(inspectorToggle)
            try await settlePanes(workspace, inspectorVisible: false, eventsVisible: true)
            #expect(workspace.inspectorItem.isCollapsed)
            #expect(workspace.isEventsVisible)
            #expect(abs(traffic.view.bounds.width - eventsWidth) < 1)
            #expect(abs(workspace.sidebar.view.bounds.width - sidebarWidth) < 1)
            #expect(window.frame == windowFrame)
            try expectReadableConversation(workspace)
            try activate(inspectorToggle)
            try await settlePanes(workspace, eventsVisible: true)
            #expect(!workspace.inspectorItem.isCollapsed)
            #expect(workspace.isEventsVisible)
            #expect(!details.view.isHidden)
            #expect(abs(workspace.sidebar.view.bounds.width - sidebarWidth) < 1)
            #expect(window.frame == windowFrame)

            let close = try #require(
                descendants(NSButton.self, in: traffic.view).first { $0.accessibilityLabel() == "Close Events" })
            try activate(close)
            try await settlePanes(workspace, eventsVisible: false)
            #expect(!workspace.isEventsVisible)
            #expect(eventsToggle.state == .off)
            #expect(!workspace.inspectorItem.isCollapsed)
            #expect(abs(workspace.sidebar.view.bounds.width - sidebarWidth) < 1)
            #expect(window.frame == windowFrame)
            try activate(eventsToggle)
            try await settlePanes(workspace, eventsVisible: true)
            #expect(workspace.isEventsVisible)
            #expect(eventsToggle.state == .on)
            #expect(workspace.events === traffic)
            #expect(filters.title == "Received")
            #expect(filters.menu?.items.filter { $0.state == .on }.map(\.title) == ["Received"])
            #expect(search.stringValue == "protocol")
            #expect(abs(workspace.sidebar.view.bounds.width - sidebarWidth) < 1)
            #expect(window.frame == windowFrame)
            workspace.setEventsVisible(false)
            try await settlePanes(workspace, eventsVisible: false)

            for _ in 0..<3 {
                try activate(sidebarToggle)
                try await settlePanes(workspace, sidebarVisible: false, eventsVisible: false)
                try expectReadableConversation(workspace)
                #expect(window.frame == windowFrame)
                try activate(sidebarToggle)
                try await settlePanes(workspace, eventsVisible: false)
                try expectReadableConversation(workspace)
                #expect(abs(workspace.sidebar.view.bounds.width - sidebarWidth) < 1)
                #expect(window.frame == windowFrame)
            }
        }
        for item in [workspace.sidebarItem, workspace.inspectorItem] { item.isCollapsed = true }
        try await settlePanes(workspace, sidebarVisible: false, inspectorVisible: false, eventsVisible: false)
        for item in [workspace.sidebarItem, workspace.inspectorItem] { item.isCollapsed = false }
        try await settlePanes(workspace, eventsVisible: false)
        #expect(!workspace.sidebarItem.isCollapsed)
        #expect(!workspace.inspectorItem.isCollapsed)
        #expect(!workspace.isEventsVisible)
        #expect(!details.view.isHidden)
    }

    @Test("Native divider dragging resizes every workspace, diagnostic, and settings pane without resizing its window")
    func dividerDragging() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = WorkspaceWindowController(environment: fixture.environment, showcase: nil)
        let workspace = controller.workspace
        let window = try #require(controller.window)
        let eventsWereVisible = workspace.isEventsVisible
        workspace.sidebarItem.isCollapsed = false
        workspace.inspectorItem.isCollapsed = false
        workspace.eventsItem.isCollapsed = false
        window.setContentSize(NSSize(width: 1320, height: 820))
        controller.showWindow(nil)
        defer {
            workspace.setEventsVisible(eventsWereVisible)
            controller.close()
        }
        try await settlePanes(workspace, eventsVisible: true)

        for width in [280.0, 240.0] {
            try await dragDivider(
                workspace.splitView, to: width, pane: workspace.sidebar.view, expectedThickness: width, in: window)
            try expectReadableConversation(workspace)
        }
        for width in [380.0, 330.0] {
            let split = workspace.content.splitView
            let contentFrame = workspace.conversation.view.convert(workspace.conversation.view.bounds, to: split)
            let position = contentFrame.maxX + workspace.inspector.view.bounds.width - width
            try await dragDivider(
                split, to: position,
                pane: workspace.inspector.view, expectedThickness: width, in: window)
            try expectReadableConversation(workspace)
        }
        for height in [260.0, 340.0] {
            let split = workspace.workbench.splitView
            let contentFrame = workspace.content.view.convert(workspace.content.view.bounds, to: split)
            let position = contentFrame.maxY + workspace.events.view.bounds.height - height
            try await dragDivider(
                split, to: position,
                pane: workspace.events.view, expectedThickness: height, in: window)
            try expectReadableConversation(workspace)
        }
        let eventsSplit = try #require(workspace.events.children.compactMap { $0 as? NSSplitViewController }.first)
        for width in [280.0, 360.0] {
            try await dragDivider(
                eventsSplit.splitView, to: width, pane: eventsSplit.splitViewItems[0].viewController.view,
                expectedThickness: width, in: window)
        }

        let settings = SettingsWindowController(environment: fixture.environment, tab: .connection)
        let settingsWindow = try #require(settings.window)
        settings.showWindow(nil)
        defer { settings.close() }
        let settingsSplit = try #require(settingsWindow.contentViewController as? NSSplitViewController)
        settingsWindow.contentView?.layoutSubtreeIfNeeded()
        for width in [280.0, 220.0] {
            try await dragDivider(
                settingsSplit.splitView, to: width, pane: settingsSplit.splitViewItems[0].viewController.view,
                expectedThickness: width, in: settingsWindow)
        }

        let logs = LogConsoleController(log: fixture.environment.appLog)
        let logWindow = NSWindow(contentViewController: logs)
        logWindow.isReleasedWhenClosed = false
        logWindow.setContentSize(NSSize(width: 1000, height: 700))
        logWindow.orderBack(nil)
        defer {
            logWindow.contentView = nil
            logWindow.close()
        }
        let logSplit = try #require(logs.children.compactMap { $0 as? NSSplitViewController }.first)
        logWindow.contentView?.layoutSubtreeIfNeeded()
        for width in [380.0, 460.0] {
            try await dragDivider(
                logSplit.splitView, to: width, pane: logSplit.splitViewItems[0].viewController.view,
                expectedThickness: width, in: logWindow)
        }
    }

    @Test("The inspector retains basic information and members without exposing unsupported protocol tools")
    func protocolSections() {
        let v12 = ConversationContentCapabilities(
            protocolChoice: .oneBotV12, scene: .group, canInteract: true, role: .owner)
        #expect(
            ConversationInspectorSection.available(capabilities: v12, supportsSettings: false) == [.overview, .members])
        let v11 = ConversationContentCapabilities(
            protocolChoice: .oneBotV11, scene: .group, canInteract: true, role: .owner)
        #expect(
            ConversationInspectorSection.available(capabilities: v11, supportsSettings: true) == [
                .overview, .members, .files, .settings,
            ])
        let temporary = ConversationContentCapabilities(
            protocolChoice: .milky, scene: .temp, canInteract: true, role: nil)
        #expect(
            ConversationInspectorSection.available(capabilities: temporary, supportsSettings: true) == [
                .overview, .settings,
            ])
    }

    @Test("Conversation tools fit the narrow inspector and render with populated light and dark workspaces")
    func renderWorkspace() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        for section in ConversationInspectorSection.allCases {
            try await render(
                ConversationDetailsController(environment: fixture.environment, chat: fixture.chat, section: section),
                size: CGSize(width: 320, height: 680), name: "inspector-" + section.rawValue.lowercased()
            )
        }
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            try await render(
                TrafficViewController(environment: fixture.environment),
                size: CGSize(width: 760, height: 300), name: "events-\(scheme == .aqua ? "light" : "dark")",
                scheme: scheme
            )
        }
        for width in [980.0, 1320.0] {
            for scheme in [NSAppearance.Name.aqua, .darkAqua] {
                for inspectorVisible in [false, true] {
                    for eventsVisible in [false, true] {
                        let workspace = WorkspaceViewController(environment: fixture.environment, showcase: nil)
                        workspace.sidebarItem.isCollapsed = false
                        workspace.inspectorItem.isCollapsed = !inspectorVisible
                        workspace.eventsItem.isCollapsed = !eventsVisible
                        try await render(
                            workspace, size: CGSize(width: width, height: 780),
                            name:
                                "workspace-\(Int(width))-\(scheme == .aqua ? "light" : "dark")-\(inspectorVisible ? "details" : "chat")\(eventsVisible ? "-events" : "")",
                            scheme: scheme, inspectorVisible: inspectorVisible, eventsVisible: eventsVisible
                        )
                        let composer = try #require(
                            workspace.conversation.children.compactMap { $0 as? ComposerViewController }.first)
                        #expect(composer.view.bounds.width <= 821)
                        #expect(
                            abs(composer.view.bounds.width - min(820, workspace.conversation.view.bounds.width - 48))
                                < 1)
                        #expect(composer.view.bounds.height >= 120)
                        #expect(composer.view.bounds.height < 240)
                        let glass = descendants(NSGlassEffectView.self, in: composer.view)
                        #expect(glass.count == 1)
                        let frame = composer.view.convert(composer.view.bounds, to: workspace.conversation.view)
                        #expect(workspace.conversation.view.bounds.contains(frame))
                    }
                }
            }
        }
    }

    private func render(
        _ controller: NSViewController, size: CGSize, name: String, scheme: NSAppearance.Name = .aqua,
        inspectorVisible: Bool? = nil, eventsVisible: Bool? = nil
    )
        async throws
    {
        let window = NSWindow(contentViewController: controller)
        let view = controller.view
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme)
        window.setContentSize(size)
        if let workspace = controller as? WorkspaceViewController, let inspectorVisible {
            workspace.sidebarItem.isCollapsed = false
            workspace.inspectorItem.isCollapsed = !inspectorVisible
            if let eventsVisible { workspace.eventsItem.isCollapsed = !eventsVisible }
        }
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        if let workspace = controller as? WorkspaceViewController, let inspectorVisible {
            #expect(workspace.inspectorItem.isCollapsed == !inspectorVisible)
            if let eventsVisible {
                #expect(workspace.isEventsVisible == eventsVisible)
                if eventsVisible {
                    let eventsFrame = workspace.events.view.convert(workspace.events.view.bounds, to: view)
                    let sidebarFrame = workspace.sidebar.view.convert(workspace.sidebar.view.bounds, to: view)
                    #expect(eventsFrame.minX >= sidebarFrame.maxX)
                    #expect(view.bounds.contains(eventsFrame))
                }
            }
        }
        #expect(abs(view.bounds.width - size.width) < 1, "\(name) must retain its viewport width")
        if controller is TrafficViewController {
            let filters = try #require(
                descendants(NSPopUpButton.self, in: view).first { $0.accessibilityLabel() == "Filter Events" })
            let frame = filters.convert(filters.bounds, to: view)
            #expect(frame.height <= 36)
            #expect(view.bounds.maxY - frame.maxY < 120)
            let menu = try #require(filters.menu)
            #expect(menu.items.map(\.title) == ["All", "Received", "Sent"])
            #expect(menu.items.allSatisfy { !$0.isHidden })
            for item in menu.items {
                let action = try #require(item.action)
                #expect(NSApp.sendAction(action, to: item.target, from: item))
                view.layoutSubtreeIfNeeded()
                #expect(filters.bounds.width < 160)
                #expect(filters.bounds.width >= filters.intrinsicContentSize.width)
                #expect(view.bounds.contains(filters.convert(filters.bounds, to: view)))
                #expect(menu.items.filter { $0.state == .on }.map(\.title) == [item.title])
                #expect(filters.title == (item.tag == 0 ? "Filter" : item.title))
            }
            let reset = try #require(descendants(NSButton.self, in: view).first { $0.title == "Show All" })
            try activate(reset)
            #expect(filters.title == "Filter")
            #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["All"])
        }
        if let details = controller as? ConversationDetailsController,
            let pane = details.children.first as? ConversationContentPane,
            let scroll = pane.view as? NSScrollView,
            let document = scroll.documentView
        {
            #expect(document.isFlipped)
            #expect(abs(scroll.documentVisibleRect.minY) < 1, "Inspector content starts at the top")
        }
        if let path = ProcessInfo.processInfo.environment["REI_WORKSPACE_PREVIEW_DIRECTORY"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try nativeViewSnapshot(view)
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    private func dragDivider(
        _ split: NSSplitView, to position: CGFloat, pane: NSView, expectedThickness: CGFloat, in window: NSWindow
    ) async throws {
        let frame = window.frame
        split.setPosition(position, ofDividerAt: 0)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var actualThickness: CGFloat = 0
        while clock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            actualThickness = split.isVertical ? pane.bounds.width : pane.bounds.height
            if abs(actualThickness - expectedThickness) < 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            abs(actualThickness - expectedThickness) < 1,
            "Dragging must reach the requested pane thickness of \(expectedThickness); reached \(actualThickness)")
        #expect(window.frame == frame, "Dragging a divider must resize the panes inside the existing window")
    }

    private func expectReadableConversation(_ workspace: WorkspaceViewController) throws {
        let viewport = workspace.view.convert(workspace.view.bounds, to: nil)
        let leading =
            workspace.sidebarItem.isCollapsed
            ? viewport.minX : workspace.sidebar.view.convert(workspace.sidebar.view.bounds, to: nil).maxX
        let trailing =
            workspace.inspectorItem.isCollapsed
            ? viewport.maxX : workspace.inspector.view.convert(workspace.inspector.view.bounds, to: nil).minX
        let conversation = workspace.conversation
        let transcript = try #require(conversation.children.compactMap { $0 as? TranscriptController }.first)
        let composer = try #require(conversation.children.compactMap { $0 as? ComposerViewController }.first)
        for content in [conversation.view, transcript.scrollView.contentView, composer.view] {
            let frame = content.convert(content.bounds, to: nil)
            #expect(frame.minX >= leading - 1, "Conversation content must remain clear of the sidebar")
            #expect(frame.maxX <= trailing + 1, "Conversation content must remain clear of the inspector")
            #expect(frame.width > 300, "Pane changes must retain a usable conversation width")
        }
        let composerFrame = composer.view.convert(composer.view.bounds, to: nil)
        let transcriptFrame = transcript.scrollView.contentView.convert(
            transcript.scrollView.contentView.bounds, to: nil)
        #expect(transcriptFrame.contains(composerFrame), "The full transcript viewport remains behind the composer")
    }

    private func settlePanes(
        _ workspace: WorkspaceViewController, sidebarVisible: Bool = true, inspectorVisible: Bool = true,
        eventsVisible: Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var previousFrames: [NSRect] = []
        var stableSince = clock.now
        var settled = false
        try await Task.sleep(for: .milliseconds(250))
        while clock.now < deadline {
            workspace.view.window?.contentView?.layoutSubtreeIfNeeded()
            let viewport = workspace.view.convert(workspace.view.bounds, to: nil)
            var panes = [workspace.conversation.view]
            if sidebarVisible { panes.append(workspace.sidebar.view) }
            if inspectorVisible { panes.append(workspace.inspector.view) }
            if eventsVisible { panes.append(workspace.events.view) }
            let frames = panes.map { $0.convert($0.bounds, to: nil) }
            let visibilityMatches =
                workspace.sidebarItem.isCollapsed == !sidebarVisible
                && workspace.inspectorItem.isCollapsed == !inspectorVisible
                && workspace.isEventsVisible == eventsVisible
            let framesFit = frames.allSatisfy { !$0.isEmpty && $0.minY >= 0 && viewport.contains($0) }
            if visibilityMatches && framesFit && frames == previousFrames {
                if stableSince.duration(to: clock.now) >= .milliseconds(60) {
                    settled = true
                    break
                }
            } else {
                stableSince = clock.now
            }
            previousFrames = frames
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(settled, "Workspace panes did not settle inside the window within 2 seconds: \(previousFrames)")
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let defaultsName: String
        let defaults: UserDefaults
        let environment: AppEnvironment
        let chat = Chat(scene: .group, peerID: "80123456", selfID: "10001")

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Rei-Workspace-\(UUID().uuidString)")
            let store = try ReiStore()
            let users = [
                User(id: "10001", name: "Rei Bot"), User(id: "10002", name: "Akashina"),
                User(id: "10003", name: "Alex Chen"),
            ]
            for user in users { try await store.save(user) }
            try await store.save(Group(id: chat.peerID, name: "Rei · Client Development"))
            for user in users {
                try await store.save(
                    GroupMember(groupID: chat.peerID, userID: user.id, role: user.id == "10002" ? .owner : .member))
            }
            defaultsName = "dev.rei.tests.workspace.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            environment = AppEnvironment(
                store: store, assetStore: try AssetStore(directory: directory.appendingPathComponent("assets")),
                appLog: AppLog(directory: directory.appendingPathComponent("logs"), emitUnifiedLog: false),
                defaults: defaults
            )
            await environment.setBotUser("10001")
            environment.setActiveUser("10002")
            environment.selectedProtocol = .milky
            try await environment.groupMembers(in: chat.peerID)
            let model = ConversationContentModel(environment: environment, chat: chat)
            try await model.postAnnouncement(
                content:
                    "Shared files and highlights are now available beside the conversation. Keep this panel open while you work.",
                image: nil)
            try await model.createFolder(name: "Release Documents")
            let source = directory.appendingPathComponent("Protocol compatibility notes.txt")
            try Data("Release notes".utf8).write(to: source)
            try await model.uploadFile(at: source)
            for (index, text) in [
                "Let's review the conversation layout.",
                "Members, files and announcements now live in the right sidebar.",
                "The chat stays visible while we check the protocol events.",
            ].enumerated() {
                let message = try await environment.platform.sendMessage(
                    scene: .group, peerID: chat.peerID, senderID: users[index].id, selfID: chat.selfID,
                    content: [.text(text)])
                if index == 1 { try await model.setHighlight(message, enabled: true) }
            }
            try await model.setPinned(true)
            environment.selectChat(chat)
        }

        func remove() {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
