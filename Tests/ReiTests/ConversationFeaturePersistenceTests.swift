import Foundation
import ReiCore
import ReiProtocol
import Testing

@Suite("Conversation Feature Persistence", .timeLimit(.minutes(1)))
struct ConversationFeaturePersistenceTests {
    @Test("New platform state survives reopening and is cleaned with its owning group")
    func reopenAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rei.store").path
        let chat = Chat(scene: .group, peerID: "50001", selfID: "10001")
        var messageID = ""
        var fileID = ""
        do {
            let store = try ReiStore(path: path)
            for id in ["10001", "10002"] { try await store.save(User(id: id, name: id)) }
            try await store.save(Group(id: chat.peerID, name: "Group"))
            try await store.save(GroupMember(groupID: chat.peerID, userID: "10001", role: .owner))
            try await store.save(GroupMember(groupID: chat.peerID, userID: "10002"))
            let platform = PlatformService(store: store)
            let message = try await platform.sendMessage(
                scene: .group, peerID: chat.peerID, senderID: "10002", selfID: chat.selfID, content: [.text("Remember")]
            )
            messageID = message.id
            try await platform.setPeerPin(in: chat, isPinned: true)
            try await platform.markRead(in: chat, through: message.seq)
            try await platform.likeProfile(userID: "10002", operatorID: "10001", count: 3)
            try await platform.postAnnouncement(groupID: chat.peerID, operatorID: "10001", content: "News")
            try await platform.setMessageEssence(messageID: message.id, operatorID: "10001", isSet: true)
            let folder = try await platform.createGroupFolder(
                groupID: chat.peerID, name: "Documents", operatorID: "10001")
            let asset = Asset(id: "asset", name: "readme.txt", byteCount: 5, source: .inline)
            let file = try await platform.shareFile(
                in: chat, operatorID: "10001", asset: asset, name: asset.name, folderID: folder.id)
            fileID = file.id
            let downloaded = try await platform.downloadSharedFile(id: file.id, in: chat, operatorID: "10002")
            #expect(downloaded.downloadCount == 1)
        }
        let store = try ReiStore(path: path)
        let state = try await store.conversationState(in: chat)
        #expect(state.isPinned)
        #expect(state.lastReadSequence == 1)
        #expect(try await store.announcements(groupID: chat.peerID).first?.content == "News")
        #expect(try await store.essences(in: chat).map(\.messageID) == [messageID])
        #expect(try await store.profileLikes(userID: "10002").first?.count == 3)
        #expect(try await store.sharedFiles(in: chat).first?.downloadCount == 1)
        #expect(try await store.folders(groupID: chat.peerID).first?.name == "Documents")
        let other = Chat(scene: .group, peerID: chat.peerID, selfID: "10002")
        #expect(try await store.conversationState(in: other).isPinned == false)
        #expect(try await store.essences(in: other).isEmpty)
        // Group directory entries belong to the group, not the uploading bot.
        #expect(try await store.sharedFiles(in: other).first?.id == fileID)
        try await store.deleteGroup(id: chat.peerID)
        #expect(try await store.sharedFile(id: fileID) == nil)
        #expect(try await store.folders(groupID: chat.peerID).isEmpty)
        #expect(try await store.announcements(groupID: chat.peerID).isEmpty)
        #expect(try await store.essences(in: chat).isEmpty)
        #expect(try await store.conversationStates(selfID: chat.selfID).isEmpty)
    }

    @Test("Clearing history removes essence references and resets read progress without unpinning")
    func clearHistory() async throws {
        let store = try ReiStore()
        let chat = Chat(scene: .group, peerID: "group", selfID: "bot")
        try await store.save(User(id: "bot", name: "Bot"))
        try await store.save(Group(id: "group", name: "Group"))
        let message = try await store.append(
            Message(
                scene: .group, peerID: chat.peerID, senderID: "member", selfID: "bot", content: [.text("hello")],
                direction: .outgoing))
        #expect(try await store.setPinned(true, in: chat))
        try await store.markRead(in: chat, through: message.seq)
        #expect(
            try await store.setEssence(
                MessageEssence(messageID: message.id, chat: chat, operatorID: "bot"), isSet: true))
        try await store.deleteMessages(in: chat)
        #expect(try await store.conversationState(in: chat) == ConversationState(chat: chat, isPinned: true))
        #expect(try await store.essences(in: chat).isEmpty)
    }

    @Test("Download requests increment once each even when concurrent")
    func concurrentDownloads() async throws {
        let store = try ReiStore()
        let chat = Chat(scene: .group, peerID: "group", selfID: "bot")
        try await store.save(Group(id: "group", name: "Group"))
        let file = SharedFile(
            chat: chat, name: "file", asset: Asset(id: "asset", name: "file", source: .inline), uploaderID: "bot")
        try await store.save(file)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let updated = try await store.recordFileDownload(id: file.id)
                    #expect(updated != nil)
                }
            }
            try await group.waitForAll()
        }
        #expect(try await store.sharedFile(id: file.id)?.downloadCount == 10)
    }

    @Test(
        "Private-file TriSHA1 includes byte length and all three large-file samples",
        arguments: [0, 5, 31 * 1024 * 1024])
    func fingerprints(size: Int) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        var data = Data(count: size)
        if size == 5 {
            data = Data("hello".utf8)
        } else if size > 0 {
            data[0] = 65
            data[size / 2] = 66
            data[size - 1] = 67
        }
        try data.write(to: path)
        let expected: [Int: String] = [
            0: "05fe405753166f125559e7c9ac558654f107c7e9",
            5: "1113c45656638f56343b4007b43f542217fbdb2c",
            31 * 1024 * 1024: "5545d3c5843e795e751ccff2e96ffc90a341dbda",
        ]
        #expect(try FileFingerprint.triSHA1(at: path) == expected[size])
    }
}
