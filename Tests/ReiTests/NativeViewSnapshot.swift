import AppKit
import Testing

@MainActor
func nativeViewSnapshot(_ view: NSView) throws -> Data {
    let cached = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: cached)
    let output = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: cached.pixelsWide, pixelsHigh: cached.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    output.size = cached.size
    let context = try #require(NSGraphicsContext(bitmapImageRep: output))
    let source = NSImage(size: cached.size)
    source.addRepresentation(cached)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: cached.size).fill()
        source.draw(in: NSRect(origin: .zero, size: cached.size))
    }
    return try #require(output.representation(using: .png, properties: [:]))
}
