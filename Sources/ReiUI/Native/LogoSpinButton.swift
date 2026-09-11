import AppKit
import QuartzCore

/// Five clicks reveal the original three-turn spin without moving the button's hit area.
final class LogoSpinButton: NSButton {
    private let artwork = CALayer()
    private var clicks = 0

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel("Rei Logo")
        target = self
        action = #selector(activateLogo)
        wantsLayer = true
        let image = Bundle.module.url(forResource: "Akame", withExtension: "png", subdirectory: "Showcase").flatMap {
            NSImage(contentsOf: $0)
        }
        artwork.name = "logoArtwork"
        artwork.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        artwork.contentsGravity = .resizeAspectFill
        artwork.masksToBounds = true
        layer?.addSublayer(artwork)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 72),
            heightAnchor.constraint(equalToConstant: 72),
        ])
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.bounds = NSRect(origin: .zero, size: bounds.size)
        artwork.position = NSPoint(x: bounds.midX, y: bounds.midY)
        artwork.cornerRadius = min(bounds.width, bounds.height) / 2
        artwork.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(reset), name: NSWindow.willCloseNotification, object: window)
        } else {
            reset()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        reset()
    }

    @objc private func activateLogo() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            artwork.animation(forKey: "logoSpin") == nil
        else { return }
        clicks += 1
        guard clicks == 5 else { return }
        clicks = 0

        let turns = CABasicAnimation(keyPath: "transform.rotation.z")
        turns.fromValue = 0
        turns.toValue = -Double.pi * 4
        turns.duration = 1.8
        turns.timingFunction = CAMediaTimingFunction(name: .linear)

        let finish = CASpringAnimation(perceptualDuration: 0.4, bounce: 0.5)
        finish.keyPath = "transform.rotation.z"
        finish.fromValue = -Double.pi * 4
        finish.toValue = -Double.pi * 6
        finish.beginTime = turns.duration
        finish.duration = 0.7
        finish.initialVelocity = 2 / turns.duration

        let spin = CAAnimationGroup()
        spin.animations = [turns, finish]
        spin.duration = turns.duration + finish.duration
        artwork.add(spin, forKey: "logoSpin")
    }

    @objc private func accessibilityChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { reset() }
    }

    @objc private func reset() {
        clicks = 0
        artwork.removeAnimation(forKey: "logoSpin")
    }
}
