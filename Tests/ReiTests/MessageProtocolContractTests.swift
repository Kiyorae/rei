import Foundation
import ReiCore
import ReiMilky
import ReiOneBot
import ReiProtocol
import Testing

/// Expectations come from the published contracts, not the adapter output.
/// - https://github.com/botuniverse/onebot-11/blob/master/event/notice.md
/// - https://12.onebot.dev/interface/group/notice-events/
/// - https://12.onebot.dev/interface/message/segments/
/// - https://milky.ntqqrev.org/api/message
/// - https://milky.ntqqrev.org/api/group
/// - https://milky.ntqqrev.org/struct/Event
@Suite("Message Protocol Contracts")
struct MessageProtocolContractTests {
    private struct Fixture {
        let store: ReiStore
        let platform: PlatformService
        let media: MediaService
        let folder: URL

        func oneBot(_ version: OneBotVersion) -> OneBotProtocolImplementation {
            OneBotProtocolImplementation(
                version: version, selfID: "10001", platform: platform, assetResolver: OneBotAssetResolver(media: media))
        }

        func milky() -> MilkyProtocolImplementation {
            MilkyProtocolImplementation(
                selfID: "10001", platform: platform, assetResolver: MilkyAssetResolverImpl(media: media, store: store))
        }

        func message(groupID: String = "50001", selfID: String = "10001", senderID: String = "10002") async throws
            -> Message
        {
            try await platform.sendMessage(
                scene: .group, peerID: groupID, senderID: senderID, selfID: selfID, content: [.text("original")])
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    private func fixture() async throws -> Fixture {
        let store = try ReiStore()
        for id in ["10001", "10002"] { try await store.save(User(id: id, name: id)) }
        for id in ["50001", "50002"] {
            try await store.save(Group(id: id, name: id))
            try await store.save(GroupMember(groupID: id, userID: "10001", role: .admin))
            try await store.save(GroupMember(groupID: id, userID: "10002"))
        }
        let platform = PlatformService(store: store)
        await platform.registerBot(id: "10001")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assets = try AssetStore(directory: folder)
        return Fixture(
            store: store, platform: platform, media: MediaService(assetStore: assets, store: store), folder: folder)
    }

    @Test("Milky group moderation events preserve targets, durations and toggles")
    func groupModerationEvents() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let adapter = fixture.milky()
        let cases: [(DomainEvent.Payload, String, JSONValue)] = [
            (
                .groupMuted(.init(groupID: "50001", userID: "10002", operatorID: "10001", muted: true, duration: 600)),
                "group_mute", ["group_id": 50001, "user_id": 10002, "operator_id": 10001, "duration": 600]
            ),
            (
                .groupMuted(.init(groupID: "50001", userID: nil, operatorID: "10001", muted: false)),
                "group_whole_mute", ["group_id": 50001, "operator_id": 10001, "is_mute": false]
            ),
            (
                .groupAdminChanged(.init(groupID: "50001", userID: "10002", operatorID: "10001", granted: true)),
                "group_admin_change", ["group_id": 50001, "user_id": 10002, "operator_id": 10001, "is_set": true]
            ),
        ]
        for (payload, type, data) in cases {
            let wire = try #require(
                await adapter.encode(event: DomainEvent(selfID: "10001", payload: payload)).first?.payload)
            #expect(wire["event_type"] == .string(type))
            #expect(wire["data"] == data)
        }
    }

    @Test("Milky friend nudges stay addressed to the bot session even when the target is the friend")
    func friendNudgeRouting() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        await fixture.platform.setEchoesSelfEvents(true)
        var events = await fixture.platform.events().makeAsyncIterator()
        let adapter = fixture.milky()
        let response = await adapter.handle(
            call: ProtocolCall(name: "send_friend_nudge", parameters: ["user_id": 10002]))
        #expect(response.isSuccess)
        let event = try #require(await events.next())
        #expect(event.selfID == "10001")
        let wire = try #require(await adapter.encode(event: event).first?.payload)
        #expect(wire["event_type"] == "friend_nudge")
        #expect(wire["data"]?["user_id"] == 10002)
        #expect(wire["data"]?["is_self_send"] == true)
        #expect(wire["data"]?["is_self_receive"] == false)
    }

    @Test(
        "OneBot recall emits the specified notice and identifier types", arguments: [OneBotVersion.v11, .v12],
        [false, true])
    func oneBotRecall(version: OneBotVersion, administrative: Bool) async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let message = try await fixture.message()
        await fixture.platform.setEchoesSelfEvents(true)
        var events = await fixture.platform.events().makeAsyncIterator()
        let operatorID = administrative ? "10001" : "10002"
        try await fixture.platform.recallMessage(id: message.id, operatorID: operatorID)
        let event = try #require(await events.next())
        let frames = await fixture.oneBot(version).encode(event: event)
        let wire = try #require(frames.first?.payload)
        switch version {
        case .v11:
            #expect(wire["post_type"] == "notice")
            #expect(wire["notice_type"] == "group_recall")
            #expect(wire["group_id"] == 50001)
            #expect(wire["user_id"] == 10002)
            #expect(wire["operator_id"] == .number(Double(operatorID)!))
            #expect(wire["message_id"] == .number(Double(message.id)!))
        case .v12:
            #expect(wire["type"] == "notice")
            #expect(wire["detail_type"] == "group_message_delete")
            #expect(wire["sub_type"] == .string(administrative ? "delete" : "recall"))
            #expect(wire["group_id"] == "50001")
            #expect(wire["user_id"] == "10002")
            #expect(wire["operator_id"] == .string(operatorID))
            #expect(wire["message_id"] == .string(message.id))
        }
    }

    @Test("OneBot delete actions recall persisted messages", arguments: [OneBotVersion.v11, .v12])
    func oneBotDeleteAction(version: OneBotVersion) async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let message = try await fixture.message()
        let reply = await fixture.oneBot(version).handle(
            call: ProtocolCall(
                name: version == .v11 ? "delete_msg" : "delete_message",
                parameters: ["message_id": version == .v11 ? .number(Double(message.id)!) : .string(message.id)]
            ))
        #expect(reply.retcode == 0)
        #expect(try await fixture.store.message(id: message.id)?.isRecalled == true)
    }

    @Test("OneBot reply segments carry the required reference fields", arguments: [OneBotVersion.v11, .v12])
    func oneBotReply(version: OneBotVersion) async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let target = try await fixture.message()
        let reply = try await fixture.platform.sendMessage(
            scene: .group, peerID: "50001", senderID: "10002", selfID: "10001",
            content: [.reply(messageID: target.id), .text("answer")]
        )
        let frames = await fixture.oneBot(version).encode(event: DomainEvent(selfID: "10001", payload: .message(reply)))
        let segment = try #require(frames.first?.payload["message"]?.arrayValue?.first)
        #expect(segment["type"] == "reply")
        #expect(segment["data"]?[version == .v11 ? "id" : "message_id"] == .string(target.id))
        if version == .v12 { #expect(segment["data"]?["user_id"] == "10002") }
    }

    @Test("OneBot V11 friend addition uses friend_add")
    func v11FriendAdded() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let frames = await fixture.oneBot(.v11).encode(
            event: DomainEvent(selfID: "10001", payload: .friendAdded(userID: "10002")))
        let wire = try #require(frames.first?.payload)
        #expect(wire["notice_type"] == "friend_add")
        #expect(wire["user_id"] == 10002)
    }

    @Test("Neither OneBot standard invents a reaction event or action", arguments: [OneBotVersion.v11, .v12])
    func oneBotDoesNotInventReactions(version: OneBotVersion) async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let adapter = fixture.oneBot(version)
        let event = DomainEvent(
            selfID: "10001",
            payload: .messageReaction(
                .init(
                    messageID: "70001", scene: .group, peerID: "50001", userID: "10002",
                    reaction: Reaction(kind: .face, value: "76"), added: true
                )))
        #expect(await adapter.encode(event: event).isEmpty)
        let reply = await adapter.handle(call: ProtocolCall(name: "send_group_message_reaction", parameters: [:]))
        #expect(reply.retcode == (version == .v11 ? 1404 : 10002))
    }

    @Test(
        "Milky reaction defaults, types and removal follow the API contract", arguments: [Reaction.Kind.face, .emoji])
    func milkyReactions(kind: Reaction.Kind) async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let message = try await fixture.message()
        let adapter = fixture.milky()
        var params: [String: JSONValue] = [
            "group_id": 50001, "message_seq": .number(Double(message.seq)), "reaction": "128077",
        ]
        if kind == .emoji { params["reaction_type"] = "emoji" }
        let added = await adapter.handle(
            call: ProtocolCall(name: "send_group_message_reaction", parameters: .object(params)))
        #expect(added.retcode == 0)
        #expect(added.data == .object([:]))
        let reaction = Reaction(kind: kind, value: "128077")
        #expect(
            try await fixture.store.message(id: message.id)?.reactions == [
                MessageReaction(reaction: reaction, userIDs: ["10001"])
            ])

        let wire = try #require(
            await adapter.encode(
                event: DomainEvent(
                    selfID: "10001",
                    payload: .messageReaction(
                        .init(
                            messageID: message.id, scene: .group, peerID: "50001", userID: "10002", reaction: reaction,
                            added: false
                        )))
            ).first?.payload)
        #expect(wire["event_type"] == "group_message_reaction")
        #expect(
            wire["data"] == [
                "group_id": 50001, "user_id": 10002, "message_seq": .number(Double(message.seq)),
                "face_id": "128077", "reaction_type": .string(kind.rawValue), "is_add": false,
            ])
        params["is_add"] = false
        #expect(
            await adapter.handle(call: ProtocolCall(name: "send_group_message_reaction", parameters: .object(params)))
                .isSuccess)
        #expect(try await fixture.store.message(id: message.id)?.reactions.isEmpty == true)
    }

    @Test(
        "Milky rejects reaction parameters outside their declared types",
        arguments: [
            JSONValue.object(["reaction_type": "sticker"]), .object(["reaction_type": .null]),
            .object(["is_add": "wrong"]), .object(["reaction": 76]), .object(["message_seq": 1.5]),
        ])
    func invalidMilkyReaction(overrides: JSONValue) async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let message = try await fixture.message()
        var params: [String: JSONValue] = [
            "group_id": 50001, "message_seq": .number(Double(message.seq)), "reaction": "76",
        ]
        params.merge(overrides.objectValue ?? [:]) { _, new in new }
        let reply = await fixture.milky().handle(
            call: ProtocolCall(name: "send_group_message_reaction", parameters: .object(params)))
        #expect(reply.retcode == -400)
        #expect(try await fixture.store.message(id: message.id)?.reactions.isEmpty == true)
    }

    @Test("Milky replies resolve sequence numbers within each request's conversation")
    func milkyReplyScope() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let first = try await fixture.message()
        let second = try await fixture.message(groupID: "50002")
        #expect(first.seq == second.seq)
        let adapter = fixture.milky()
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for target in [first, second] {
                tasks.addTask {
                    let reply = await adapter.handle(
                        call: ProtocolCall(
                            name: "send_group_message",
                            parameters: [
                                "group_id": .number(Double(target.peerID)!),
                                "message": [
                                    ["type": "reply", "data": ["message_seq": .number(Double(target.seq))]],
                                    ["type": "text", "data": ["text": "answer"]],
                                ],
                            ]))
                    #expect(reply.isSuccess)
                    let stored = try await fixture.store.message(
                        scene: .group, peerID: target.peerID, seq: reply.data["message_seq"]?.int64Value ?? 0,
                        selfID: "10001")
                    #expect(stored?.content.replyTarget == target.id)
                }
            }
            try await tasks.waitForAll()
        }
    }

    @Test("Milky recall uses a per-chat sequence and recalled history is unavailable")
    func milkyRecallAndHistory() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let message = try await fixture.message()
        await fixture.platform.setEchoesSelfEvents(true)
        var events = await fixture.platform.events().makeAsyncIterator()
        let adapter = fixture.milky()
        let reply = await adapter.handle(
            call: ProtocolCall(
                name: "recall_group_message",
                parameters: ["group_id": 50001, "message_seq": .number(Double(message.seq))]))
        #expect(reply.isSuccess)
        #expect(reply.data == .object([:]))
        let event = try #require(await events.next())
        let wire = try #require(await adapter.encode(event: event).first?.payload)
        #expect(wire["event_type"] == "message_recall")
        #expect(wire["data"]?["message_seq"] == .number(Double(message.seq)))
        #expect(wire["data"]?["sender_id"] == 10002)
        #expect(wire["data"]?["operator_id"] == 10001)
        let history = await adapter.handle(
            call: ProtocolCall(name: "get_history_messages", parameters: ["message_scene": "group", "peer_id": 50001]))
        #expect(history.isSuccess)
        #expect(history.data["messages"] == .array([]))
    }
}
