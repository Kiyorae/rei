import Foundation
import ReiCore
import ReiProtocol
import Testing

@Suite("Milky File Contracts", .timeLimit(.minutes(1)))
struct MilkyFileContractTests {
    @Test("The existing group-upload entry point populates the same directory and event file ID")
    func sharedGroupUpload() async throws {
        let f = try await MilkyPlatformContractTests().fixture()
        defer { f.remove() }
        let asset = try #require(await f.media.store(data: Data("content".utf8), name: "shared.txt"))
        var events = await f.platform.events().makeAsyncIterator()
        try await f.platform.uploadGroupFile(groupID: "50001", userID: "10002", asset: asset)
        let entry = try #require(
            try await f.store.sharedFiles(in: Chat(scene: .group, peerID: "50001", selfID: "10001")).first)
        #expect(entry.asset.id == asset.id)
        let event = try #require(await events.next())
        let wire = try #require(await f.adapter.encode(event: event).first?.payload)
        #expect(wire["data"]?["file_id"] == .string(entry.id))
    }
    @Test("Private uploads emit the exact fingerprint and download identity is checked")
    func privateFile() async throws {
        let f = try await MilkyPlatformContractTests().fixture()
        defer { f.remove() }
        await f.platform.setEchoesSelfEvents(true)
        var events = await f.platform.events().makeAsyncIterator()
        let uploaded = await f.call(
            "upload_private_file", ["user_id": 10002, "file_uri": "base64://aGVsbG8=", "file_name": "Hello.txt"])
        let id = try #require(uploaded.data["file_id"]?.stringValue)
        let event = try #require(await events.next())
        let wire = try #require(await f.adapter.encode(event: event).first?.payload)
        #expect(wire["event_type"] == "friend_file_upload")
        #expect(
            wire["data"] == [
                "user_id": 10002, "file_id": .string(id), "file_name": "Hello.txt", "file_size": 5,
                "file_hash": "1113c45656638f56343b4007b43f542217fbdb2c", "is_self": true,
            ])
        let base: [String: JSONValue] = [
            "user_id": 10002, "file_id": .string(id), "file_hash": "1113c45656638f56343b4007b43f542217fbdb2c",
            "is_self_send": true,
        ]
        let download = await f.call("get_private_file_download_url", .object(base))
        #expect(download.isSuccess)
        #expect(download.data["download_url"]?.stringValue?.hasPrefix("http://") == true)
        for change: [String: JSONValue] in [["user_id": 10003], ["file_hash": "incorrect"], ["is_self_send": false]] {
            let bad = base.merging(change) { _, new in new }
            #expect(await f.call("get_private_file_download_url", .object(bad)).isSuccess == false)
        }
        #expect(try await f.store.sharedFile(id: id)?.downloadCount == 1)
    }

    @Test("Concurrent renames and downloads do not overwrite independent fields")
    func atomicFileEdits() async throws {
        let f = try await MilkyPlatformContractTests().fixture()
        defer { f.remove() }
        let uploaded = await f.call(
            "upload_group_file", ["group_id": 50001, "file_uri": "base64://YQ==", "file_name": "original.txt"])
        let id = try #require(uploaded.data["file_id"]?.stringValue)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    try await f.platform.renameGroupFile(
                        id: id, groupID: "50001", folderID: "/", name: "name-\(index).txt", operatorID: "10001")
                }
                group.addTask {
                    let file = try await f.platform.downloadSharedFile(
                        id: id, in: Chat(scene: .group, peerID: "50001", selfID: "10001"), operatorID: "10002")
                    #expect(file.downloadCount > 0)
                }
            }
            try await group.waitForAll()
        }
        #expect(try await f.store.sharedFile(id: id)?.downloadCount == 30)
        try await f.store.deleteSharedFile(id: id)
        await #expect(throws: StoreMutationError.self) {
            try await f.store.editSharedFile(id: id, groupID: "50001", edit: .makePermanent)
        }
        #expect(try await f.store.sharedFile(id: id) == nil)
    }

    @Test("Folders cannot be duplicated concurrently or resurrected by a delayed rename")
    func atomicFolders() async throws {
        let f = try await MilkyPlatformContractTests().fixture()
        defer { f.remove() }
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        try await f.platform.createGroupFolder(groupID: "50001", name: "Same", operatorID: "10001")
                        return true
                    } catch { return false }
                }
            }
            var successes = 0
            for await succeeded in group { if succeeded { successes += 1 } }
            return successes
        }
        #expect(outcomes == 1)
        let folder = try #require(try await f.store.folders(groupID: "50001").first)
        try await f.platform.deleteGroupFolder(id: folder.id, groupID: "50001", operatorID: "10001")
        await #expect(throws: StoreMutationError.self) {
            try await f.store.renameFolder(id: folder.id, groupID: "50001", name: "Resurrected")
        }
        #expect(try await f.store.folders(groupID: "50001").isEmpty)
    }

    @Test("Delayed read and highlight writes cannot attach to cleared or recalled messages")
    func atomicMessageState() async throws {
        let f = try await MilkyPlatformContractTests().fixture()
        defer { f.remove() }
        let chat = Chat(scene: .group, peerID: "50001", selfID: "10001")
        let old = try await f.platform.sendMessage(
            scene: .group, peerID: chat.peerID, senderID: "10002", selfID: chat.selfID, content: [.text("old")])
        try await f.store.deleteMessages(in: chat)
        let new = try await f.platform.sendMessage(
            scene: .group, peerID: chat.peerID, senderID: "10002", selfID: chat.selfID, content: [.text("new")])
        #expect(new.seq == old.seq)
        await #expect(throws: StoreMutationError.self) {
            try await f.store.markRead(in: chat, through: old.seq, expectedMessageID: old.id)
        }
        #expect(try await f.store.conversationState(in: chat).lastReadSequence == 0)
        try await f.platform.recallMessage(id: new.id, operatorID: "10002")
        await #expect(throws: StoreMutationError.self) {
            try await f.store.setEssence(
                MessageEssence(messageID: new.id, chat: chat, operatorID: "10001"), isSet: true)
        }
        #expect(try await f.store.essences(in: chat).isEmpty)
    }
}
