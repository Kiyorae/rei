import AppKit

final class SelectionSheetController<Item: Identifiable & Equatable>: NSViewController
where Item.ID: Hashable & Sendable {
    private let heading: String
    private let items: [Item]
    private let describeItem: (Item) -> String
    private let operation: @MainActor (Item) async throws -> Void
    private let search = SearchField("Search")
    private let status = NativeUI.label("", secondary: true)
    private let list: ItemListController<Item>
    private var selectedID: Item.ID?
    private var working = false

    init(
        title: String, items: [Item], description: @escaping (Item) -> String,
        operation: @escaping @MainActor (Item) async throws -> Void
    ) {
        heading = title
        self.items = items
        self.describeItem = description
        self.operation = operation
        list = ItemListController { NativeUI.label(description($0)) }
        selectedID = items.first?.id
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        addChild(list)
        list.view.heightAnchor.constraint(equalToConstant: 300).isActive = true
        list.onSelect = { [weak self] in self?.selectedID = $0?.id }
        search.onChange = { [weak self] query in
            guard let self else { return }
            let filtered = items.filter { query.isEmpty || describeItem($0).localizedCaseInsensitiveContains(query) }
            if !filtered.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id }
            list.update(filtered, selection: selectedID)
        }
        let cancel = ActionButton("Cancel") { [weak self] in self?.dismiss() }
        cancel.keyEquivalent = "\u{1b}"
        let choose = ActionButton("Choose") { [weak self] in self?.choose() }
        choose.keyEquivalent = "\r"
        let column = NativeUI.column([
            NativeUI.label(heading, style: .headline), search, list.view, status,
            NativeUI.row([NativeUI.spacer(), cancel, choose]),
        ])
        column.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36).isActive = true
        }
        view = column
        list.update(items, selection: selectedID)
        preferredContentSize = NSSize(width: 500, height: 450)
    }

    func present(on parent: NSWindow) {
        let panel = NSPanel(contentViewController: self)
        panel.setContentSize(preferredContentSize)
        parent.beginSheet(panel)
    }

    private func choose() {
        guard !working, let item = items.first(where: { $0.id == selectedID }) else { return }
        working = true
        Task { [weak self] in
            guard let self else { return }
            defer { working = false }
            do {
                try await operation(item)
                dismiss()
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    private func dismiss() {
        guard let window = view.window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
