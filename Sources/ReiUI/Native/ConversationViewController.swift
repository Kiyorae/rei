import AppKit
import ReiCore

final class ConversationViewController: NSViewController {
    private let environment: AppEnvironment
    private let showcase: ShowcaseSession?
    private let heading = NativeUI.label("", style: .headline)
    private let detail = NativeUI.label("", style: .caption1, secondary: true)
    private let header = NativeUI.column(spacing: 3)
    private let transcriptContainer = NSView()
    private let emptyState = ConversationEmptyView()
    private var emptyStateBottom: NSLayoutConstraint?
    private var transcript: TranscriptController?
    private var composer: ComposerViewController?
    private var displayedChat: Chat?
    private var hasPresentedConversation = false
    private var sessions: [ComposerDraftKey: ComposerSession] = [:]
    private var observation: ModelObservation?

    init(environment: AppEnvironment, showcase: ShowcaseSession?) {
        self.environment = environment
        self.showcase = showcase
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.maximumNumberOfLines = 1
        detail.font = .systemFont(ofSize: 11)
        detail.maximumNumberOfLines = 1
        header.addArrangedSubview(heading)
        header.addArrangedSubview(detail)
        header.edgeInsets = NSEdgeInsets(top: 10, left: 24, bottom: 12, right: 24)
        for label in [heading, detail] {
            label.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -48).isActive = true
        }
        let column = NativeUI.column([header, transcriptContainer], spacing: 8)
        column.alignment = .centerX
        NativeUI.embed(column, in: view, respectingSafeArea: true)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        transcriptContainer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        transcriptContainer.setContentHuggingPriority(.init(1), for: .vertical)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        transcriptContainer.addSubview(emptyState)
        let emptyBottom = emptyState.bottomAnchor.constraint(equalTo: transcriptContainer.bottomAnchor)
        emptyStateBottom = emptyBottom
        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: transcriptContainer.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: transcriptContainer.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: transcriptContainer.topAnchor),
            emptyBottom,
        ])
        emptyState.onNewConversation = { [weak self] button in self?.showNewConversationMenu(from: button) }
        observation = ModelObservation { [weak self] in self?.refresh() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateComposerClearance()
    }

    private func updateComposerClearance() {
        let height: CGFloat
        if let composer {
            let frame = transcriptContainer.convert(composer.view.bounds, from: composer.view)
            height = max(0, frame.maxY - transcriptContainer.bounds.minY)
        } else {
            height = 0
        }
        transcript?.setBottomOverlayHeight(height)
        if emptyStateBottom?.constant != -height { emptyStateBottom?.constant = -height }
    }

    private func refresh() {
        let chat = environment.selectedChat
        heading.stringValue = chat.map { environment.conversationTitle(for: $0) } ?? ""
        header.isHidden = chat == nil
        if let chat {
            let kind = chat.scene == .group ? "Group conversation" : "Direct conversation"
            detail.stringValue = kind
        }
        if !hasPresentedConversation || displayedChat != chat {
            hasPresentedConversation = true
            displayedChat = chat
            transcript?.view.removeFromSuperview()
            transcript?.removeFromParent()
            transcript = nil
            if let chat {
                let controller = TranscriptController(
                    environment: environment, chat: chat, showcase: showcase,
                    reply: { [weak self] in self?.reply(to: $0, in: chat) },
                    reveal: { [weak environment] id in Task { await environment?.revealMessage(id: id, in: chat) } })
                addChild(controller)
                NativeUI.embed(controller.view, in: transcriptContainer)
                transcript = controller
                let menu = NSMenu()
                menu.addItem(ActionMenuItem("Clear Chat History…") { [weak self] in self?.clearHistory() })
                controller.tableView.menu = menu
            }
        }
        let showsEmptyState = chat == nil || environment.messages.isEmpty
        emptyState.isHidden = !showsEmptyState
        transcript?.view.isHidden = showsEmptyState
        if let chat {
            emptyState.display(
                title: environment.isLoadingMessages
                    ? "Loading conversation…" : "Say hello to \(environment.conversationTitle(for: chat))",
                detail: environment.isLoadingMessages
                    ? "Your messages will appear here." : "Every conversation starts with a message.",
                allowsNewConversation: false)
        } else {
            emptyState.display(
                title: "Where should we start?",
                detail: "Choose a conversation from the sidebar, or start something new.",
                allowsNewConversation: true)
        }
        if let chat {
            let key = ComposerDraftKey(chat: chat, senderID: environment.activeUserID)
            if composer?.session.key != key {
                if let previous = composer?.session, previous.draft.isEmpty {
                    sessions.removeValue(forKey: previous.key)
                }
                composer?.view.removeFromSuperview()
                composer?.removeFromParent()
                let session = sessions[key] ?? ComposerSession(key: key)
                sessions[key] = session
                let controller = ComposerViewController(environment: environment, session: session)
                addChild(controller)
                controller.onLayout = { [weak self] in self?.updateComposerClearance() }
                controller.view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(controller.view)
                let guide = view.safeAreaLayoutGuide
                let width = controller.view.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -48)
                // Fill available space without pushing the panes or the window around.
                width.priority = .init(450)
                NSLayoutConstraint.activate([
                    width,
                    controller.view.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, constant: -48),
                    controller.view.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
                    controller.view.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
                    controller.view.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
                    controller.view.topAnchor.constraint(
                        greaterThanOrEqualTo: transcriptContainer.topAnchor, constant: 64),
                ])
                composer = controller
            }
            transcript?.update(
                messages: environment.messages, isLoading: environment.isLoadingMessages,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                reveal: environment.messageReveal)
        } else {
            composer?.view.removeFromSuperview()
            composer?.removeFromParent()
            composer = nil
        }
        updateComposerClearance()
    }

    private func showNewConversationMenu(from button: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for user in environment.users where environment.privateChat(with: user.id) != nil {
            menu.addItem(
                ActionMenuItem(user.displayName) { [environment] in environment.openPrivateChat(with: user.id) })
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(
            ActionMenuItem("New Persona…") { [weak self] in
                guard let self, let window = view.window else { return }
                PersonaForms.createUser(environment: environment, on: window)
            })
        let group = ActionMenuItem("New Group…") { [weak self] in
            guard let self, let window = view.window else { return }
            PersonaForms.createGroup(environment: environment, on: window)
        }
        group.isEnabled = !environment.users.isEmpty
        menu.addItem(group)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }

    private func reply(to message: Message, in chat: Chat) {
        guard !message.isRecalled, environment.canInteract(in: chat) else { return }
        let key = ComposerDraftKey(chat: chat, senderID: environment.activeUserID)
        let session = sessions[key] ?? ComposerSession(key: key)
        guard !session.draft.isSending else { return }
        sessions[key] = session
        session.draft.replyTo = message.id
        session.draft.focusRequest = UUID()
    }

    func clearHistory() {
        guard let chat = environment.selectedChat else { return }
        NativeUI.confirm(
            "Clear all messages in \(environment.conversationTitle(for: chat))?",
            detail: "This permanently deletes the saved messages. The conversation remains available.",
            button: "Clear Chat History", on: view.window
        ) { [environment, weak self] in
            Task { [environment, weak self] in
                do { try await environment.clearMessageHistory(in: chat) } catch {
                    NativeUI.error(error, on: self?.view.window)
                }
            }
        }
    }
}

private final class ConversationEmptyView: NSView {
    var onNewConversation: ((NSButton) -> Void)?
    private let title = NativeUI.label("")
    private let detail = NativeUI.label("", secondary: true)
    private lazy var newConversation: ActionButton = ActionButton("New Conversation", symbol: "square.and.pencil") {
        [weak self] in
        guard let self else { return }
        onNewConversation?(newConversation)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 44, weight: .light)
        symbol.contentTintColor = .tertiaryLabelColor
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 60),
            symbol.heightAnchor.constraint(equalToConstant: 60),
        ])
        title.font = .systemFont(ofSize: 27, weight: .medium)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 13)
        detail.alignment = .center
        newConversation.controlSize = .large
        let column = NativeUI.column([symbol, title, detail, newConversation], spacing: 16)
        column.alignment = .centerX
        column.setCustomSpacing(24, after: symbol)
        column.setCustomSpacing(24, after: detail)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            column.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            title.widthAnchor.constraint(equalTo: column.widthAnchor),
            detail.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(title: String, detail: String, allowsNewConversation: Bool) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        newConversation.isHidden = !allowsNewConversation
    }
}
