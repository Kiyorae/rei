import Foundation
import ReiCore
import ReiProtocol
import Testing

@Suite("Message Interactions")
struct MessageInteractionTests {
    private func fixture() async throws -> (ReiStore, PlatformService, Message) {
        let store = try ReiStore()
        for id in ["bot", "alice", "bob", "outsider"] { try await store.save(User(id: id, name: id)) }
        try await store.save(Group(id: "group", name: "Group"))
        for id in ["bot", "alice", "bob"] {
            try await store.save(GroupMember(groupID: "group", userID: id))
        }
        let platform = PlatformService(store: store)
        await platform.registerBot(id: "bot")
        let message = try await platform.sendMessage(
            scene: .group, peerID: "group", senderID: "alice", selfID: "bot", content: [.text("hello")]
        )
        return (store, platform, message)
    }

    @Test("Reaction membership survives duplicate requests, separates namespaces, and publishes committed state")
    func reactionMembership() async throws {
        let (store, platform, message) = try await fixture()
        let face = Reaction(kind: .face, value: "76")
        let emoji = Reaction(kind: .emoji, value: "76")
        var events = await platform.events().makeAsyncIterator()
        try await platform.react(messageID: message.id, userID: "alice", reaction: face, added: true)
        let event = try #require(await events.next())
        guard case .messageReaction(let change) = event.payload else {
            Issue.record("Expected a reaction event")
            return
        }
        #expect(change.reaction == face)
        #expect(change.added)
        #expect(try await store.message(id: message.id)?.reactions.first?.userIDs == ["alice"])

        try await platform.react(messageID: message.id, userID: "alice", reaction: face, added: true)
        try await platform.react(messageID: message.id, userID: "bob", reaction: face, added: true)
        let next = try #require(await events.next())
        guard case .messageReaction(let nextChange) = next.payload else {
            Issue.record("Expected a reaction event")
            return
        }
        // A duplicate Alice add must not appear before Bob's real change.
        #expect(nextChange.userID == "bob")
        try await platform.react(messageID: message.id, userID: "alice", reaction: emoji, added: true)
        var loaded = try #require(try await store.message(id: message.id))
        #expect(loaded.reactions.count == 2)
        #expect(loaded.reactions.first?.userIDs == ["alice", "bob"])

        try await platform.react(messageID: message.id, userID: "alice", reaction: face, added: false)
        try await platform.react(messageID: message.id, userID: "alice", reaction: face, added: false)
        loaded = try #require(try await store.message(id: message.id))
        #expect(loaded.reactions.first?.userIDs == ["bob"])
        try await platform.react(messageID: message.id, userID: "bob", reaction: face, added: false)
        #expect(try await store.message(id: message.id)?.reactions.map(\.reaction) == [emoji])
    }

    @Test("Concurrent reaction writes preserve both participants")
    func concurrentReactions() async throws {
        let (store, platform, message) = try await fixture()
        let reaction = Reaction(kind: .face, value: "76")
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for user in ["alice", "bob"] {
                tasks.addTask {
                    try await platform.react(messageID: message.id, userID: user, reaction: reaction, added: true)
                }
            }
            try await tasks.waitForAll()
        }
        #expect(try await store.message(id: message.id)?.reactions.first?.userIDs == ["alice", "bob"])
    }

    @Test("Reactions reject outsiders, empty IDs, private chats, and recalled messages")
    func reactionValidation() async throws {
        let (store, platform, message) = try await fixture()
        let reaction = Reaction(kind: .face, value: "76")
        await #expect(throws: PlatformError.self) {
            try await platform.react(messageID: message.id, userID: "outsider", reaction: reaction, added: true)
        }
        await #expect(throws: PlatformError.self) {
            try await platform.react(
                messageID: message.id, userID: "alice", reaction: Reaction(kind: .face, value: " "), added: true)
        }
        let direct = try await platform.sendMessage(
            scene: .friend, peerID: "alice", senderID: "alice", selfID: "bot", content: [.text("hi")]
        )
        await #expect(throws: PlatformError.self) {
            try await platform.react(messageID: direct.id, userID: "alice", reaction: reaction, added: true)
        }
        try await platform.react(messageID: message.id, userID: "alice", reaction: reaction, added: true)
        let recalled = try await platform.recallMessage(id: message.id, operatorID: "alice")
        let again = try await platform.recallMessage(id: message.id, operatorID: "alice")
        #expect(recalled.recalledAt == again.recalledAt)
        #expect(recalled.reactions.isEmpty)
        await #expect(throws: PlatformError.self) {
            try await platform.react(messageID: message.id, userID: "bob", reaction: reaction, added: true)
        }
        #expect(try await store.message(id: message.id)?.reactions.isEmpty == true)
    }

    @Test("Replies require a live target in the same bot-scoped conversation")
    func replyValidation() async throws {
        let (_, platform, message) = try await fixture()
        let content: [MessageSegment] = [.reply(messageID: message.id), .text("answer")]
        let reply = try await platform.sendMessage(
            scene: .group, peerID: "group", senderID: "bob", selfID: "bot", content: content
        )
        #expect(reply.content == content)
        await #expect(throws: PlatformError.self) {
            try await platform.sendMessage(
                scene: .group, peerID: "group", senderID: "bob", selfID: "other-bot", content: content)
        }
        await #expect(throws: PlatformError.self) {
            try await platform.sendMessage(
                scene: .friend, peerID: "alice", senderID: "alice", selfID: "bot", content: content)
        }
        try await platform.recallMessage(id: message.id, operatorID: "alice")
        await #expect(throws: PlatformError.self) {
            try await platform.sendMessage(
                scene: .group, peerID: "group", senderID: "bob", selfID: "bot", content: content)
        }
    }

    @Test("Quoted-message observations follow recalls and history deletion")
    func quoteObservation() async throws {
        let (store, platform, message) = try await fixture()
        var iterator = store.observeMessage(id: message.id).makeAsyncIterator()
        #expect(try await iterator.next()??.isRecalled == false)
        try await platform.recallMessage(id: message.id, operatorID: "alice")
        #expect(try await iterator.next()??.isRecalled == true)
        try await store.deleteMessages(in: message.chat)
        let next = try await iterator.next()
        #expect(next != nil)
        #expect(next! == nil)
    }
}
