import AppKit

extension NativeUI {
    static func configureGlassButton(_ button: NSButton) {
        button.bezelStyle = .glass
        button.borderShape = .capsule
    }

    static func glass(_ content: NSView, cornerRadius: CGFloat = 16, inset: CGFloat = 0) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        if inset > 0 {
            let padding = NSView()
            embed(content, in: padding, inset: inset)
            glass.contentView = padding
        } else {
            glass.contentView = content
        }
        return glass
    }

    static func glassButton(_ button: NSButton) -> NSGlassEffectView {
        button.isBordered = false
        if button.title.isEmpty { button.imagePosition = .imageOnly }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        return glass(button, inset: 4)
    }

    static func glassGroup(_ content: NSView, spacing: CGFloat = 8) -> NSGlassEffectContainerView {
        let group = NSGlassEffectContainerView()
        group.spacing = spacing
        group.contentView = content
        return group
    }

}
