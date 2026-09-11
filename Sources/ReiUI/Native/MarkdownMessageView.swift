import AppKit
import Litext
import MarkdownView

/// A native Markdown document with a single selection range and semantic
/// accessibility content. Its source is never written back into the message.
final class MarkdownMessageView: MarkdownTextView, NSUserInterfaceValidations {
    private(set) var source = ""
    private var measuredWidth: CGFloat = 0
    private var measuredSize = NSSize.zero
    private var preferredSize = NSSize.zero
    var onSizeChange: (() -> Void)?

    init(source: String) {
        super.init()
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        linkHandler = { payload, _, _ in
            let url: URL?
            switch payload {
            case .url(let value): url = value
            case .string(let value): url = URL(string: value)
            }
            if let url, Self.canOpen(url) { NSWorkspace.shared.open(url) }
        }
        update(source: source)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(source: String) {
        guard self.source != source || content.blocks.isEmpty else { return }
        self.source = source
        setAccessibilityLabel(source)
        var theme = MarkdownTheme.default
        theme.fonts.largeTitle = NSFont.preferredFont(forTextStyle: .title1)
        theme.fonts.title = NSFont.preferredFont(forTextStyle: .title2)
        theme.spacings.final = 0
        theme.spacings.paragraph = 8
        theme.spacings.headingBefore = 10
        setContentImmediately(MarkdownContent(markdown: source, theme: theme), theme: theme)
        preferredSize = boundingSize(for: 560)
        var blocks = content.blocks
        while let block = blocks.popLast() {
            switch block {
            case .codeBlock, .table:
                preferredSize.width = 560
                blocks.removeAll()
            default: blocks.append(contentsOf: block.children)
            }
        }
        measuredWidth = 0
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: ceil(preferredSize.width),
            height: measuredWidth > 0 ? measuredSize.height : ceil(preferredSize.height))
    }

    override func layout() {
        guard bounds.width > 0 else {
            super.layout()
            return
        }
        let width = bounds.width
        let size = boundingSize(for: width)
        let changed = measuredWidth != width || abs(size.height - measuredSize.height) > 0.5
        measuredWidth = width
        measuredSize = NSSize(width: min(width, ceil(size.width)), height: ceil(size.height))
        super.layout()
        if changed {
            invalidateIntrinsicContentSize()
            onSizeChange?()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackedScrollView = enclosingScrollView
    }

    private var focusedLabel: TextLabelView? {
        guard let label = window?.firstResponder as? TextLabelView, label.isDescendant(of: self) else { return nil }
        return label
    }

    @objc func copy(_ sender: Any?) { focusedLabel?.copyAction(sender) }

    override func selectAll(_ sender: Any?) { focusedLabel?.selectAll() }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return (focusedLabel?.selectionRange?.length ?? 0) > 0
        case #selector(selectAll(_:)): return (focusedLabel?.attributedText.length ?? 0) > 0
        default: return false
        }
    }

    static func canOpen(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }
}
