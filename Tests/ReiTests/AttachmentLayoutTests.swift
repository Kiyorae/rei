import AppKit
import ReiCore
import SwiftUI
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
        let content = VStack(alignment: .leading, spacing: 18) {
            Text("Media and Forwarded Messages").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 18) {
                MediaSegmentView(asset: voice, environment: environment, duration: 12)
                MediaSegmentView(asset: video, environment: environment, isVideo: true)
            }
            FileSegmentView(asset: file, environment: environment)
            ForwardSegmentView(nodes: nodes, environment: environment, chat: chat)
                .disclosureGroupStyle(ExpandedLayoutStyle())
        }
        .padding(24)
        .frame(width: 750, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content)
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
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

    /// Forces lazy disclosure contents to participate in the rendering check,
    /// including nested bundles and nodes beyond the three-line collapsed summary.
    private struct ExpandedLayoutStyle: DisclosureGroupStyle {
        func makeBody(configuration: Configuration) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                configuration.label
                configuration.content
            }
        }
    }
}
