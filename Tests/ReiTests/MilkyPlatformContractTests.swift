import Foundation
import ReiCore
import ReiMilky
import ReiProtocol
import Testing

/// Contract fixtures are based on Milky 1.3 system, group and file API tables.
/// https://milky.ntqqrev.org/api/system
/// https://milky.ntqqrev.org/api/group
/// https://milky.ntqqrev.org/api/file
@Suite("Milky Platform Contracts", .timeLimit(.minutes(1)))
struct MilkyPlatformContractTests {
    struct Fixture {
        let root: URL
        let store: ReiStore
        let platform: PlatformService
        let media: MediaService
        let adapter: MilkyProtocolImplementation

        func call(_ name: String, _ parameters: JSONValue = [:]) async -> ProtocolReply {
            await adapter.handle(call: ProtocolCall(name: name, parameters: parameters))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ReiStore()
        for id in ["10001", "10002", "10003"] { try await store.save(User(id: id, name: id)) }
        for id in ["50001", "50002"] {
            try await store.save(Group(id: id, name: id))
            try await store.save(GroupMember(groupID: id, userID: "10001", role: .owner))
            try await store.save(GroupMember(groupID: id, userID: "10002"))
        }
        try await store.save(Friendship(userID: "10001", friendID: "10002"))
        let platform = PlatformService(store: store)
        await platform.registerBot(id: "10001")
        let media = MediaService(assetStore: try AssetStore(directory: root), store: store)
        let adapter = MilkyProtocolImplementation(
            selfID: "10001", platform: platform, assetResolver: MilkyAssetResolverImpl(media: media, store: store))
        return Fixture(root: root, store: store, platform: platform, media: media, adapter: adapter)
    }

    @Test("Peer pins change state, query as entities, and publish the specified event")
    func peerPins() async throws {
        let f = try await fixture()
        defer { f.remove() }
        await f.platform.setEchoesSelfEvents(true)
        var events = await f.platform.events().makeAsyncIterator()
        let result = await f.call("set_peer_pin", ["message_scene": "group", "peer_id": 50001])
        #expect(result.isSuccess)
        guard result.isSuccess else { return }
        let event = try #require(await events.next())
        let wire = try #require(await f.adapter.encode(event: event).first?.payload)
        #expect(wire["event_type"] == "peer_pin_change")
        #expect(wire["data"] == ["message_scene": "group", "peer_id": 50001, "is_pinned": true])
        let pins = await f.call("get_peer_pins")
        #expect(pins.data["groups"]?.arrayValue?.first?["group_id"] == 50001)
        #expect(pins.data["friends"] == .array([]))
        #expect(
            await f.call("set_peer_pin", ["message_scene": "group", "peer_id": 50001, "is_pinned": false]).isSuccess)
        #expect(await f.call("get_peer_pins").data["groups"] == .array([]))
    }

    @Test("Announcements support create, list and delete with their full entity fields")
    func announcements() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let response = await f.call("send_group_announcement", ["group_id": 50001, "content": "Meeting tomorrow"])
        #expect(response.isSuccess)
        let listing = await f.call("get_group_announcements", ["group_id": 50001])
        let item = try #require(listing.data["announcements"]?.arrayValue?.first)
        #expect(item["group_id"] == 50001)
        #expect(item["user_id"] == 10001)
        #expect(item["content"] == "Meeting tomorrow")
        #expect(item["time"]?.int64Value != nil)
        let id = try #require(item["announcement_id"]?.stringValue)
        #expect(
            await f.call("delete_group_announcement", ["group_id": 50002, "announcement_id": .string(id)]).retcode != 0)
        #expect(
            await f.call("delete_group_announcement", ["group_id": 50001, "announcement_id": .string(id)]).isSuccess)
        #expect(await f.call("get_group_announcements", ["group_id": 50001]).data["announcements"] == .array([]))
    }

    @Test("Essence messages preserve author/operator fields, paginate and remove")
    func essence() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let message = try await f.platform.sendMessage(
            scene: .group, peerID: "50001", senderID: "10002", selfID: "10001", content: [.text("Keep this")])
        #expect(
            await f.call("set_group_essence_message", ["group_id": 50001, "message_seq": .number(Double(message.seq))])
                .isSuccess)
        let page = await f.call("get_group_essence_messages", ["group_id": 50001, "page_index": 0, "page_size": 1])
        let item = try #require(page.data["messages"]?.arrayValue?.first)
        #expect(item["group_id"] == 50001)
        #expect(item["sender_id"] == 10002)
        #expect(item["operator_id"] == 10001)
        #expect(item["message_seq"] == .number(Double(message.seq)))
        #expect(item["segments"] == [["type": "text", "data": ["text": "Keep this"]]])
        #expect(page.data["is_end"] == true)
        #expect(
            await f.call(
                "set_group_essence_message",
                ["group_id": 50001, "message_seq": .number(Double(message.seq)), "is_set": false]
            ).isSuccess)
        #expect(
            await f.call("get_group_essence_messages", ["group_id": 50001, "page_index": 0, "page_size": 10]).data[
                "messages"] == .array([]))
    }

    @Test("All group file operations share one persistent directory and enforce the supplied scope")
    func groupFileLifecycle() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let folderReply = await f.call("create_group_folder", ["group_id": 50001, "folder_name": "Documents"])
        let folderID = try #require(folderReply.data["folder_id"]?.stringValue)
        let upload = await f.call(
            "upload_group_file", ["group_id": 50001, "file_uri": "base64://aGVsbG8=", "file_name": "hello.txt"])
        let fileID = try #require(upload.data["file_id"]?.stringValue)
        let listing = await f.call("get_group_files", ["group_id": 50001])
        #expect(listing.data["files"]?.arrayValue?.first?["file_size"] == 5)
        #expect(listing.data["files"]?.arrayValue?.first?["uploader_id"] == 10001)
        #expect(listing.data["folders"]?.arrayValue?.first?["folder_id"] == .string(folderID))
        #expect(
            await f.call(
                "move_group_file",
                ["group_id": 50001, "file_id": .string(fileID), "target_folder_id": .string(folderID)]
            ).isSuccess)
        #expect(
            await f.call(
                "rename_group_file", ["group_id": 50001, "file_id": .string(fileID), "new_file_name": "wrong.txt"]
            ).retcode != 0)
        #expect(
            await f.call(
                "rename_group_file",
                [
                    "group_id": 50001, "file_id": .string(fileID), "parent_folder_id": .string(folderID),
                    "new_file_name": "renamed.txt",
                ]
            ).isSuccess)
        let moved = await f.call("get_group_files", ["group_id": 50001, "parent_folder_id": .string(folderID)])
        #expect(moved.data["files"]?.arrayValue?.first?["file_name"] == "renamed.txt")
        let download = await f.call("get_group_file_download_url", ["group_id": 50001, "file_id": .string(fileID)])
        #expect(download.data["download_url"]?.stringValue?.contains("/assets/") == true)
        #expect(
            await f.call("get_group_file_download_url", ["group_id": 50002, "file_id": .string(fileID)]).retcode != 0)
        #expect(await f.call("persist_group_file", ["group_id": 50001, "file_id": .string(fileID)]).isSuccess)
        #expect(
            await f.call(
                "rename_group_folder",
                ["group_id": 50001, "folder_id": .string(folderID), "new_folder_name": "Archive"]
            ).isSuccess)
        #expect(await f.call("delete_group_file", ["group_id": 50001, "file_id": .string(fileID)]).isSuccess)
        #expect(await f.call("delete_group_folder", ["group_id": 50001, "folder_id": .string(folderID)]).isSuccess)
        let empty = await f.call("get_group_files", ["group_id": 50001])
        #expect(empty.data["files"] == .array([]))
        #expect(empty.data["folders"] == .array([]))
    }
}
