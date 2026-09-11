import AppKit
import ReiLogging

/// Application lifetime, windows and the menu bar are owned by AppKit.
@MainActor
public final class ReiApplicationDelegate: NSObject, NSApplicationDelegate {
    private let appLog = AppLog.standard
    private var workspace: WorkspaceWindowController?
    private var logWindow: NSWindowController?
    private var startupWindow: NSWindowController?
    private var demoTask: Task<Void, Never>?

    public override init() {
        super.init()
        appLog.record(.applicationStarted)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installMenuBar()
        do {
            let environment: AppEnvironment
            let showcase: ShowcaseSession?
            if ShowcaseSession.requested(in: ProcessInfo.processInfo.arguments) {
                let cache = try FileManager.default.url(
                    for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
                ).appendingPathComponent("Rei/Showcase", isDirectory: true)
                let session = try ShowcaseSession(appLog: appLog, cacheDirectory: cache)
                showcase = session
                environment = session.environment
            } else {
                showcase = nil
                environment = try AppEnvironment.standard(appLog: appLog)
            }
            appLog.record(.environmentLoaded)
            let controller = WorkspaceWindowController(environment: environment, showcase: showcase)
            workspace = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            if let showcase { demoTask = Task { await showcase.run() } }
        } catch {
            appLog.record(.environmentLoadFailed(AppLogFailure(error)))
            showStartupFailure(error)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            workspace?.showWindow(nil)
            startupWindow?.showWindow(nil)
        }
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    public func applicationWillTerminate(_ notification: Notification) { demoTask?.cancel() }

    private func installMenuBar() {
        let bar = NSMenu()
        func add(_ title: String, _ menu: NSMenu) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            bar.addItem(item)
        }
        let application = NSMenu(title: "Rei")
        application.addItem(
            ActionMenuItem("About Rei") { [weak self] in
                if let workspace = self?.workspace {
                    workspace.showSettings(.about)
                } else {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            })
        application.addItem(ActionMenuItem("Settings…", key: ",") { [weak self] in self?.workspace?.showSettings() })
        application.addItem(.separator())
        let services = NSMenu(title: "Services")
        let serviceItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        serviceItem.submenu = services
        application.addItem(serviceItem)
        NSApp.servicesMenu = services
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Rei", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = application.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        application.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit Rei", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add("Rei", application)

        let file = NSMenu(title: "File")
        file.addItem(ActionMenuItem("New Persona…", key: "n") { [weak self] in self?.workspace?.createUser() })
        let group = ActionMenuItem("New Group…", key: "n") { [weak self] in self?.workspace?.createGroup() }
        group.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(group)
        file.addItem(ActionMenuItem("Add Friend…") { [weak self] in self?.workspace?.addFriend() })
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add("File", file)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add("Edit", edit)

        let view = NSMenu(title: "View")
        view.addItem(ActionMenuItem("Toggle Sidebar") { [weak self] in self?.workspace?.workspace.toggleSidebarPane() })
        let inspector = ActionMenuItem("Toggle Inspector", key: "i") { [weak self] in
            self?.workspace?.workspace.toggleInspectorPane()
        }
        inspector.keyEquivalentModifierMask = [.command, .option]
        view.addItem(inspector)
        add("View", view)

        let simulation = NSMenu(title: "Simulation")
        let connection = ActionMenuItem("Connect / Disconnect", key: "k") { [weak self] in
            self?.workspace?.workspace.sidebar.toggleConnection()
        }
        connection.keyEquivalentModifierMask = [.command, .shift]
        simulation.addItem(connection)
        add("Simulation", simulation)

        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(ActionMenuItem("Rei") { [weak self] in self?.workspace?.showWindow(nil) })
        let logs = ActionMenuItem("Log Console", key: "l") { [weak self] in self?.showLogs() }
        logs.keyEquivalentModifierMask = [.command, .option]
        windows.addItem(logs)
        add("Window", windows)
        NSApp.windowsMenu = windows
        let help = NSMenu(title: "Help")
        help.addItem(
            ActionMenuItem("Rei Project Homepage") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Kiyorae/rei")!)
            })
        add("Help", help)
        NSApp.helpMenu = help
        NSApp.mainMenu = bar
    }

    private func showLogs() {
        if logWindow == nil {
            let window = NSWindow(contentViewController: LogConsoleController(log: appLog))
            window.title = "Log Console"
            window.setContentSize(NSSize(width: 1000, height: 680))
            window.minSize = NSSize(width: 780, height: 500)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ReiLogConsole")
            logWindow = NSWindowController(window: window)
        }
        logWindow?.showWindow(nil)
    }

    private func showStartupFailure(_ error: any Error) {
        let diagnostic = error.localizedDescription
        let content = NativeUI.column(
            [
                NativeUI.label("Rei Couldn’t Start", style: .title1),
                NativeUI.label(
                    "The local data or asset directory could not be opened. Check that Application Support is writable, then relaunch Rei."
                ),
                NativeUI.label(diagnostic, secondary: true),
                NativeUI.row([
                    ActionButton("Copy Diagnostic Information") { NativeUI.copy(diagnostic) },
                    ActionButton("Quit") { NSApp.terminate(nil) },
                ]),
            ], spacing: 16)
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 400), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Rei Couldn’t Start"
        window.isReleasedWhenClosed = false
        window.contentView = content
        startupWindow = NSWindowController(window: window)
        startupWindow?.showWindow(nil)
    }
}
