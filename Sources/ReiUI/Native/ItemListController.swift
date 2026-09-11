import AppKit

/// Reusable AppKit list with identity-based data updates and native selection.
final class ItemListController<Item: Identifiable & Equatable>: NSViewController, NSTableViewDelegate, NSMenuDelegate
where Item.ID: Hashable & Sendable {
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    var onSelect: ((Item?) -> Void)?
    var menuForItem: ((Item) -> NSMenu)?
    var allowsSelection: (Item) -> Bool = { _ in true }
    var rowHeight: (Item) -> CGFloat = { _ in 48 }
    private let makeView: (Item) -> NSView
    private var dataSource: NSTableViewDiffableDataSource<Int, Item.ID>!
    private var items: [Item.ID: Item] = [:]
    private var latestItems: [Item] = []
    private var appliedItems: [Item] = []
    private var latestSelection: Item.ID?
    private var isApplying = false
    private var updateTask: Task<Void, Never>?

    init(makeView: @escaping (Item) -> NSView) {
        self.makeView = makeView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        tableView.headerView = nil
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: .init("content"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.delegate = self
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        dataSource = NSTableViewDiffableDataSource(tableView: tableView) { [weak self] _, _, _, id in
            guard let self, let item = items[id] else { return NSView() }
            return makeView(item)
        }
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        NativeUI.embed(scrollView, in: view)
    }

    func update(_ newItems: [Item], selection: Item.ID? = nil) {
        loadViewIfNeeded()
        latestItems = newItems
        latestSelection = selection
        scheduleSnapshotUpdate()
    }

    private func scheduleSnapshotUpdate() {
        guard !isApplying, updateTask == nil else { return }
        updateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            updateTask = nil
            applyLatestSnapshot()
        }
    }

    private func applyLatestSnapshot() {
        // AppKit must finish reconciling the current snapshot before another
        // changes row identities. Intermediate model updates are coalesced.
        guard !isApplying else { return }
        guard appliedItems != latestItems else {
            select(latestSelection)
            return
        }
        let newItems = latestItems
        items.merge(Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })) { _, new in new }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item.ID>()
        snapshot.appendSections([0])
        snapshot.appendItems(newItems.map(\.id))
        isApplying = true
        // Nonanimated snapshots replace structure and cell contents together.
        // An animated diff can retain stale cells while the same IDs also move.
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                appliedItems = newItems
                let ids = Set(newItems.map(\.id))
                items = items.filter { ids.contains($0.key) }
                isApplying = false
                select(latestSelection)
                scheduleSnapshotUpdate()
            }
        }
    }

    func select(_ id: Item.ID?) {
        let row = id.flatMap { dataSource.row(forItemIdentifier: $0) } ?? -1
        let previous = isApplying
        isApplying = true
        if row >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isApplying = previous
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let id = dataSource.itemIdentifier(forRow: row), let item = items[id] else { return 48 }
        return rowHeight(item)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.style == .sourceList ? SidebarTableRowView() : nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard let id = dataSource.itemIdentifier(forRow: row), let item = items[id] else { return false }
        return allowsSelection(item)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying else { return }
        onSelect?(dataSource.itemIdentifier(forRow: tableView.selectedRow).flatMap { items[$0] })
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard let id = dataSource.itemIdentifier(forRow: row), let item = items[id], let source = menuForItem?(item)
        else { return }
        for entry in source.items {
            source.removeItem(entry)
            menu.addItem(entry)
        }
    }
}
