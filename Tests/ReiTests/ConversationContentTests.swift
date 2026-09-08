import AppKit
import Foundation
import ReiCore
import ReiProtocol
import SwiftUI
import Testing

@testable import ReiLogging
@testable import ReiUI

@Suite("Conversation Content", .serialized)
@MainActor
struct ConversationContentTests {
    @Test("Milky content tools are gated independently from OneBot V11 file-upload notices")
    func capabilityMatrix() {
        let milky = ConversationContentCapabilities(
            protocolChoice: .milky, scene: .group, canInteract: true, role: .owner)
        #expect(milky.sections == [.overview, .announcements, .files, .essence])
        #expect(milky.canManageGroupContent)
        let member = ConversationContentCapabilities(
            protocolChoice: .milky, scene: .group, canInteract: true, role: .member)
        #expect(member.supportsFiles)
        #expect(!member.canManageGroupContent)
        let v11 = ConversationContentCapabilities(
            protocolChoice: .oneBotV11, scene: .group, canInteract: true, role: .owner)
        #expect(v11.sections == [.files])
        #expect(!v11.canManageGroupContent)
        for scene in [ChatScene.group, .friend, .temp] {
            let v12 = ConversationContentCapabilities(
                protocolChoice: .oneBotV12, scene: scene, canInteract: true, role: .owner)
            #expect(v12.sections.isEmpty)
        }
    }

    @Test("Group file controls complete create, upload, rename, move, download, keep, and delete workflows")
    func fileLifecycle() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.groupModel
        try await model.createFolder(name: "Design")
        var folder = try #require(try await fixture.store.folders(groupID: "group").first)
        try await model.renameFolder(folder, to: "Documents")
        folder = try #require(try await fixture.store.folders(groupID: "group").first)
        #expect(folder.name == "Documents")
        model.selectedFolderID = folder.id
        let source = fixture.directory.appendingPathComponent("notes.txt")
        let bytes = Data("shared document".utf8)
        try bytes.write(to: source)
        try await model.uploadFile(at: source)
        var file = try #require(try await fixture.store.sharedFiles(in: model.chat).first)
        #expect(file.folderID == folder.id)
        #expect(file.uploaderID == "owner")
        let cache = try await fixture.environment.attachmentURL(for: file.asset)
        #expect(try Data(contentsOf: cache) == bytes)
        try await model.renameFile(file, to: "plan.txt")
        file = try #require(try await fixture.store.sharedFile(id: file.id))
        #expect(file.name == "plan.txt")
        try await model.moveFile(file, to: "/")
        file = try #require(try await fixture.store.sharedFile(id: file.id))
        #expect(file.folderID == "/")
        try await model.download(file)
        #expect(try await fixture.store.sharedFile(id: file.id)?.downloadCount == 1)
        file.expiresAt = .now.addingTimeInterval(60)
        try await fixture.store.save(file)
        try await model.keepFile(file)
        #expect(try await fixture.store.sharedFile(id: file.id)?.expiresAt == nil)
        try await model.deleteFile(file)
        #expect(try await fixture.store.sharedFile(id: file.id) == nil)
        try await model.uploadFile(at: source)
        #expect(try await fixture.store.sharedFiles(in: model.chat).count == 1)
        try await model.deleteFolder(folder)
        #expect(try await fixture.store.folders(groupID: "group").isEmpty)
        #expect(try await fixture.store.sharedFiles(in: model.chat).isEmpty)
        #expect(try Data(contentsOf: cache) == bytes)
    }

    @Test("Announcement and highlight actions persist state and cannot escape their conversation")
    func announcementsAndHighlights() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.groupModel
        try await model.postAnnouncement(content: "Release notes", image: nil)
        let announcement = try #require(try await fixture.store.announcements(groupID: "group").first)
        #expect(announcement.content == "Release notes")
        #expect(announcement.senderID == "owner")
        let message = try await fixture.environment.platform.sendMessage(
            scene: .group, peerID: "group", senderID: "member", selfID: "bot", content: [.text("Important message")]
        )
        try await model.setHighlight(message, enabled: true)
        #expect(try await fixture.store.essences(in: model.chat).map(\.messageID) == [message.id])
        var foreign = message
        foreign.selfID = "other-bot"
        await #expect(throws: PlatformError.self) { try await model.setHighlight(foreign, enabled: false) }
        #expect(!(await model.reveal(foreign)))
        try await model.setHighlight(message, enabled: false)
        #expect(try await fixture.store.essences(in: model.chat).isEmpty)
        try await model.deleteAnnouncement(announcement)
        #expect(try await fixture.store.announcements(groupID: "group").isEmpty)
    }

    @Test("Ordinary members can manage their own uploads while protocol and administrator restrictions remain enforced")
    func ownershipAndProtocolChecks() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.groupModel
        let source = fixture.directory.appendingPathComponent("member.txt")
        try Data("file".utf8).write(to: source)
        try await model.uploadFile(at: source)
        let ownerFile = try #require(try await fixture.store.sharedFiles(in: model.chat).first)
        fixture.environment.setActiveUser("member")
        #expect(!model.canEdit(ownerFile))
        await #expect(throws: PlatformError.self) { try await model.renameFile(ownerFile, to: "wrong.txt") }
        await #expect(throws: PlatformError.self) { try await model.createFolder(name: "Forbidden") }
        await #expect(throws: PlatformError.self) { try await model.postAnnouncement(content: "Forbidden", image: nil) }
        try await model.uploadFile(at: source)
        let ownFile = try #require(
            try await fixture.store.sharedFiles(in: model.chat).first(where: { $0.uploaderID == "member" }))
        #expect(model.canEdit(ownFile))
        try await model.renameFile(ownFile, to: "mine.txt")
        fixture.environment.selectedProtocol = .oneBotV11
        #expect(model.capabilities.supportsFiles)
        #expect(!model.canEdit(ownFile))
        await #expect(throws: PlatformError.self) { try await model.deleteFile(ownFile) }
        try await model.uploadFile(at: source)
        fixture.environment.selectedProtocol = .oneBotV12
        await #expect(throws: PlatformError.self) { try await model.uploadFile(at: source) }
    }

    @Test("Private conversation controls persist read, pin, likes, and downloadable file fingerprints")
    func privateControls() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let chat = Chat(scene: .friend, peerID: "owner", selfID: "bot")
        let model = ConversationContentModel(environment: fixture.environment, chat: chat)
        let message = try await fixture.environment.platform.sendMessage(
            scene: .friend, peerID: "owner", senderID: "bot", selfID: "bot", content: [.text("Hello")]
        )
        try await model.setPinned(true)
        try await model.markRead()
        let state = try await fixture.store.conversationState(in: chat)
        #expect(state.isPinned)
        #expect(state.lastReadSequence == message.seq)
        try await model.likeProfile(count: 2)
        #expect(try await fixture.store.profileLikes(userID: "bot").first?.count == 2)
        let source = fixture.directory.appendingPathComponent("private.txt")
        try Data("private document".utf8).write(to: source)
        try await model.uploadFile(at: source)
        let file = try #require(try await fixture.store.sharedFiles(in: chat).first)
        #expect(file.fileHash == (try FileFingerprint.triSHA1(at: source)))
        try await model.download(file)
        #expect(try await fixture.store.sharedFile(id: file.id)?.downloadCount == 1)
        fixture.environment.selectedProtocol = .oneBotV12
        await #expect(throws: PlatformError.self) { try await model.markRead() }
        await #expect(throws: PlatformError.self) { try await model.likeProfile(count: 1) }
    }

    @Test("Open content panels observe changes initiated outside the panel")
    func observesPeerChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.groupModel
        let announcements = Task { await model.observeAnnouncements() }
        let state = Task { await model.observeState() }
        defer {
            announcements.cancel()
            state.cancel()
        }
        try await fixture.environment.platform.postAnnouncement(
            groupID: "group", operatorID: "owner", content: "From peer")
        try await fixture.environment.platform.setPeerPin(in: model.chat, isPinned: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.announcements?.first?.content != "From peer" || !model.state.isPinned {
            guard ContinuousClock.now < deadline else {
                Issue.record("The content observation did not refresh")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Milky temporary conversations expose pin and read controls without friend-only actions")
    func temporaryConversationState() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let chat = Chat(scene: .temp, peerID: "owner", selfID: "bot")
        let model = ConversationContentModel(environment: fixture.environment, chat: chat)
        #expect(model.capabilities.sections == [.overview])
        #expect(model.capabilities.supportsState)
        #expect(!model.capabilities.supportsProfileLikes)
        #expect(!model.capabilities.supportsFiles)
        let message = try await fixture.environment.platform.sendMessage(
            scene: .temp, peerID: "owner", senderID: "bot", selfID: "bot", content: [.text("Temporary conversation")]
        )
        try await model.setPinned(true)
        try await model.markRead()
        let state = try await fixture.store.conversationState(in: chat)
        #expect(state.isPinned)
        #expect(state.lastReadSequence == message.seq)
        let friend = Chat(scene: .friend, peerID: "owner", selfID: "bot")
        #expect(try await fixture.store.conversationState(in: friend).isPinned == false)
        #expect(try await fixture.store.conversationState(in: friend).lastReadSequence == 0)
        await #expect(throws: PlatformError.self) { try await model.likeProfile(count: 1) }
        try await model.setPinned(false)
        #expect(try await fixture.store.conversationState(in: chat).isPinned == false)
    }

    @Test("Announcements, shared files, and highlighted messages render with native desktop controls")
    func renderContentPanels() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.groupModel
        try await model.postAnnouncement(
            content: "Welcome to the group. Please read the project notes before posting.", image: nil)
        try await model.createFolder(name: "Project Documents")
        let source = fixture.directory.appendingPathComponent("Project Notes.txt")
        try Data("Project notes".utf8).write(to: source)
        try await model.uploadFile(at: source)
        let message = try await fixture.environment.platform.sendMessage(
            scene: .group, peerID: "group", senderID: "member", selfID: "bot",
            content: [.text("The latest project notes are ready for review.")]
        )
        try await model.setHighlight(message, enabled: true)
        model.announcements = try await fixture.store.announcements(groupID: "group")
        model.files = try await fixture.store.sharedFiles(in: model.chat)
        model.folders = try await fixture.store.folders(groupID: "group")
        model.highlightedMessages = [message]
        let panels = [
            ("announcements", AnyView(ConversationAnnouncementsView(model: model))),
            ("files", AnyView(ConversationFilesView(model: model))),
            ("highlights", AnyView(ConversationHighlightsView(model: model, didReveal: {}))),
        ]
        for (name, panel) in panels {
            let content = panel.frame(width: 740, height: 500).background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: content)
            view.frame = CGRect(origin: .zero, size: CGSize(width: 740, height: 500))
            let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            if let path = ProcessInfo.processInfo.environment["REI_CONTENT_PREVIEW_DIRECTORY"] {
                let destination = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let data = try #require(image.representation(using: .png, properties: [:]))
                try data.write(to: destination.appendingPathComponent(name + ".png"))
            }
        }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let store: ReiStore
        let environment: AppEnvironment
        let defaults: UserDefaults
        let defaultsName: String
        let groupModel: ConversationContentModel

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Rei-Content-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try ReiStore()
            for (index, id) in ["owner", "member", "bot"].enumerated() {
                try await store.save(
                    User(id: id, name: id.capitalized, createdAt: Date(timeIntervalSince1970: Double(index))))
            }
            try await store.save(Group(id: "group", name: "Group"))
            for id in ["owner", "member", "bot"] {
                try await store.save(GroupMember(groupID: "group", userID: id, role: id == "owner" ? .owner : .member))
            }
            defaultsName = "dev.rei.tests.content.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            environment = AppEnvironment(
                store: store, assetStore: try AssetStore(directory: directory.appendingPathComponent("assets")),
                appLog: AppLog(directory: directory.appendingPathComponent("logs"), emitUnifiedLog: false),
                defaults: defaults
            )
            await environment.setBotUser("bot")
            environment.setActiveUser("owner")
            environment.selectedProtocol = .milky
            try await environment.groupMembers(in: "group")
            groupModel = ConversationContentModel(
                environment: environment, chat: Chat(scene: .group, peerID: "group", selfID: "bot"))
        }

        func remove() {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
