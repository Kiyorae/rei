import AppKit
import ReiCore

final class MessageSegmentsContentView: NSStackView {
    private let environment: AppEnvironment
    private let chat: Chat
    private let reveal: ((Message.ID) -> Void)?
    var onSizeChange: (() -> Void)?

    init(
        _ segments: [MessageSegment], environment: AppEnvironment, chat: Chat, reveal: ((Message.ID) -> Void)? = nil,
        context: MessageReferenceContext? = nil
    ) {
        self.environment = environment
        self.chat = chat
        self.reveal = reveal
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        for segment in segments {
            let view: NSView
            switch segment {
            case .text(let text):
                let markdown = MarkdownMessageView(source: text)
                markdown.onSizeChange = { [weak self] in self?.onSizeChange?() }
                view = markdown
            case .mention(let id):
                let label = NativeUI.label(id.map { "@" + environment.displayName(for: $0, in: chat) } ?? "@everyone")
                label.textColor = .controlAccentColor
                view = label
            case .face(_, let name): view = NativeUI.label(name.map { "[\($0)]" } ?? "[Emoji]")
            case .image(let asset): view = attachment(asset, kind: .image)
            case .record(let asset, let duration): view = attachment(asset, kind: .audio(duration))
            case .video(let asset): view = attachment(asset, kind: .video)
            case .file(let asset): view = attachment(asset, kind: .file)
            case .reply(let id):
                let quote = MessageQuoteView(
                    id: id, environment: environment, chat: chat, reveal: reveal,
                    context: context ?? .conversation(chat))
                quote.onSizeChange = { [weak self] in self?.onSizeChange?() }
                view = quote
            case .poke: view = NativeUI.label("Poke", secondary: true)
            case .forward(_, let nodes):
                let forward = ForwardMessagesView(nodes: nodes, environment: environment, chat: chat)
                forward.onSizeChange = { [weak self] in self?.onSizeChange?() }
                view = forward
            case .unsupported(let type, _):
                view = NativeUI.label("Unsupported message segment: \(type)", secondary: true)
            }
            addArrangedSubview(view)
            if view is MarkdownMessageView || view is MessageQuoteView {
                view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func attachment(_ asset: Asset, kind: AttachmentContentView.Kind) -> AttachmentContentView {
        let view = AttachmentContentView(asset: asset, environment: environment, kind: kind)
        view.onSizeChange = { [weak self] in self?.onSizeChange?() }
        return view
    }
}

final class MessageQuoteView: NSView, NSGestureRecognizerDelegate {
    var onSizeChange: (() -> Void)?
    private let id: Message.ID
    private let environment: AppEnvironment
    private let chat: Chat
    private let context: MessageReferenceContext
    private let reveal: ((Message.ID) -> Void)?
    private let author = NativeUI.label("Reply", style: .caption1, secondary: true)
    private let previewText = NativeUI.label("Loading message…")
    private let button = ActionButton("", symbol: "arrow.up.right", action: {})
    private let click = NSClickGestureRecognizer()
    private var observation: Task<Void, Never>?

    init(
        id: Message.ID, environment: AppEnvironment, chat: Chat, reveal: ((Message.ID) -> Void)?,
        context: MessageReferenceContext
    ) {
        self.id = id
        self.environment = environment
        self.chat = chat
        self.reveal = reveal
        self.context = context
        super.init(frame: .zero)
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Let a reference widen a short text bubble, while still yielding to pane sizing.
        setContentCompressionResistancePriority(.init(251), for: .horizontal)
        author.font = .systemFont(ofSize: 11, weight: .semibold)
        author.maximumNumberOfLines = 1
        author.lineBreakMode = .byTruncatingTail
        previewText.font = .systemFont(ofSize: 12)
        previewText.textColor = .labelColor
        previewText.maximumNumberOfLines = 2
        previewText.lineBreakMode = .byWordWrapping
        previewText.cell?.truncatesLastVisibleLine = true
        let text = NativeUI.column([author, previewText], spacing: 3)
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [author, previewText] { label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel("Show Referenced Message")
        button.toolTip = "Show referenced message"
        button.isHidden = true
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        button.onAction = { [weak self] in self?.showReferencedMessage() }
        click.target = self
        click.action = #selector(showReferencedMessage)
        click.delegate = self
        click.isEnabled = false
        addGestureRecognizer(click)
        let row = NativeUI.row([text, button], spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 8, left: 18, bottom: 8, right: 10)
        row.detachesHiddenViews = true
        NativeUI.embed(row, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let textWidth = max(author.attributedStringValue.size().width, previewText.attributedStringValue.size().width)
        return NSSize(width: ceil(textWidth + 28 + (button.isHidden ? 0 : 32)), height: NSView.noIntrinsicMetric)
    }

    @objc private func showReferencedMessage() {
        guard click.isEnabled else { return }
        reveal?(id)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent)
        -> Bool
    {
        button.isHidden || !button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if click.isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
        background.fill()
        let marker = NSBezierPath(
            roundedRect: NSRect(x: 8, y: 8, width: 2, height: max(0, bounds.height - 16)), xRadius: 1, yRadius: 1)
        NSColor.secondaryLabelColor.setFill()
        marker.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation?.cancel()
        guard window != nil else {
            observation = nil
            return
        }
        if context.conversation == nil {
            display(nil)
            return
        }
        observation = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in environment.store.observeMessage(id: id) {
                    try Task.checkCancellation()
                    display(message?.chat == chat ? message : nil)
                }
            } catch is CancellationError {
            } catch {
                author.stringValue = "Reply"
                previewText.stringValue = error.localizedDescription
                button.isHidden = true
                click.isEnabled = false
                window?.invalidateCursorRects(for: self)
                toolTip = error.localizedDescription
                invalidateIntrinsicContentSize()
                onSizeChange?()
            }
        }
    }

    private func display(_ message: Message?) {
        let preview = context.preview(for: id, message: message)
        author.stringValue =
            preview.map { $0.senderName ?? environment.displayName(for: $0.senderID, in: chat) } ?? "Reply"
        previewText.stringValue = preview?.text ?? "Message unavailable"
        click.isEnabled = reveal != nil && context.conversation != nil && preview != nil
        button.isHidden = !click.isEnabled
        window?.invalidateCursorRects(for: self)
        toolTip = preview.map { author.stringValue + ": " + $0.text } ?? "Message unavailable"
        invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

final class ForwardMessagesView: NSStackView {
    private let content = NativeUI.column()
    private var expanded = false
    var onSizeChange: (() -> Void)?

    init(nodes: [MessageSegment.ForwardNode], environment: AppEnvironment, chat: Chat) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        let preview = NativeUI.label(
            nodes.prefix(3).map { $0.senderName + ": " + $0.content.textPreview }.joined(separator: "\n"),
            style: .caption1, secondary: true)
        preview.maximumNumberOfLines = 3
        let toggle = ActionButton("Forwarded Messages · \(nodes.count)", symbol: "chevron.right", action: {})
        toggle.setAccessibilityValue("Collapsed")
        toggle.onAction = { [weak self, weak toggle] in
            guard let self else { return }
            expanded.toggle()
            toggle?.image = NSImage(
                systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
            toggle?.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded, content.arrangedSubviews.isEmpty {
                for node in nodes {
                    content.addArrangedSubview(
                        NativeUI.label(
                            node.senderName + " · " + node.time.formatted(date: .abbreviated, time: .shortened),
                            style: .caption1, secondary: true))
                    let segments = MessageSegmentsContentView(
                        node.content, environment: environment, chat: chat, context: .forwarded(nodes))
                    segments.onSizeChange = { [weak self] in self?.onSizeChange?() }
                    content.addArrangedSubview(segments)
                }
                if nodes.isEmpty {
                    content.addArrangedSubview(NativeUI.label("No forwarded messages are available.", secondary: true))
                }
            }
            preview.isHidden = expanded
            content.isHidden = !expanded
            onSizeChange?()
            if expanded {
                content.alphaValue = 0
                NativeUI.animate { self.content.animator().alphaValue = 1 }
            }
        }
        addArrangedSubview(toggle)
        addArrangedSubview(preview)
        content.isHidden = true
        addArrangedSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
