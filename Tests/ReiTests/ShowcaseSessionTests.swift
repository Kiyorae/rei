import AVFoundation
import AppKit
import ImageIO
import ReiCore
import ReiProtocol
import SwiftUI
import Testing

@testable import ReiLogging
@testable import ReiUI

@Suite("Showcase Mode", .serialized)
@MainActor
struct ShowcaseSessionTests {
    @Test("The demo connects a real local Milky client, measures API RTT, receives events, and closes cleanly")
    func liveConnection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session
        try await session.prepare()
        session.connection.connect()
        do {
            for _ in 0..<150 {
                if session.connection.state == .connected || session.connection.state == .failed { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(session.connection.errorMessage == nil)
            try #require(session.connection.state == .connected)
            #expect(try #require(session.connection.roundTripTime) > .zero)
            guard case .ready(let port) = session.environment.sessionState else {
                Issue.record("The Milky service must report its bound port")
                await session.connection.disconnect()
                return
            }
            #expect(port != 0)
            #expect(session.environment.settings.host == "127.0.0.1")
            #expect(!session.environment.settings.accessToken.isEmpty)
            // Client API timing must not masquerade as a service-wide WebSocket RTT.
            #expect(session.environment.roundTripTimeState == .unsupported)
            try await session.advance()
            // The second step is an operator message; the bot's own first message
            // is intentionally not echoed back to its protocol consumer.
            try await session.advance()
            for _ in 0..<100 {
                if session.connection.receivedEvents > 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(session.connection.receivedEvents > 0)
            #expect(session.environment.traffic.contains { $0.summary.contains("get_login_info") })
        } catch {
            await session.connection.disconnect()
            throw error
        }
        await session.connection.disconnect()
        #expect(!session.connection.isActive)
        #expect(session.connection.state == .idle)
        #expect(session.connection.roundTripTime == nil)
        #expect(session.environment.sessionState == .idle)
    }

    @Test("Demo is opt-in and a full cycle uses exactly two conversations with real platform mutations")
    func cycle() async throws {
        #expect(!ShowcaseSession.requested(in: ["Rei"]))
        #expect(!ShowcaseSession.requested(in: ["Rei", "--demo-other"]))
        #expect(ShowcaseSession.requested(in: ["Rei", "--demo"]))
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session
        try await session.prepare()
        #expect(session.environment.selectedProtocol == .milky)
        #expect(session.environment.botUserID == ShowcaseSession.botID)
        #expect(session.environment.activeUserID == ShowcaseSession.userID)
        for _ in 0..<ShowcaseSession.stepCount { try await session.advance() }
        let group = try await session.environment.store.messages(in: ShowcaseSession.groupChat)
        let direct = try await session.environment.store.messages(in: ShowcaseSession.directChat)
        #expect(
            Set(try await session.environment.store.activeChats(selfID: ShowcaseSession.botID).map(\.chat)) == [
                ShowcaseSession.groupChat, ShowcaseSession.directChat,
            ])
        for messages in [group, direct] {
            #expect(Set(messages.map(\.direction)) == [.incoming, .outgoing])
            #expect(messages.contains { $0.isRecalled })
            #expect(messages.contains { $0.content.replyTarget != nil })
            #expect(
                messages.contains {
                    $0.content.contains {
                        if case .forward(_, let nodes) = $0 { return nodes.count >= 5 }
                        return false
                    }
                })
            #expect(
                messages.contains {
                    $0.content.contains {
                        if case .image(let asset) = $0 { return asset.mimeType == "image/gif" }
                        return false
                    }
                })
            #expect(
                messages.contains {
                    $0.content.contains {
                        if case .record = $0 { return true }
                        return false
                    }
                })
            #expect(
                messages.contains {
                    $0.content.contains {
                        if case .video = $0 { return true }
                        return false
                    }
                })
            #expect(
                messages.contains {
                    $0.content.contains {
                        if case .file = $0 { return true }
                        return false
                    }
                })
        }
        #expect(group.contains { $0.reactions.contains { $0.userIDs.count == 3 } })
        #expect(direct.allSatisfy { $0.reactions.isEmpty })
        #expect(try await session.environment.store.essences(in: ShowcaseSession.groupChat).count == 1)
        #expect(try await session.environment.store.announcements(groupID: ShowcaseSession.groupChat.peerID).count == 1)
        #expect(try await session.environment.store.sharedFiles(in: ShowcaseSession.groupChat).count == 1)
        #expect(try await session.environment.store.profileLikes(userID: ShowcaseSession.botID).first?.count == 1)

        // A replay resets the next conversation without accumulating history or
        // removing the other conversation's messages and shared content.
        try await session.advance()
        #expect(try await session.environment.store.messages(in: ShowcaseSession.groupChat).count == 1)
        #expect(try await session.environment.store.messages(in: ShowcaseSession.directChat).count == direct.count)
    }

    @Test("Browsing another conversation pauses the producer and resume restores the demonstration target")
    func browsing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.session.prepare()
        fixture.session.selectedChatChanged(ShowcaseSession.directChat)
        #expect(!fixture.session.isFollowing)
        #expect(!fixture.session.isPlaying)
        fixture.session.resumeFollowing()
        #expect(fixture.session.isFollowing)
        #expect(fixture.session.environment.selectedChat == fixture.session.currentChat)
    }

    @Test("The supplied artwork has a looping rotation GIF plus playable audio and video")
    func bundledMedia() async throws {
        let gif = try ShowcaseMedia.resource("Akame-Spin", extension: "gif")
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 72)
        let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [String: Any])
        let gifProperties = try #require(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        #expect(gifProperties[kCGImagePropertyGIFLoopCount as String] as? Int == 0)
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rotated = try #require(CGImageSourceCreateImageAtIndex(source, 18, nil))
        #expect(first.width == 480 && first.height == 480)
        #expect(first.dataProvider?.data != rotated.dataProvider?.data)
        for (name, fileExtension) in [("Chime", "wav"), ("Akame-Spin", "mp4")] {
            let asset = AVURLAsset(url: try ShowcaseMedia.resource(name, extension: fileExtension))
            #expect(try await asset.load(.isPlayable))
            #expect(try await asset.load(.duration).seconds >= 4.9)
        }
    }

    @Test("GIF messages animate in a real AppKit image view")
    func inlineAnimation() async throws {
        let gif = try ShowcaseMedia.resource("Akame-Spin", extension: "gif")
        let bytes = try Data(contentsOf: gif)
        let animation = try #require(NSImage(data: bytes))
        let controller = NSHostingController(
            rootView: AnimatedAttachmentImage(image: animation, animates: true).frame(width: 240, height: 240))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        func snapshot() throws -> Data {
            let view = controller.view
            view.layoutSubtreeIfNeeded()
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            return try #require(image.representation(using: .png, properties: [:]))
        }
        try await Task.sleep(for: .milliseconds(150))
        let first = try snapshot()
        try await Task.sleep(for: .milliseconds(350))
        let next = try snapshot()
        #expect(next != first)
    }

    @Test("The demo transcript scrolls as rich messages arrive")
    func followsTranscript() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session
        try await session.prepare()
        session.isPlaying = false
        let controller = NSHostingController(
            rootView: RootView(
                environment: session.environment, selectedSettingsTab: .constant(.connection), showcase: session
            ))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 1320, height: 780))
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<9 { try await session.advance() }
        try await Task.sleep(for: .milliseconds(1600))
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let transcript = try #require(
            scrollViews(in: controller.view).max {
                ($0.documentView?.frame.height ?? 0) - $0.contentSize.height
                    < ($1.documentView?.frame.height ?? 0) - $1.contentSize.height
            })
        #expect(session.isFollowing)
        #expect(transcript.documentVisibleRect.minY > 100)
    }

    @Test("Reselecting the current chat keeps its transcript, revealed message, and live subscription")
    func repeatedSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session
        try await session.prepare()
        try await session.advance()
        let environment = session.environment
        for _ in 0..<100 where environment.messages.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let original = try #require(environment.messages.first)
        #expect(await environment.revealMessage(id: original.id, in: session.currentChat))
        let reveal = environment.messageReveal
        let ids = environment.messages.map(\.id)
        environment.selectChat(session.currentChat)
        #expect(environment.messages.map(\.id) == ids)
        #expect(environment.messageReveal == reveal)
        try await session.advance()
        for _ in 0..<100 where environment.messages.count == ids.count {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(environment.messages.count == ids.count + 1)
        #expect(environment.messages.first?.id == original.id)
    }

    @Test(
        "Appending a message preserves the already visible animated image view",
        .enabled(
            if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Reduced Motion uses a static image instead of an animated NSImageView"
        )
    )
    func preservesVisibleRows() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session
        try await session.prepare()
        session.isPlaying = false
        let controller = NSHostingController(
            rootView: RootView(
                environment: session.environment, selectedSettingsTab: .constant(.connection), showcase: session
            ))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 1320, height: 900))
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        for _ in 0..<4 { try await session.advance() }
        func animatedImage(in view: NSView) -> NSImageView? {
            if let image = view as? NSImageView, image.animates { return image }
            return view.subviews.lazy.compactMap { animatedImage(in: $0) }.first
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while animatedImage(in: controller.view) == nil && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let original = try #require(animatedImage(in: controller.view))
        try await session.advance()
        try await Task.sleep(for: .milliseconds(900))
        let current = try #require(animatedImage(in: controller.view))
        #expect(original === current)
    }

    @Test("A new message does not pull the viewport away from a revealed earlier message")
    func preservesHistoryPosition() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session
        try await session.prepare()
        session.isPlaying = false
        let controller = NSHostingController(
            rootView: RootView(
                environment: session.environment, selectedSettingsTab: .constant(.connection), showcase: session
            ))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 1320, height: 780))
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        for _ in 0..<9 { try await session.advance() }
        try await Task.sleep(for: .milliseconds(900))
        let first = try #require(session.environment.messages.first)
        #expect(await session.environment.revealMessage(id: first.id, in: session.currentChat))
        try await Task.sleep(for: .milliseconds(900))
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let transcript = try #require(
            scrollViews(in: controller.view).max {
                ($0.documentView?.frame.height ?? 0) - $0.contentSize.height
                    < ($1.documentView?.frame.height ?? 0) - $1.contentSize.height
            })
        let offset = transcript.documentVisibleRect.minY
        #expect(!session.isFollowing)
        try await session.environment.platform.sendMessage(
            scene: .group, peerID: session.currentChat.peerID, senderID: ShowcaseSession.botID,
            selfID: ShowcaseSession.botID, content: [.text("This arrival must not displace the message being read.")]
        )
        try await Task.sleep(for: .milliseconds(900))
        #expect(abs(transcript.documentVisibleRect.minY - offset) < 2)
    }

    @MainActor
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Rei-Showcase-Test-\(UUID().uuidString)")
        let session: ShowcaseSession

        init() throws {
            session = try ShowcaseSession(
                appLog: AppLog(directory: directory.appendingPathComponent("logs"), emitUnifiedLog: false),
                cacheDirectory: directory.appendingPathComponent("assets-\(UUID().uuidString)")
            )
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
