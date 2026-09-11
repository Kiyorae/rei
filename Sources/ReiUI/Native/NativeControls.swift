import AppKit
import Observation
import QuartzCore

@MainActor
final class ModelObservation {
    private let update: () -> Void

    init(_ update: @escaping () -> Void) {
        self.update = update
        refresh()
    }

    private func refresh() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
}

final class ActionButton: NSButton {
    var onAction: (() -> Void)?

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        onAction = action
        super.init(frame: .zero)
        self.title = title
        NativeUI.configureGlassButton(self)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        target = self
        self.action = #selector(invoke)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { onAction?() }
}

final class ActionMenuItem: NSMenuItem {
    private let onAction: () -> Void

    init(_ title: String, key: String = "", action: @escaping () -> Void) {
        onAction = action
        super.init(title: title, action: nil, keyEquivalent: key)
        target = self
        self.action = #selector(invoke)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { onAction() }
}

final class ChoiceButton: NSPopUpButton {
    var onChange: ((Int) -> Void)?

    init(_ titles: [String], selected: Int = 0) {
        super.init(frame: .zero, pullsDown: false)
        NativeUI.configureGlassButton(self)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell?.lineBreakMode = .byTruncatingTail
        addItems(withTitles: titles)
        if titles.indices.contains(selected) { selectItem(at: selected) }
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func changed() { onChange?(indexOfSelectedItem) }
}

final class SearchField: NSSearchField, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?

    init(_ prompt: String) {
        super.init(frame: .zero)
        placeholderString = prompt
        setAccessibilityLabel(prompt)
        sendsSearchStringImmediately = true
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func controlTextDidChange(_ notification: Notification) { onChange?(stringValue) }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

@MainActor
enum NativeUI {
    // Preserve pane sizes ahead of flexible content (250), but yield to native divider dragging (490).
    static let paneHoldingPriority = NSLayoutConstraint.Priority(480)

    static func label(_ value: String, style: NSFont.TextStyle = .body, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = NSFont.preferredFont(forTextStyle: style)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func field(_ placeholder: String, value: String = "") -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func column(_ views: [NSView] = [], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        return stack
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    static func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = self.label(title, secondary: true)
        label.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return row([label, control])
    }

    static func labeled(_ title: String, _ control: NSPopUpButton) -> NSView {
        let row = row([label(title, secondary: true), spacer(), control], spacing: 16)
        control.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.55).isActive = true
        return row
    }

    static func section(_ title: String, _ children: [NSView]) -> NSView {
        let heading = label(title, style: .headline)
        let stack = column([heading] + children)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        return stack
    }

    static func scroll(_ content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = FlippedClipView()
        scroll.contentView.clipsToBounds = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        embed(content, in: document)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    static func embed(_ child: NSView, in parent: NSView, inset: CGFloat = 0, respectingSafeArea: Bool = false) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        let guide = respectingSafeArea ? parent.safeAreaLayoutGuide : nil
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: guide?.leadingAnchor ?? parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: guide?.trailingAnchor ?? parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: guide?.topAnchor ?? parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: guide?.bottomAnchor ?? parent.bottomAnchor, constant: -inset),
        ])
    }

    static func replace(_ stack: NSStackView, with children: [NSView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for child in children { stack.addArrangedSubview(child) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func error(_ error: any Error, on window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func confirm(
        _ title: String, detail: String, button: String, on window: NSWindow?, action: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { action() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    static func animate(_ changes: () -> Void, duration: TimeInterval = 0.22) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            context.allowsImplicitAnimation = true
            changes()
        }
    }
}

final class FormSheetController: NSViewController {
    private let heading: String
    private let fields: [NSView]
    private let submitTitle: String
    private let operation: @MainActor () async throws -> Void
    private let errorLabel = NativeUI.label("", secondary: true)
    private var isSubmitting = false

    init(title: String, fields: [NSView], submit: String, operation: @escaping @MainActor () async throws -> Void) {
        heading = title
        self.fields = fields
        submitTitle = submit
        self.operation = operation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let cancel = ActionButton("Cancel") { [weak self] in self?.dismissSheet() }
        cancel.keyEquivalent = "\u{1b}"
        let submit = ActionButton(submitTitle) { [weak self] in self?.submit() }
        submit.keyEquivalent = "\r"
        let column = NativeUI.column(
            [NativeUI.label(heading, style: .headline)] + fields + [
                errorLabel, NativeUI.row([NativeUI.spacer(), cancel, submit]),
            ])
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for field in fields { field.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true }
        view = column
        preferredContentSize = NSSize(width: 480, height: max(200, column.fittingSize.height))
    }

    func present(on parent: NSWindow) {
        let panel = NSPanel(contentViewController: self)
        panel.setContentSize(preferredContentSize)
        parent.beginSheet(panel)
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { [weak self] in
            guard let self else { return }
            defer { isSubmitting = false }
            do {
                try await operation()
                dismissSheet()
            } catch { errorLabel.stringValue = error.localizedDescription }
        }
    }

    private func dismissSheet() {
        guard let window = view.window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
