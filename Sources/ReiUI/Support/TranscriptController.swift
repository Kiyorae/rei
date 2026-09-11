import AppKit
import ReiCore

/// AppKit owns the viewport and reusable rows. Messages are the current display
/// snapshot, and all actions go back through the existing application model.
final class TranscriptController: NSViewController, NSTableViewDelegate {
    let scrollView = TranscriptScrollView()
    let tableView = TranscriptTableView()
    private let documentView = TranscriptDocumentView()
    private let latestButton = NSButton(title: "Jump to Latest", target: nil, action: nil)
    private lazy var latestGlass = NativeUI.glassButton(latestButton)
    private var latestBottom: NSLayoutConstraint?
    private var bottomOverlayHeight: CGFloat = 0
    private let environment: AppEnvironment
    private let chat: Chat
    private let showcase: ShowcaseSession?
    var reply: (Message) -> Void
    var reveal: (Message.ID) -> Void
    private(set) var messages: [Message] = []
    private(set) var followsLatest = true
    private(set) var hasNewMessages = false
    private var hasLoadedSnapshot = false
    private var reduceMotion = false
    private var lastRevealID: UUID?
    private var readingAnchor: (id: Message.ID, offset: CGFloat)?
    private var geometryUpdate: Task<Void, Never>?
    private var updatingGeometry = false
    private var scrollAnimationID: UUID?
    private var dataSource: NSTableViewDiffableDataSource<Int, Message.ID>!
    private var renderedMessages: [Message.ID: Message] = [:]
    private var isApplyingSnapshot = false
    private var pendingUpdate: (messages: [Message], isLoading: Bool, reduceMotion: Bool, reveal: MessageReveal?)?

    init(
        environment: AppEnvironment, chat: Chat, showcase: ShowcaseSession?,
        reply: @escaping (Message) -> Void, reveal: @escaping (Message.ID) -> Void
    ) {
        self.environment = environment
        self.chat = chat
        self.showcase = showcase
        self.reply = reply
        self.reveal = reveal
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = documentView
        scrollView.setAccessibilityLabel("Conversation messages")
        documentView.addSubview(tableView)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = 72
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.delegate = self
        dataSource = NSTableViewDiffableDataSource(tableView: tableView) { [weak self] table, _, _, id in
            guard let self, let message = renderedMessages[id] else { return NSView() }
            let identifier = NSUserInterfaceItemIdentifier("messageCell")
            let cell =
                table.makeView(withIdentifier: identifier, owner: self) as? TranscriptCellView ?? TranscriptCellView()
            cell.identifier = identifier
            cell.onSizeChange = { [weak self, weak cell] in
                guard let self, let cell, let row = dataSource.row(forItemIdentifier: id),
                    tableView.view(atColumn: 0, row: row, makeIfNecessary: false) === cell
                else { return }
                scheduleGeometryUpdate()
            }
            cell.display(content(for: message))
            return cell
        }
        dataSource.defaultRowAnimation = []
        tableView.onSizeChange = { [weak self] in self?.scheduleGeometryUpdate() }
        scrollView.onUserScroll = { [weak self] in self?.userDidScroll() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(userDidScroll), name: NSScrollView.didLiveScrollNotification, object: scrollView
        )
        latestButton.target = self
        latestButton.action = #selector(jumpToLatest)
        latestButton.bezelStyle = .rounded
        latestButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        latestButton.imagePosition = .imageLeading
        latestGlass.isHidden = true
        latestGlass.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        view.addSubview(latestGlass)
        let latestBottom = latestGlass.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        self.latestBottom = latestBottom
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            latestGlass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            latestBottom,
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateGeometry()
    }

    /// Reserve scrollable space for a floating composer while keeping messages
    /// visible underneath its glass surface throughout the full viewport.
    func setBottomOverlayHeight(_ height: CGFloat) {
        let height = max(0, height)
        guard abs(height - bottomOverlayHeight) > 0.5 else { return }
        if !followsLatest { captureAnchor() }
        bottomOverlayHeight = height
        latestBottom?.constant = -height - 16
        updateGeometry()
    }

    func update(messages next: [Message], isLoading: Bool, reduceMotion: Bool, reveal request: MessageReveal?) {
        loadViewIfNeeded()
        guard !isApplyingSnapshot else {
            pendingUpdate = (next, isLoading, reduceMotion, request)
            return
        }
        self.reduceMotion = reduceMotion
        let previous = messages
        let oldIDs = previous.map(\.id)
        let newIDs = next.map(\.id)
        let appended = hasLoadedSnapshot && newIDs.count > oldIDs.count && newIDs.starts(with: oldIDs)
        let shouldFollow = followsLatest && showcase?.isFollowing != false
        if !followsLatest { captureAnchor() }
        messages = next
        let nextByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        // Keep both snapshots available while AppKit reconciles visible rows.
        // The provider receives stable IDs rather than indexing a changing array.
        renderedMessages.merge(nextByID) { _, new in new }
        if oldIDs != newIDs {
            var snapshot = NSDiffableDataSourceSnapshot<Int, Message.ID>()
            snapshot.appendSections([0])
            snapshot.appendItems(newIDs)
            isApplyingSnapshot = true
            dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let retained = Set(messages.map(\.id))
                    renderedMessages = renderedMessages.filter { retained.contains($0.key) }
                    isApplyingSnapshot = false
                    scheduleGeometryUpdate()
                    if let pending = pendingUpdate {
                        pendingUpdate = nil
                        update(
                            messages: pending.messages, isLoading: pending.isLoading,
                            reduceMotion: pending.reduceMotion, reveal: pending.reveal)
                    }
                }
            }
        }
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for message in next where previousByID[message.id] != message {
            guard let row = dataSource.row(forItemIdentifier: message.id) else { continue }
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCellView {
                // Intrinsic sizing updates the existing cell without replacing
                // its selected text, expanded forwards or playing attachments.
                cell.display(content(for: message))
            }
        }
        if !isLoading { hasLoadedSnapshot = true }
        if next.isEmpty {
            followsLatest = true
            hasNewMessages = false
            readingAnchor = nil
        } else if appended && !shouldFollow {
            hasNewMessages = true
        }
        updateGeometry(followTail: !appended || !shouldFollow)
        if appended && shouldFollow {
            scrollToBottom(animated: !reduceMotion)
            for row in max(oldIDs.count, newIDs.count - 8)..<newIDs.count {
                if let rowView = tableView.rowView(atRow: row, makeIfNecessary: true) {
                    rowView.wantsLayer = true
                    TranscriptMotion.animateArrival(
                        rowView, outgoing: next[row].direction == .outgoing, reduceMotion: reduceMotion)
                }
            }
        }
        if let request, request.chat == chat, request.id != lastRevealID,
            let row = next.firstIndex(where: { $0.id == request.messageID })
        {
            lastRevealID = request.id
            followsLatest = false
            showcase?.isFollowing = false
            showcase?.isPlaying = false
            let rect = documentView.convert(tableView.rect(ofRow: row), from: tableView)
            let readableHeight = max(0, scrollView.contentSize.height - bottomOverlayHeight)
            scroll(to: rect.midY - readableHeight / 2, animated: !reduceMotion)
            readingAnchor = (request.messageID, readableHeight / 2 - rect.height / 2)
        }
        latestGlass.isHidden = !hasNewMessages
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func content(for message: Message) -> TranscriptRowContent {
        TranscriptRowContent(message: message, environment: environment, chat: chat, reply: reply, reveal: reveal)
    }

    private func scheduleGeometryUpdate() {
        guard !updatingGeometry, geometryUpdate == nil else { return }
        geometryUpdate = Task { @MainActor [weak self] in
            guard let self else { return }
            geometryUpdate = nil
            updateGeometry()
        }
    }

    private func updateGeometry(followTail: Bool = true) {
        guard isViewLoaded, !updatingGeometry else { return }
        let viewport = scrollView.contentSize
        guard viewport.width > 0, viewport.height > 0 else { return }
        updatingGeometry = true
        defer { updatingGeometry = false }
        // The table is inside a bottom-aligned document, rather than serving as
        // NSScrollView.documentView itself. Its frame must therefore be sized
        // from row geometry even before an obscured window gets a display pass.
        let initialHeight = tableView.numberOfRows > 0 ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY : 0
        tableView.setFrameSize(NSSize(width: viewport.width, height: initialHeight))
        tableView.layoutSubtreeIfNeeded()
        let tableHeight = tableView.numberOfRows > 0 ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY : 0
        tableView.setFrameSize(NSSize(width: viewport.width, height: tableHeight))
        let height = max(viewport.height, tableHeight + 42 + bottomOverlayHeight)
        documentView.setFrameSize(NSSize(width: viewport.width, height: height))
        tableView.setFrameOrigin(NSPoint(x: 0, y: height - tableHeight - 24 - bottomOverlayHeight))
        if view.window?.occlusionState.contains(.visible) != true { scrollAnimationID = nil }
        if followsLatest && showcase?.isFollowing != false, followTail, scrollAnimationID == nil {
            scrollToBottom(animated: false)
        } else if let anchor = readingAnchor, let row = dataSource.row(forItemIdentifier: anchor.id) {
            let rect = documentView.convert(tableView.rect(ofRow: row), from: tableView)
            scroll(to: rect.minY - anchor.offset, animated: false)
        }
    }

    @objc private func userDidScroll() {
        scrollAnimationID = nil
        followsLatest = documentView.bounds.height - scrollView.documentVisibleRect.maxY <= 32
        if followsLatest { hasNewMessages = false }
        showcase?.isFollowing = false
        showcase?.isPlaying = false
        captureAnchor()
        latestGlass.isHidden = !hasNewMessages
    }

    private func captureAnchor() {
        // Resolve newly visible rows before recording a position: an estimated
        // partial row may shrink entirely above the viewport when it is realized.
        let wasUpdating = updatingGeometry
        updatingGeometry = true
        tableView.layoutSubtreeIfNeeded()
        updatingGeometry = wasUpdating
        let visible = tableView.convert(scrollView.documentVisibleRect, from: documentView)
        let range = tableView.rows(in: visible)
        guard range.location != NSNotFound, let id = dataSource.itemIdentifier(forRow: range.location) else { return }
        let rect = documentView.convert(tableView.rect(ofRow: range.location), from: tableView)
        readingAnchor = (id, rect.minY - scrollView.documentVisibleRect.minY)
    }

    @objc func jumpToLatest() {
        followsLatest = true
        hasNewMessages = false
        readingAnchor = nil
        latestGlass.isHidden = true
        scrollToBottom(animated: !reduceMotion)
    }

    private func scrollToBottom(animated: Bool) {
        scroll(to: documentView.bounds.height - scrollView.contentSize.height, animated: animated)
    }

    private func scroll(to offset: CGFloat, animated: Bool) {
        let y = min(max(0, offset), max(0, documentView.bounds.height - scrollView.contentSize.height))
        let origin = NSPoint(x: 0, y: y)
        guard abs(scrollView.contentView.bounds.origin.y - y) > 0.5 else { return }
        if animated, view.window?.occlusionState.contains(.visible) == true {
            let animationID = UUID()
            scrollAnimationID = animationID
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                scrollView.contentView.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, scrollAnimationID == animationID else { return }
                    scrollAnimationID = nil
                    updateGeometry()
                }
            }
        } else {
            scrollAnimationID = nil
            scrollView.contentView.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
