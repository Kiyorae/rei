import AppKit
import QuartzCore
import ReiCore

final class MessageBubbleRow: NSView {
    var onSizeChange: (() -> Void)?
    private var presentation: TranscriptRowContent?
    private var renderedContent: [MessageSegment]?
    private var renderedID: Message.ID?
    private var renderedRecalled = false
    private var renderedOutgoing = false
    private let heading = NativeUI.label("", style: .caption1, secondary: true)
    private let reactions = NativeUI.row([])
    private var bubble: NSView?
    private var toolbar: NSStackView?
    private var tracking: NSTrackingArea?
    private var observation: ModelObservation?
    private var reactionMessageID: Message.ID?
    private var displayedReactions: [MessageReaction] = []

    func display(_ presentation: TranscriptRowContent) {
        self.presentation = presentation
        if observation == nil { observation = ModelObservation { [weak self] in self?.refresh() } }
        refresh()
    }

    private func refresh() {
        guard let presentation else { return }
        let message = presentation.message
        let environment = presentation.environment
        let outgoing = message.senderID == environment.activeUserID
        let name = environment.displayName(for: message.senderID, in: presentation.chat)
        let role = message.scene == .group ? environment.role(of: message.senderID, in: message.peerID) : nil
        heading.stringValue =
            name + "  " + message.time.formatted(date: .omitted, time: .shortened)
            + (role == .owner ? "  Owner" : role == .admin ? "  Admin" : "")
        if renderedID != message.id || renderedContent != message.content || renderedRecalled != message.isRecalled
            || renderedOutgoing != outgoing
        {
            renderedID = message.id
            renderedContent = message.content
            renderedRecalled = message.isRecalled
            renderedOutgoing = outgoing
            rebuild(presentation, name: name, outgoing: outgoing)
        }
        let reactionButtons: [NSView] =
            environment.supportsReactions(in: presentation.chat) && !message.isRecalled
            ? message.reactions.map { item in
                let selected = environment.activeUserID.map(item.userIDs.contains) ?? false
                let button = ActionButton("\(ReactionChoice.label(for: item.reaction)) \(item.userIDs.count)") {
                    Task { await environment.setReaction(item.reaction, on: message, added: !selected) }
                }
                button.bezelStyle = .inline
                button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
                button.isEnabled = environment.canInteract(in: presentation.chat)
                button.toolTip = item.userIDs.sorted().map { environment.displayName(for: $0, in: presentation.chat) }
                    .joined(separator: ", ")
                return button
            } : []
        NativeUI.replace(reactions, with: reactionButtons)
        reactions.isHidden = reactionButtons.isEmpty
        if reactionMessageID == message.id, displayedReactions != message.reactions,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        {
            reactions.wantsLayer = true
            let transition = CATransition()
            transition.type = .push
            transition.subtype = .fromTop
            transition.duration = 0.18
            reactions.layer?.add(transition, forKey: "reactionCount")
        }
        reactionMessageID = message.id
        displayedReactions = message.reactions
        menu = actions(for: presentation)
    }

    private func rebuild(_ presentation: TranscriptRowContent, name: String, outgoing: Bool) {
        for view in subviews { view.removeFromSuperview() }
        let message = presentation.message
        let environment = presentation.environment
        let content: NSView
        if message.isRecalled {
            content = NativeUI.label(
                "Message recalled by "
                    + environment.displayName(for: message.recalledBy ?? message.senderID, in: presentation.chat),
                style: .callout, secondary: true)
        } else {
            let segments = MessageSegmentsContentView(
                message.content, environment: environment, chat: presentation.chat, reveal: presentation.reveal)
            segments.onSizeChange = { [weak self] in self?.onSizeChange?() }
            content = segments
        }
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 16
        self.bubble = bubble
        updateBubbleColor()
        NativeUI.embed(content, in: bubble, inset: 12)
        heading.font = .systemFont(ofSize: 11)
        let column = NativeUI.column([heading, bubble, reactions], spacing: 5)
        column.widthAnchor.constraint(lessThanOrEqualToConstant: 640).isActive = true
        bubble.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        let avatar = AvatarImageView(name: name, path: environment.users.first { $0.id == message.senderID }?.avatar)
        let spacer = NativeUI.spacer()
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        let row = NativeUI.row(outgoing ? [spacer, column, avatar] : [avatar, column, spacer])
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let readingWidth = row.widthAnchor.constraint(equalTo: widthAnchor, constant: -48)
        readingWidth.priority = .init(450)
        NSLayoutConstraint.activate([
            readingWidth,
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            row.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        var buttons: [NSView] = []
        if !message.isRecalled {
            let reply = ActionButton("", symbol: "arrowshape.turn.up.left") { presentation.reply(message) }
            reply.toolTip = "Reply"
            reply.setAccessibilityLabel("Reply")
            reply.isBordered = false
            reply.contentTintColor = .secondaryLabelColor
            reply.isEnabled = environment.canInteract(in: presentation.chat)
            buttons.append(reply)
            if environment.supportsReactions(in: presentation.chat) {
                let reaction = ActionButton("", symbol: "face.smiling") { [weak self] in self?.showReactions() }
                reaction.setAccessibilityLabel("Add Reaction")
                reaction.isBordered = false
                reaction.contentTintColor = .secondaryLabelColor
                reaction.isEnabled = environment.canInteract(in: presentation.chat)
                buttons.append(reaction)
            }
        }
        let toolbar = NativeUI.row(buttons, spacing: 3)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.isHidden = true
        addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: row.topAnchor),
            outgoing
                ? toolbar.leadingAnchor.constraint(equalTo: row.leadingAnchor)
                : toolbar.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        self.toolbar = toolbar
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBubbleColor()
    }

    private func updateBubbleColor() {
        bubble?.layer?.backgroundColor =
            (renderedOutgoing
            ? NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.05)).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        toolbar?.isHidden = false
        toolbar?.alphaValue = 0
        NativeUI.animate { toolbar?.animator().alphaValue = 1 }
    }

    override func mouseExited(with event: NSEvent) { toolbar?.isHidden = true }

    private func showReactions() {
        guard let presentation else { return }
        let menu = NSMenu()
        for choice in ReactionChoice.common {
            menu.addItem(
                ActionMenuItem(choice.symbol + " " + choice.name) {
                    Task {
                        await presentation.environment.setReaction(
                            choice.reaction, on: presentation.message, added: true)
                    }
                })
        }
        menu.addItem(
            ActionMenuItem("Other Expression…") { [weak self] in
                guard let self, let window else { return }
                let kind = ChoiceButton(["QQ Face", "Emoji"])
                let identifier = NativeUI.field("Expression ID")
                FormSheetController(
                    title: "Add Reaction",
                    fields: [NativeUI.labeled("Type", kind), NativeUI.labeled("Expression ID", identifier)],
                    submit: "Add"
                ) {
                    let value = identifier.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
                    await presentation.environment.setReaction(
                        Reaction(kind: kind.indexOfSelectedItem == 0 ? .face : .emoji, value: value),
                        on: presentation.message, added: true)
                }.present(on: window)
            })
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
    }

    private func actions(for presentation: TranscriptRowContent) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let message = presentation.message
        let environment = presentation.environment
        let chat = presentation.chat
        if !message.isRecalled {
            let reply = ActionMenuItem("Reply") { presentation.reply(message) }
            reply.isEnabled = environment.canInteract(in: chat)
            menu.addItem(reply)
            if environment.supportsReactions(in: chat) {
                menu.addItem(ActionMenuItem("Add Reaction…") { [weak self] in self?.showReactions() })
            }
            menu.addItem(ActionMenuItem("Copy Text") { NativeUI.copy(message.content.plainText) })
        }
        menu.addItem(ActionMenuItem("Copy Message ID") { NativeUI.copy(message.id) })
        if environment.supportsNudges(in: chat) {
            menu.addItem(
                ActionMenuItem("Nudge Sender") { Task { await environment.nudge(message.senderID, in: chat) } })
        }
        if chat.scene == .group, environment.botUserID == chat.selfID,
            environment.users.contains(where: { $0.id == message.senderID }),
            environment.privateChat(with: message.senderID) != nil
        {
            menu.addItem(ActionMenuItem("Start Conversation") { environment.openPrivateChat(with: message.senderID) })
            if !environment.isFriend(message.senderID) {
                menu.addItem(
                    ActionMenuItem("Add Friend") {
                        Task {
                            do { try await environment.addFriend(message.senderID) } catch {
                                environment.lastError = error.localizedDescription
                            }
                        }
                    })
            }
        }
        if environment.canRecall(message) {
            menu.addItem(.separator())
            menu.addItem(
                ActionMenuItem("Recall Message…") { [weak self] in
                    NativeUI.confirm(
                        "Recall this message?",
                        detail: "The message will be marked as recalled for everyone in this conversation.",
                        button: "Recall Message", on: self?.window
                    ) {
                        Task { await environment.recall(message) }
                    }
                })
        }
        return menu
    }
}
