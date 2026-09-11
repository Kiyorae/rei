import AppKit
import Observation
import QuartzCore
import ReiCore

@Observable
@MainActor
final class ComposerSession {
    let key: ComposerDraftKey
    var draft = ComposerDraft()
    init(key: ComposerDraftKey) { self.key = key }
}

final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !hasMarkedText() {
            let placeholder = NSAttributedString(
                string: "Write a message…",
                attributes: [
                    .font: font ?? NSFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: NSColor.placeholderTextColor,
                ])
            placeholder.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height))
        }
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).intersection([
            .command, .control, .option, .shift,
        ])
        if modifiers == [.shift] {
            insertNewline(self)
        } else if modifiers.isEmpty {
            onSubmit?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class ComposerDropView: NSView {
    var onDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls =
            sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        return onDrop?(urls) ?? false
    }
}

final class ComposerViewController: NSViewController, NSTextViewDelegate {
    let session: ComposerSession
    let editor = ComposerTextView()
    var onLayout: (() -> Void)?
    private let environment: AppEnvironment
    private let quoteContainer = NativeUI.column()
    private let attachmentStrip = NativeUI.row([])
    private let attachmentScroller = NSScrollView()
    private let editorScroller = NSScrollView()
    private let status = NativeUI.label("", style: .caption1, secondary: true)
    private lazy var sendButton = ActionButton("", symbol: "arrow.up") { [weak self] in self?.submit() }
    private lazy var attachButton = ActionButton("", symbol: "plus") { [weak self] in self?.chooseFiles() }
    private lazy var mentionButton = ActionButton("", symbol: "at") { [weak self] in self?.chooseMention() }
    private var editorHeight: NSLayoutConstraint?
    private var observation: ModelObservation?
    private var displayedReply: Message.ID?
    private var displayedMentions: [MentionTarget] = []
    private var displayedAttachments: [Asset.ID] = []
    private var lastFocusRequest: UUID?

    init(environment: AppEnvironment, session: ComposerSession) {
        self.environment = environment
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let drop = ComposerDropView()
        drop.onDrop = { [weak self] urls in self?.attach(urls) ?? false }
        view = drop
        let contents = NativeUI.column(spacing: 8)
        contents.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        let glass = NativeUI.glass(contents, cornerRadius: 24)
        NativeUI.embed(glass, in: view)
        editor.delegate = self
        editor.onSubmit = { [weak self] in self?.submit() }
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Message")
        editorScroller.drawsBackground = false
        editorScroller.hasVerticalScroller = true
        editorScroller.autohidesScrollers = true
        editorScroller.documentView = editor
        editorHeight = editorScroller.heightAnchor.constraint(equalToConstant: 64)
        // Let the editor scroll within a shorter composer when another pane
        // leaves little vertical space, while keeping its actions accessible.
        editorHeight?.priority = .init(450)
        editorHeight?.isActive = true
        editorScroller.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        attachButton.setAccessibilityLabel("Attach Files")
        attachButton.toolTip = "Attach files or drag them into your message"
        mentionButton.setAccessibilityLabel("Mention Group Member")
        mentionButton.toolTip = "Mention a group member"
        mentionButton.isHidden = session.key.chat.scene != .group
        for button in [attachButton, mentionButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            button.contentTintColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28),
            ])
        }
        sendButton.setAccessibilityLabel("Send")
        sendButton.toolTip = "Send with Return; insert a line break with Shift-Return"
        sendButton.bezelStyle = .circular
        sendButton.imagePosition = .imageOnly
        sendButton.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        sendButton.controlSize = .large
        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: 34),
            sendButton.heightAnchor.constraint(equalToConstant: 34),
        ])
        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingTail
        let actions = NativeUI.row([attachButton, mentionButton, status, NativeUI.spacer(), sendButton], spacing: 8)
        attachmentScroller.drawsBackground = false
        attachmentScroller.hasHorizontalScroller = true
        attachmentScroller.autohidesScrollers = true
        attachmentScroller.documentView = attachmentStrip
        attachmentScroller.heightAnchor.constraint(equalToConstant: 36).isActive = true
        for child in [quoteContainer, attachmentScroller, editorScroller, actions] {
            contents.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: contents.widthAnchor, constant: -32).isActive = true
        }
        observation = ModelObservation { [weak self] in self?.refresh() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(editor)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateEditorHeight()
        onLayout?()
    }

    func textDidChange(_ notification: Notification) {
        guard !session.draft.isSending else { return }
        session.draft.text = editor.string
        updateEditorHeight()
    }

    private func updateEditorHeight() {
        guard let container = editor.textContainer, let layoutManager = editor.layoutManager,
            editorScroller.contentSize.width > 0
        else { return }
        layoutManager.ensureLayout(for: container)
        let contentHeight = ceil(layoutManager.usedRect(for: container).height + editor.textContainerInset.height * 2)
        let height = min(160, max(64, contentHeight))
        if editorHeight?.constant != height { editorHeight?.constant = height }
    }

    private func refresh() {
        let draft = session.draft
        if !editor.hasMarkedText(), editor.string != draft.text {
            editor.string = draft.text
            editor.setSelectedRange(NSRange(location: (draft.text as NSString).length, length: 0))
        }
        editor.isEditable = !draft.isSending
        sendButton.isEnabled = canSend
        sendButton.contentTintColor = canSend ? .controlAccentColor : .tertiaryLabelColor
        attachButton.isEnabled = !draft.isSending
        mentionButton.isEnabled = !draft.isSending
        status.stringValue =
            draft.isSending
            ? "Sending…" : draft.attachmentImportCount > 0 ? "Importing attachments…" : "Markdown supported"
        updateEditorHeight()
        if let request = draft.focusRequest, request != lastFocusRequest,
            view.window?.makeFirstResponder(editor) == true
        {
            lastFocusRequest = request
        }
        if displayedReply != draft.replyTo {
            displayedReply = draft.replyTo
            var children: [NSView] = []
            if let id = draft.replyTo {
                let quote = MessageQuoteView(
                    id: id, environment: environment, chat: session.key.chat, reveal: nil,
                    context: .conversation(session.key.chat))
                let cancel = ActionButton("", symbol: "xmark.circle.fill") { [weak self] in
                    self?.session.draft.replyTo = nil
                }
                cancel.setAccessibilityLabel("Cancel Reply")
                cancel.isBordered = false
                cancel.contentTintColor = .secondaryLabelColor
                let row = NativeUI.row([quote, cancel])
                children = [row]
            }
            NativeUI.replace(quoteContainer, with: children)
            for child in children { child.widthAnchor.constraint(equalTo: quoteContainer.widthAnchor).isActive = true }
        }
        quoteContainer.isHidden = draft.replyTo == nil
        if displayedMentions != draft.mentions || displayedAttachments != draft.attachments.map(\.id) {
            displayedMentions = draft.mentions
            displayedAttachments = draft.attachments.map(\.id)
            let mentions: [NSView] = draft.mentions.map { mention in
                let name =
                    mention.userID.map { "@" + environment.displayName(for: $0, in: session.key.chat) } ?? "@everyone"
                return attachmentChip(name, symbol: "at") { [weak self] in
                    self?.session.draft.mentions.removeAll { $0 == mention }
                }
            }
            let attachments: [NSView] = draft.attachments.map { asset in
                attachmentChip(asset.name, symbol: "paperclip") { [weak self] in
                    self?.session.draft.attachments.removeAll { $0.id == asset.id }
                }
            }
            NativeUI.replace(attachmentStrip, with: mentions + attachments)
            attachmentStrip.setFrameSize(NSSize(width: attachmentStrip.fittingSize.width, height: 28))
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                attachmentStrip.wantsLayer = true
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.35
                fade.toValue = 1
                fade.duration = 0.18
                attachmentStrip.layer?.add(fade, forKey: "attachments")
            }
        }
        attachmentScroller.isHidden = draft.mentions.isEmpty && draft.attachments.isEmpty
    }

    private func attachmentChip(_ title: String, symbol: String, remove: @escaping () -> Void) -> NSButton {
        let button = ActionButton(title + "  ×", symbol: symbol, action: remove)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        button.lineBreakMode = .byTruncatingMiddle
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        button.toolTip = "Remove " + title
        button.setAccessibilityLabel("Remove " + title)
        return button
    }

    private var validMentions: Set<User.ID> { Set(environment.mentionableUsers(in: session.key.chat).map(\.id)) }
    private var canSend: Bool {
        session.key.senderID != nil && environment.canSubmitMessages && !session.draft.isSending
            && session.draft.attachmentImportCount == 0
            && !session.draft.messageContent(allowedMentionUserIDs: validMentions).isEmpty
    }

    func submit() {
        guard canSend, let sender = session.key.senderID else { return }
        let content = session.draft.messageContent(allowedMentionUserIDs: validMentions)
        let session = session
        session.draft.isSending = true
        Task { [weak self, environment] in
            let sent = await environment.send(content: content, in: session.key.chat, as: sender)
            if sent {
                session.draft = ComposerDraft()
                self?.animateSent()
            } else {
                session.draft.isSending = false
            }
        }
    }

    private func animateSent() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        sendButton.wantsLayer = true
        let bounce = CASpringAnimation(keyPath: "transform.translation.y")
        bounce.fromValue = 6
        bounce.toValue = 0
        bounce.damping = 14
        bounce.stiffness = 280
        bounce.duration = 0.4
        sendButton.layer?.add(bounce, forKey: "sent")
    }

    private func chooseMention() {
        let menu = NSMenu()
        let users = environment.mentionableUsers(in: session.key.chat)
        menu.addItem(ActionMenuItem("@everyone") { [weak self] in self?.session.draft.addMention(userID: nil) })
        for user in users {
            menu.addItem(
                ActionMenuItem(user.displayName) { [weak self] in self?.session.draft.addMention(userID: user.id) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 14, y: 30), in: view)
    }

    private func chooseFiles() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.attach(panel.urls) }
        }
    }

    @discardableResult
    func attach(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, !session.draft.isSending else { return false }
        let session = session
        session.draft.attachmentImportCount += 1
        Task { [environment] in
            defer { session.draft.attachmentImportCount -= 1 }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let asset = await environment.ingestAttachment(at: url),
                    !session.draft.attachments.contains(where: { $0.id == asset.id })
                {
                    session.draft.attachments.append(asset)
                }
            }
        }
        return true
    }
}
