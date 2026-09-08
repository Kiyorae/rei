import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ReiCore
import ReiProtocol
import Testing

@testable import ReiLogging
@testable import ReiUI

@Suite("Attachment Presentation")
struct AttachmentPresentationTests {
    @Test("Protocol uploads use their stored bytes regardless of their original source")
    @MainActor
    func attachmentSourceDoesNotChooseTheOpenedResource() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = try AssetStore(directory: directory.appendingPathComponent("assets"))
        let store = try ReiStore()
        let media = MediaService(assetStore: assets, store: store)
        let bytes = Data("the protocol attachment".utf8)
        var asset = try #require(await media.store(data: bytes, name: "message.txt"))
        let defaultsName = "dev.rei.tests.attachments.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let environment = AppEnvironment(
            store: store,
            assetStore: assets,
            appLog: AppLog(directory: directory.appendingPathComponent("logs"), emitUnifiedLog: false),
            defaults: defaults
        )

        for source: Asset.Source in [
            .inline,
            .remote(url: "https://invalid.example/changed.txt"),
            .local(path: "/unavailable/original.txt"),
        ] {
            asset.source = source
            let url = try await environment.attachmentURL(for: asset)
            #expect(url.isFileURL)
            #expect(try Data(contentsOf: url) == bytes)
        }
        asset.id = "missing-asset"
        await #expect(throws: (any Error).self) {
            try await environment.attachmentURL(for: asset)
        }
    }

    @Test("Attachment names cannot escape the preview directory and saved bytes are unchanged")
    func namedPreviewAndExport() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("cached-by-hash")
        let bytes = Data([0, 255, 13, 10, 128])
        try bytes.write(to: source)
        let asset = Asset(id: "hash", name: "../../unsafe/report.pdf", source: .inline)
        let preview = try await AttachmentFiles.previewCopy(of: asset, from: source)
        defer { try? FileManager.default.removeItem(at: preview.deletingLastPathComponent()) }
        #expect(preview.lastPathComponent == "report.pdf")
        #expect(try Data(contentsOf: preview) == bytes)
        #expect(AttachmentFiles.fileName(for: Asset(id: "hash", name: "..", source: .inline)) == "Attachment")
        #expect(
            AttachmentFiles.fileName(for: Asset(id: "hash", name: "C:\\folder\\name.txt", source: .inline))
                == "name.txt")

        let destination = directory.appendingPathComponent("saved.pdf")
        try Data("old file".utf8).write(to: destination)
        try await AttachmentFiles.save(from: source, to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test("Inline voice bytes load with their actual duration and support seeking")
    @MainActor
    func voicePlayback() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("voice-without-extension")
        try Self.waveFixture().write(to: source)
        let player = try await AttachmentPlayback.load(from: source, mimeType: "audio/wav")
        let item = try #require(player.currentItem)
        let duration = try await item.asset.load(.duration)
        #expect(abs(duration.seconds - 1) < 0.01)
        let completed = await player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 8_000))
        #expect(completed)
        #expect(abs(player.currentTime().seconds - 0.5) < 0.05)
        player.pause()
    }

    @Test("Corrupt media reports failure instead of presenting a nonfunctional player")
    @MainActor
    func corruptMedia() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("broken.mp4")
        try Data("not a media file".utf8).write(to: source)
        await #expect(throws: (any Error).self) {
            try await AttachmentPlayback.load(from: source)
        }
    }

    @Test("Protocol image bytes are sampled to a bounded thumbnail")
    func imageThumbnail() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try #require(
            CGContext(
                data: nil, width: 960, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 720))
        let image = try #require(context.makeImage())
        let url = directory.appendingPathComponent("image-without-extension")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let thumbnail = try await AttachmentImages.thumbnail(at: url)
        #expect(thumbnail.width == 480)
        #expect(thumbnail.height == 360)
    }

    @Test("Forwarded quotes resolve inside their bundle and cannot read conversation history")
    func forwardedQuoteScope() {
        let chat = Chat(scene: .group, peerID: "group", selfID: "bot")
        let foreignMessage = Message(
            id: "same-id", scene: .group, peerID: "other-group", senderID: "secret-user", selfID: "bot",
            content: [.text("private history")], direction: .incoming
        )
        #expect(MessageReferenceContext.conversation(chat).preview(for: "same-id", message: foreignMessage) == nil)
        #expect(MessageReferenceContext.forwarded([]).preview(for: "same-id", message: foreignMessage) == nil)
        let node = MessageSegment.ForwardNode(
            id: "same-id", senderID: "sender", senderName: "Original Sender", content: [.text("forwarded content")]
        )
        let preview = MessageReferenceContext.forwarded([node]).preview(for: "same-id", message: foreignMessage)
        #expect(preview?.senderName == "Original Sender")
        #expect(preview?.text == "forwarded content")
        #expect(MessageReferenceContext.forwarded([node]).conversation == nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Rei-Attachments-\(UUID().uuidString)")
    }

    private static func waveFixture() -> Data {
        let sampleCount = 8_000
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        text("RIFF")
        integer(UInt32(36 + sampleCount * 2))
        text("WAVEfmt ")
        integer(UInt32(16))
        integer(UInt16(1))
        integer(UInt16(1))
        integer(UInt32(8_000))
        integer(UInt32(16_000))
        integer(UInt16(2))
        integer(UInt16(16))
        text("data")
        integer(UInt32(sampleCount * 2))
        data.append(Data(repeating: 0, count: sampleCount * 2))
        return data
    }
}
