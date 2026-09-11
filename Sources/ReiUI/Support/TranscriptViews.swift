import AppKit
import QuartzCore
import ReiCore

final class TranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        contentView.layer?.removeAllAnimations()
        super.scrollWheel(with: event)
        onUserScroll?()
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        onUserScroll?()
    }
}

final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class TranscriptTableView: NSTableView {
    var onSizeChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { onSizeChange?() }
    }
}

struct TranscriptRowContent {
    let message: Message
    let environment: AppEnvironment
    let chat: Chat
    let reply: (Message) -> Void
    let reveal: (Message.ID) -> Void
}

final class TranscriptCellView: NSTableCellView {
    private let messageView = MessageBubbleRow()
    var onSizeChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NativeUI.embed(messageView, in: self)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        messageView.onSizeChange = { [weak self] in
            self?.invalidateIntrinsicContentSize()
            self?.onSizeChange?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: messageView.fittingSize.height)
    }

    func display(_ content: TranscriptRowContent) {
        messageView.display(content)
        invalidateIntrinsicContentSize()
    }
}

@MainActor
enum TranscriptMotion {
    static func animateArrival(_ view: NSView, outgoing: Bool, reduceMotion: Bool) {
        guard !reduceMotion, let layer = view.layer else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = 0.2
        let translation = CASpringAnimation(keyPath: "transform.translation.y")
        translation.fromValue = outgoing ? 28 : 12
        translation.toValue = 0
        translation.damping = 24
        translation.stiffness = 260
        translation.mass = 1
        translation.duration = 0.42
        let group = CAAnimationGroup()
        group.animations = [opacity, translation]
        group.duration = 0.42
        layer.add(group, forKey: "messageArrival")
    }
}
