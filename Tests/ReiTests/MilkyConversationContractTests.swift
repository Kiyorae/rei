import CoreGraphics
import Foundation
import ImageIO
import ReiCore
import ReiMilky
import ReiProtocol
import Testing

/// https://milky.ntqqrev.org/api/system
/// https://milky.ntqqrev.org/api/group
/// https://milky.ntqqrev.org/api/message
/// https://milky.ntqqrev.org/api/friend
extension MilkyPlatformContractTests {
    @Test("Private pins return user entities and stay within the bot account")
    func privatePinEntities() async throws {
        let f = try await fixture()
        defer { f.remove() }
        #expect(await f.call("set_peer_pin", ["message_scene": "friend", "peer_id": 10002]).isSuccess)
        #expect(await f.call("set_peer_pin", ["message_scene": "temp", "peer_id": 10003]).isSuccess)
        #expect(try await f.store.setPinned(true, in: Chat(scene: .group, peerID: "50001", selfID: "10003")))
        let result = await f.call("get_peer_pins")
        let friends = try #require(result.data["friends"]?.arrayValue)
        #expect(Set(friends.compactMap { $0["user_id"]?.intValue }) == [10002, 10003])
        #expect(friends.allSatisfy { $0["nickname"]?.stringValue != nil && $0["category"]?["category_id"] == 0 })
        #expect(result.data["groups"] == .array([]))
    }

    @Test("Announcement images are stored and exposed as downloadable image_url values")
    func announcementImages() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let context = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let uri = "base64://" + (data as Data).base64EncodedString()
        #expect(
            await f.call(
                "send_group_announcement", ["group_id": 50001, "content": "Image notice", "image_uri": .string(uri)]
            ).isSuccess)
        let response = await f.call("get_group_announcements", ["group_id": 50001])
        let item = try #require(response.data["announcements"]?.arrayValue?.first)
        let imageURL = try #require(item["image_url"]?.stringValue)
        #expect(imageURL.hasPrefix("http://127.0.0.1:"))
        let announcements = try await f.store.announcements(groupID: "50001")
        let storedImage = try #require(announcements.first?.image)
        let storedBytes = try #require(await f.media.data(for: storedImage.id))
        #expect(storedBytes == data as Data)
        #expect(await f.call("get_group_info", ["group_id": 50001]).data["group"]?["announcement"] == "Image notice")
    }

    @Test("Read markers persist per conversation and never move backwards")
    func readMarkers() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let first = try await f.platform.sendMessage(
            scene: .group, peerID: "50001", senderID: "10002", selfID: "10001", content: [.text("first")])
        let second = try await f.platform.sendMessage(
            scene: .group, peerID: "50001", senderID: "10002", selfID: "10001", content: [.text("second")])
        for sequence in [second.seq, first.seq, second.seq] {
            #expect(
                await f.call(
                    "mark_message_as_read",
                    [
                        "message_scene": "group", "peer_id": 50001, "message_seq": .number(Double(sequence)),
                    ]
                ).isSuccess)
        }
        #expect(try await f.store.conversationState(in: second.chat).lastReadSequence == second.seq)
        let other = Chat(scene: .group, peerID: "50002", selfID: "10001")
        #expect(try await f.store.conversationState(in: other).lastReadSequence == 0)
        #expect(
            await f.call(
                "mark_message_as_read",
                [
                    "message_scene": "group", "peer_id": 50002, "message_seq": .number(Double(second.seq)),
                ]
            ).retcode != 0)
    }

    @Test("Profile likes use the protocol default count and update persistent totals")
    func profileLikes() async throws {
        let f = try await fixture()
        defer { f.remove() }
        #expect(await f.call("send_profile_like", ["user_id": 10002]).isSuccess)
        #expect(await f.call("send_profile_like", ["user_id": 10002, "count": 3]).isSuccess)
        let likes = try await f.store.profileLikes(userID: "10002")
        #expect(likes.count == 1)
        #expect(likes.first?.operatorID == "10001")
        #expect(likes.first?.count == 4)
        #expect(await f.call("send_profile_like", ["user_id": 10001]).retcode != 0)
        #expect(await f.call("send_profile_like", ["user_id": 99999]).retcode != 0)
    }

    @Test("New Milky fields reject coercion, fractional IDs, invalid booleans and invalid pagination")
    func strictConversationParameters() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let cases: [(String, JSONValue)] = [
            ("set_peer_pin", ["message_scene": "group", "peer_id": "50001"]),
            ("set_peer_pin", ["message_scene": "group", "peer_id": 50001.5]),
            ("set_peer_pin", ["message_scene": "group", "peer_id": 50001, "is_pinned": "true"]),
            ("set_peer_pin", ["message_scene": "other", "peer_id": 50001]),
            ("send_profile_like", ["user_id": 10002, "count": 0]),
            ("send_profile_like", ["user_id": 10002, "count": 1.5]),
            ("send_profile_like", ["user_id": 10002, "count": true]),
            ("send_profile_like", ["user_id": 10002, "count": 2_147_483_648]),
            ("send_group_announcement", ["group_id": 50001, "content": 123]),
            ("send_group_announcement", ["group_id": 50001, "content": "text", "image_uri": false]),
            ("get_group_essence_messages", ["group_id": 50001, "page_index": -1, "page_size": 1]),
            ("get_group_essence_messages", ["group_id": 50001, "page_index": 0, "page_size": 0]),
            ("get_group_essence_messages", ["group_id": 50001, "page_index": 0]),
            ("get_peer_pins", .array([])),
        ]
        for (name, parameters) in cases {
            #expect(await f.call(name, parameters).retcode == -400, "\(name) accepted invalid input")
        }
        #expect(try await f.store.profileLikes(userID: "10002").isEmpty)
    }

    @Test("Duplicate pin and essence changes do not publish duplicate state-change events")
    func idempotentConversationEvents() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let message = try await f.platform.sendMessage(
            scene: .group, peerID: "50001", senderID: "10002", selfID: "10001", content: [.text("keep")])
        await f.platform.setEchoesSelfEvents(true)
        var events = await f.platform.events().makeAsyncIterator()
        for pinned in [true, true, false] {
            #expect(
                await f.call(
                    "set_peer_pin",
                    [
                        "message_scene": "group", "peer_id": 50001, "is_pinned": .bool(pinned),
                    ]
                ).isSuccess)
        }
        for expected in [true, false] {
            let event = try #require(await events.next())
            let frame = try #require(await f.adapter.encode(event: event).first?.payload)
            #expect(frame["event_type"] == "peer_pin_change")
            #expect(frame["data"]?["is_pinned"] == .bool(expected))
        }
        for isSet in [true, true, false] {
            #expect(
                await f.call(
                    "set_group_essence_message",
                    [
                        "group_id": 50001, "message_seq": .number(Double(message.seq)), "is_set": .bool(isSet),
                    ]
                ).isSuccess)
        }
        for expected in [true, false] {
            let event = try #require(await events.next())
            let frame = try #require(await f.adapter.encode(event: event).first?.payload)
            #expect(frame["event_type"] == "group_essence_message_change")
            #expect(
                frame["data"] == [
                    "group_id": 50001, "message_seq": .number(Double(message.seq)),
                    "operator_id": 10001, "is_set": .bool(expected),
                ])
        }
    }

    @Test("Essence pagination returns all entity fields and an empty terminal page")
    func essencePagination() async throws {
        let f = try await fixture()
        defer { f.remove() }
        for text in ["one", "two"] {
            let message = try await f.platform.sendMessage(
                scene: .group, peerID: "50001", senderID: "10002", selfID: "10001", content: [.text(text)])
            #expect(
                await f.call(
                    "set_group_essence_message",
                    [
                        "group_id": 50001, "message_seq": .number(Double(message.seq)),
                    ]
                ).isSuccess)
        }
        let first = await f.call("get_group_essence_messages", ["group_id": 50001, "page_index": 0, "page_size": 1])
        let second = await f.call("get_group_essence_messages", ["group_id": 50001, "page_index": 1, "page_size": 1])
        #expect(first.data["is_end"] == false)
        #expect(second.data["is_end"] == true)
        let item = try #require(first.data["messages"]?.arrayValue?.first)
        #expect(item["message_time"]?.int64Value != nil)
        #expect(item["operation_time"]?.int64Value != nil)
        #expect(item["sender_name"] == "10002")
        #expect(item["operator_name"] == "10001")
        #expect(item["message_seq"] != second.data["messages"]?.arrayValue?.first?["message_seq"])
        let beyond = await f.call(
            "get_group_essence_messages",
            [
                "group_id": 50001, "page_index": 2_147_483_647, "page_size": 2_147_483_647,
            ])
        #expect(beyond.isSuccess && beyond.data["is_end"] == true)
        #expect(beyond.data["messages"] == .array([]))
    }

    @Test("Announcements and essence writes require authority and remain in their group")
    func conversationPermissions() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let message = try await f.platform.sendMessage(
            scene: .group, peerID: "50001", senderID: "10002", selfID: "10001", content: [.text("keep")])
        #expect(
            await f.call(
                "set_group_essence_message",
                [
                    "group_id": 50002, "message_seq": .number(Double(message.seq)),
                ]
            ).retcode != 0)
        try await f.store.save(GroupMember(groupID: "50001", userID: "10001"))
        #expect(await f.call("send_group_announcement", ["group_id": 50001, "content": "forbidden"]).retcode != 0)
        #expect(
            await f.call(
                "set_group_essence_message",
                [
                    "group_id": 50001, "message_seq": .number(Double(message.seq)),
                ]
            ).retcode != 0)
        try await f.store.removeMember(groupID: "50001", userID: "10001")
        #expect(await f.call("get_group_announcements", ["group_id": 50001]).retcode != 0)
        #expect(
            await f.call("get_group_essence_messages", ["group_id": 50001, "page_index": 0, "page_size": 1]).retcode
                != 0)
    }

    @Test("Temporary resource URLs use the configured HTTP endpoint and authorize the real bytes")
    func temporaryResources() async throws {
        let f = try await fixture()
        defer { f.remove() }
        await f.adapter.configureResourceEndpoint(host: "127.0.0.1", port: 12345)
        let asset = try #require(await f.media.store(data: Data("hello".utf8), name: "test.txt"))
        let response = await f.call("get_resource_temp_url", ["resource_id": .string(asset.id)])
        let address = try #require(response.data["url"]?.stringValue)
        let url = try #require(URLComponents(string: address))
        #expect(url.scheme == "http" && url.port == 12345)
        #expect(url.path == "/assets/\(asset.id)")
        let token = url.queryItems?.first { $0.name == "token" }?.value
        #expect(await f.media.resource(id: asset.id, token: token) != nil)
    }
}
