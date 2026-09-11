import AppKit
import ReiCore
import Testing

@testable import ReiLogging
@testable import ReiUI

@Suite("Attachment Layout")
@MainActor
struct AttachmentLayoutTests {
    @Test("Attachment cards and nested forward nodes render in a desktop transcript")
    func renderTranscript() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rei-AttachmentLayout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "dev.rei.tests.attachment-layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let environment = AppEnvironment(
            store: try ReiStore(), assetStore: try AssetStore(directory: directory),
            appLog: AppLog(directory: directory.appendingPathComponent("logs"), emitUnifiedLog: false),
            defaults: defaults
        )
        let chat = Chat(scene: .group, peerID: "group", selfID: "bot")
        let voice = Asset(id: "voice", name: "Voice message.silk", mimeType: "audio/silk", source: .inline)
        let video = Asset(id: "video", name: "Screen recording.mp4", mimeType: "video/mp4", source: .inline)
        let file = Asset(id: "file", name: "Protocol notes.pdf", byteCount: 2_048, source: .inline)
        let date = Date(timeIntervalSince1970: 1_783_330_000)
        let nested = MessageSegment.ForwardNode(
            senderID: "carol", senderName: "Carol", time: date,
            content: [.text("Nested forwards retain their full content.")]
        )
        let nodes = [
            MessageSegment.ForwardNode(
                id: "original", senderID: "alice", senderName: "Alice", time: date,
                content: [.text("This forwarded message includes a document."), .file(file)]
            ),
            MessageSegment.ForwardNode(
                senderID: "bob", senderName: "Bob", time: date,
                content: [.reply(messageID: "original"), .text("The reply stays inside this forward bundle.")]
            ),
            MessageSegment.ForwardNode(
                senderID: "carol", senderName: "Carol", time: date,
                content: [.forward(id: "nested", nodes: [nested])]
            ),
            MessageSegment.ForwardNode(
                senderID: "alice", senderName: "Alice", time: date,
                content: [.text("The fourth node remains visible when expanded.")]
            ),
        ]
        let forward = ForwardMessagesView(nodes: nodes, environment: environment, chat: chat)
        func expand(_ view: NSView) throws {
            if let forward = view as? ForwardMessagesView,
                let button = forward.arrangedSubviews.first as? NSButton
            {
                try activate(button)
            }
            for child in view.subviews { try expand(child) }
        }
        try expand(forward)
        let view = NativeUI.column(
            [
                NativeUI.label("Media and Forwarded Messages", style: .title2),
                NativeUI.row([
                    AttachmentContentView(asset: voice, environment: environment, kind: .audio(12)),
                    AttachmentContentView(asset: video, environment: environment, kind: .video),
                ]),
                AttachmentContentView(asset: file, environment: environment, kind: .file),
                forward,
            ], spacing: 18)
        view.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        view.frame = NSRect(x: 0, y: 0, width: 750, height: 900)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        if let output = ProcessInfo.processInfo.environment["REI_MEDIA_PREVIEW_PATH"] {
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output))
        }
    }

}
