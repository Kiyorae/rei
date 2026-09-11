import AppKit
import ReiLogging
import ReiProtocol

final class PayloadTextController: NSViewController {
    private let heading = NativeUI.label("", style: .headline)
    private let scroll = NSTextView.scrollableTextView()
    private var text = ""

    override func loadView() {
        let editor = scroll.documentView as! NSTextView
        editor.isEditable = false
        editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.setAccessibilityLabel("Diagnostic payload")
        let copy = ActionButton("Copy", symbol: "doc.on.doc") { [weak self] in NativeUI.copy(self?.text ?? "") }
        let header = NativeUI.row([heading, NativeUI.spacer(), copy])
        header.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        header.heightAnchor.constraint(equalToConstant: header.fittingSize.height).isActive = true
        let column = NativeUI.column([header, scroll], spacing: 0)
        view = column
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
    }

    func display(title: String, text: String) {
        loadViewIfNeeded()
        heading.stringValue = title
        guard self.text != text else { return }
        self.text = text
        (scroll.documentView as! NSTextView).string = text
    }
}

final class TrafficViewController: NSViewController {
    private enum DirectionFilter: Int, CaseIterable {
        case all, received, sent

        var title: String {
            switch self {
            case .all: "All"
            case .received: "Received"
            case .sent: "Sent"
            }
        }

        func includes(_ entry: TrafficEntry) -> Bool {
            switch self {
            case .all: true
            case .received: entry.direction == .inboundCall
            case .sent: entry.direction != .inboundCall
            }
        }
    }

    private let environment: AppEnvironment
    private let search = SearchField("Search raw events")
    private lazy var filterButton: NSPopUpButton = makeFilterButton()
    private var direction = DirectionFilter.all
    private let list = ItemListController<TrafficEntry> { entry in
        let label = NativeUI.label(entry.summary)
        label.maximumNumberOfLines = 1
        let time = NativeUI.label(
            entry.timestamp.formatted(date: .omitted, time: .standard), style: .caption1, secondary: true)
        if entry.direction == .reply,
            entry.payload["retcode"]?.intValue != nil && entry.payload["retcode"]?.intValue != 0
                || entry.payload["ok"]?.boolValue == false
        {
            label.textColor = .systemRed
        }
        return NativeUI.column([label, time], spacing: 2)
    }
    private let payload = PayloadTextController()
    private let split = NSSplitViewController()
    private var selection: TrafficEntry.ID?
    private var query = ""
    private var clearedBefore: Date?
    private var observation: ModelObservation?
    var onClose: (() -> Void)?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        search.font = .systemFont(ofSize: 12)
        search.onChange = { [weak self] in
            self?.query = $0
            self?.refresh()
        }
        NativeUI.configureGlassButton(filterButton)
        filterButton.controlSize = search.controlSize
        filterButton.font = search.font
        filterButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        filterButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        filterButton.setAccessibilityLabel("Filter Events")
        updateFilter()
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let searchWidth = search.widthAnchor.constraint(equalToConstant: 320)
        searchWidth.priority = .init(489)
        NSLayoutConstraint.activate([
            searchWidth,
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        list.tableView.setAccessibilityLabel("Raw Events")
        list.rowHeight = { _ in 44 }
        list.onSelect = { [weak self] in
            self?.selection = $0?.id
            self?.refresh()
        }
        let clear = ActionButton("", symbol: "eraser") { [weak self] in
            self?.clearedBefore = .now
            self?.selection = nil
            self?.refresh()
        }
        clear.setAccessibilityLabel("Clear View")
        clear.toolTip = "Hide current events; Show All restores them"
        clear.controlSize = search.controlSize
        let reset = ActionButton("Show All") { [weak self] in
            guard let self else { return }
            clearedBefore = nil
            query = ""
            search.stringValue = ""
            direction = .all
            updateFilter()
            refresh()
        }
        reset.controlSize = search.controlSize
        reset.font = search.font
        let close = ActionButton("", symbol: "xmark") { [weak self] in self?.onClose?() }
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        close.contentTintColor = .secondaryLabelColor
        close.setAccessibilityLabel("Close Events")
        close.toolTip = "Close Events"
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: 24),
            close.heightAnchor.constraint(equalToConstant: 24),
        ])
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "events.native.columns"
        let listItem = NSSplitViewItem(viewController: list)
        listItem.minimumThickness = 230
        listItem.holdingPriority = NativeUI.paneHoldingPriority
        listItem.preferredThicknessFraction = 0.4
        let payloadItem = NSSplitViewItem(viewController: payload)
        payloadItem.minimumThickness = 260
        split.addSplitViewItem(listItem)
        split.addSplitViewItem(payloadItem)
        addChild(split)
        let title = NativeUI.label("Raw Events")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = NativeUI.row([title, search, NativeUI.spacer(), filterButton, clear, reset, close], spacing: 8)
        heading.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 12)
        heading.heightAnchor.constraint(
            equalToConstant: max(search.intrinsicContentSize.height, filterButton.intrinsicContentSize.height, 24) + 20
        ).isActive = true
        let column = NativeUI.column([heading, split.view], spacing: 0)
        NativeUI.embed(column, in: view)
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        split.view.setContentHuggingPriority(.init(1), for: .vertical)
        observation = ModelObservation { [weak self] in self?.refresh() }
    }

    private func makeFilterButton() -> NSPopUpButton {
        let menu = NSMenu()
        for choice in DirectionFilter.allCases {
            let item = ActionMenuItem(choice.title) { [weak self] in
                guard let self else { return }
                direction = choice
                updateFilter()
                refresh()
            }
            item.tag = choice.rawValue
            menu.addItem(item)
        }
        return NSPopUpButton(title: "Filter", pullDownMenu: menu)
    }

    private func updateFilter() {
        filterButton.title = direction == .all ? "Filter" : direction.title
        filterButton.toolTip = "Event direction: " + direction.title
        for item in filterButton.menu?.items ?? [] {
            item.state = item.tag == direction.rawValue ? .on : .off
        }
    }

    private func refresh() {
        let entries = environment.traffic.filter {
            (query.isEmpty || $0.summary.localizedCaseInsensitiveContains(query))
                && (clearedBefore == nil || $0.timestamp > clearedBefore!)
                && direction.includes($0)
        }
        if !entries.contains(where: { $0.id == selection }) { selection = nil }
        list.update(entries, selection: selection)
        let selected = entries.first { $0.id == selection }
        payload.display(
            title: selected?.summary ?? "Select an Event",
            text: selected?.payload.prettyText ?? "Raw protocol messages appear here after the bot framework connects.")
    }
}

final class LogConsoleController: NSViewController {
    private let model: LogConsoleModel
    private let search = SearchField("Search logs")
    private let levels = NSPopUpButton(frame: .zero, pullsDown: true)
    private let categories = NSPopUpButton(frame: .zero, pullsDown: true)
    private let list = ItemListController<AppLogRecord> { record in
        let event = NativeUI.label(record.event)
        event.maximumNumberOfLines = 1
        let summary = NativeUI.label(record.renderedMessage, style: .caption1, secondary: true)
        summary.maximumNumberOfLines = 1
        return NativeUI.column([event, summary], spacing: 2)
    }
    private let payload = PayloadTextController()
    private let split = NSSplitViewController()
    private let status = NativeUI.label("", style: .caption1, secondary: true)
    private var selection: AppLogRecord.ID?
    private var query = ""
    private var excludedLevels: Set<String> = []
    private var excludedCategories: Set<String> = []
    private var observation: ModelObservation?
    private var logTask: Task<Void, Never>?

    init(log: AppLog) {
        model = LogConsoleModel(log: log)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { logTask?.cancel() }

    override func loadView() {
        view = NSView()
        for filter in [levels, categories] {
            NativeUI.configureGlassButton(filter)
            filter.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        search.onChange = { [weak self] in
            self?.query = $0
            self?.refresh()
        }
        list.onSelect = { [weak self] in
            self?.selection = $0?.id
            self?.refresh()
        }
        let clear = ActionButton("Clear Logs…", symbol: "trash") { [weak self] in
            guard let self else { return }
            NativeUI.confirm(
                "Clear All Logs?",
                detail: "This deletes saved logs and current records. Exported files are not affected.",
                button: "Clear Logs", on: view.window
            ) { [model] in Task { await model.clear() } }
        }
        let export = ActionButton("Export…", symbol: "square.and.arrow.up") { [weak self] in
            Task { [weak self] in
                guard let self, let url = LogExportPanel.chooseDirectory() else { return }
                await model.export(to: url)
            }
        }
        let copy = ActionButton("Copy Visible Logs") { [weak self] in
            guard let self else { return }
            NativeUI.copy(filtered.map(\.consoleLine).joined(separator: "\n"))
        }
        let reset = ActionButton("Reset Filters") { [weak self] in
            guard let self else { return }
            query = ""
            search.stringValue = ""
            excludedLevels = []
            excludedCategories = []
            refresh()
        }
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "logs.native.columns"
        let listItem = NSSplitViewItem(viewController: list)
        listItem.minimumThickness = 320
        listItem.holdingPriority = NativeUI.paneHoldingPriority
        let detailItem = NSSplitViewItem(viewController: payload)
        detailItem.minimumThickness = 340
        split.addSplitViewItem(listItem)
        split.addSplitViewItem(detailItem)
        addChild(split)
        let heading = NativeUI.row([
            NativeUI.label("Log Console", style: .headline), NativeUI.spacer(), copy, export, clear,
        ])
        heading.heightAnchor.constraint(equalToConstant: heading.fittingSize.height).isActive = true
        let filters = NativeUI.row([levels, categories, reset, NativeUI.spacer()])
        filters.heightAnchor.constraint(equalToConstant: filters.fittingSize.height).isActive = true
        let controls = NativeUI.column([heading, search, filters])
        controls.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for child in controls.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -24).isActive = true
        }
        controls.heightAnchor.constraint(equalToConstant: controls.fittingSize.height).isActive = true
        let footer = NativeUI.row([status])
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        footer.heightAnchor.constraint(equalTo: status.heightAnchor, constant: 16).isActive = true
        let column = NativeUI.column([controls, split.view, footer], spacing: 0)
        NativeUI.embed(column, in: view)
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        split.view.setContentHuggingPriority(.init(1), for: .vertical)
        observation = ModelObservation { [weak self] in self?.refresh() }
        logTask = Task { [model] in await model.observeSnapshots() }
    }

    private var filtered: [AppLogRecord] {
        model.records.filter {
            !excludedLevels.contains($0.levelToken) && !excludedCategories.contains($0.categoryToken)
                && (query.isEmpty || $0.searchText.contains(query.lowercased()))
        }
        .sorted { $0.sequence != $1.sequence ? $0.sequence > $1.sequence : $0.timestamp > $1.timestamp }
    }

    private func refresh() {
        let records = filtered
        if !records.contains(where: { $0.id == selection }) { selection = nil }
        list.update(records, selection: selection)
        let selected = records.first { $0.id == selection }
        payload.display(
            title: selected?.event ?? "Select a Log Record",
            text: selected?.prettyJSON ?? "Structured diagnostic records appear here while the app runs.")
        status.stringValue =
            model.errorMessage ?? model.statusMessage ?? "\(records.count) visible · \(model.records.count) total"
        configureFilter(
            levels, title: "Levels", tokens: Array(Set(model.records.map(\.levelToken))).sorted(),
            excluded: excludedLevels
        ) { [weak self] token in
            guard let self else { return }
            if !excludedLevels.insert(token).inserted { excludedLevels.remove(token) }
            refresh()
        }
        configureFilter(
            categories, title: "Categories", tokens: Array(Set(model.records.map(\.categoryToken))).sorted(),
            excluded: excludedCategories
        ) { [weak self] token in
            guard let self else { return }
            if !excludedCategories.insert(token).inserted { excludedCategories.remove(token) }
            refresh()
        }
    }

    private func configureFilter(
        _ button: NSPopUpButton, title: String, tokens: [String], excluded: Set<String>,
        action: @escaping (String) -> Void
    ) {
        let menu = NSMenu()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        for token in tokens {
            let item = ActionMenuItem(token.capitalized) { action(token) }
            item.state = excluded.contains(token) ? .off : .on
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            ActionMenuItem("Select All") { for token in tokens where excluded.contains(token) { action(token) } })
        menu.addItem(
            ActionMenuItem("Deselect All") { for token in tokens where !excluded.contains(token) { action(token) } })
        button.menu = menu
    }
}
