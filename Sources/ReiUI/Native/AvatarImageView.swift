import AppKit

final class AvatarImageView: NSImageView {
    init(name: String, path: String?, group: Bool = false, size: CGFloat = 28) {
        super.init(frame: .zero)
        image =
            path.flatMap(NSImage.init(contentsOfFile:))
            ?? NSImage(systemSymbolName: group ? "person.3.fill" : "person.fill", accessibilityDescription: nil)
        imageScaling = .scaleProportionallyUpOrDown
        animates = false
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.masksToBounds = true
        setAccessibilityLabel(name)
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
