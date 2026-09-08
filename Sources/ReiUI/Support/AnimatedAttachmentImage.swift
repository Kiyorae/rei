import AppKit
import SwiftUI

/// NSImageView owns GIF frame timing and looping. The surrounding SwiftUI button
/// retains preview actions and accessibility; reduced motion presents a still.
struct AnimatedAttachmentImage: NSViewRepresentable {
    let image: NSImage
    let animates: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = image
        view.animates = animates
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
        view.animates = animates
    }

    static func dismantleNSView(_ view: NSImageView, coordinator: ()) {
        view.animates = false
        view.image = nil
    }
}
