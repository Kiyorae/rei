import AppKit

final class AboutViewController: NSViewController {
    private let environment: AppEnvironment
    private var licenseWindow: NSWindowController?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let logo = LogoSpinButton()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        var sections: [NSView] = [
            NativeUI.row([
                logo,
                textColumn([
                    NativeUI.label("Rei for macOS", style: .title2),
                    NativeUI.label("Version \(version) (\(build))", secondary: true),
                    NativeUI.label("AppKit · SwiftData", style: .caption1, secondary: true),
                    NativeUI.label(
                        "A local protocol simulator and conversation workspace for developing and debugging chat bots."),
                ]),
            ]),
            NativeUI.row([
                link("Project Homepage", "https://github.com/Kiyorae/rei"),
                link("AGPL-3.0", "https://www.gnu.org/licenses/agpl-3.0.html"), NativeUI.spacer(),
            ]),
        ]
        if let url = environment.store.fileURL {
            sections.append(
                contentSection(
                    "Local Storage",
                    [
                        NativeUI.row([
                            NativeUI.label("Conversation data", secondary: true), NativeUI.spacer(),
                            ActionButton("Open Data Folder", symbol: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            },
                        ])
                    ]))
        } else {
            sections.append(NativeUI.label("This workspace stores conversations in memory.", secondary: true))
        }
        sections.append(
            contentSection(
                "Protocol Documentation",
                [
                    documentationRow("OneBot V11", "https://11.onebot.dev/"),
                    documentationRow("OneBot V12", "https://12.onebot.dev/"),
                    documentationRow("Milky 1.3", "https://milky.ntqqrev.org/"),
                ]))
        let components = ComponentAcknowledgement.bundled.map { component in
            let license = ActionButton("View License") { [weak self] in self?.showLicense(component) }
            license.setAccessibilityLabel("View " + component.name + " License")
            return NativeUI.row([
                textColumn(
                    [
                        NativeUI.label(component.title),
                        NativeUI.label(component.purpose, style: .caption1, secondary: true),
                        NativeUI.label(component.license, style: .caption1, secondary: true),
                    ], spacing: 2),
                license,
            ])
        }
        sections.append(contentSection("Components & Licenses", components))
        let column = NativeUI.column(sections)
        column.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36).isActive = true
        }
        view = NativeUI.scroll(column)
    }

    private func link(_ title: String, _ url: String) -> NSView {
        let button = ActionButton(title, symbol: "arrow.up.right") { NSWorkspace.shared.open(URL(string: url)!) }
        button.toolTip = url
        return button
    }

    private func documentationRow(_ title: String, _ url: String) -> NSView {
        let button = link("Open", url)
        button.setAccessibilityLabel("Open " + title + " Documentation")
        return NativeUI.row([NativeUI.label(title), NativeUI.spacer(), button])
    }

    private func contentSection(_ title: String, _ rows: [NSView]) -> NSView {
        let column = NativeUI.column([NativeUI.label(title, style: .headline)] + rows, spacing: 12)
        column.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        for row in rows { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }

    private func textColumn(_ labels: [NSView], spacing: CGFloat = 10) -> NSView {
        let column = NativeUI.column(labels, spacing: spacing)
        column.setContentHuggingPriority(.init(1), for: .horizontal)
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in labels { label.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }

    private func showLicense(_ component: ComponentAcknowledgement) {
        guard component.licenseURL.isFileURL else {
            NSWorkspace.shared.open(component.licenseURL)
            return
        }
        do {
            let text = try String(contentsOf: component.licenseURL, encoding: .utf8)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 560), styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.title = component.title + " · License"
            window.isReleasedWhenClosed = false
            let scroll = NSTextView.scrollableTextView()
            let editor = scroll.documentView as! NSTextView
            editor.string = text
            editor.isEditable = false
            editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            editor.textContainerInset = NSSize(width: 18, height: 18)
            window.contentView = scroll
            window.center()
            licenseWindow = NSWindowController(window: window)
            licenseWindow?.showWindow(nil)
        } catch { NativeUI.error(error, on: view.window) }
    }
}
