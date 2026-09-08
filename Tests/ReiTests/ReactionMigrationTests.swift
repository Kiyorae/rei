import Foundation
import SwiftData
import Testing

@testable import ReiCore

@Suite("Reaction Persistence")
struct ReactionMigrationTests {
    @Test("V1 stores migrate without losing messages, personas, or membership; reactions survive reopening")
    @MainActor
    func migrateAndReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rei.store")
        try seedV1(at: url)

        let reaction = Reaction(kind: .emoji, value: "128077")
        do {
            let store = try ReiStore(path: url.path)
            let original = try #require(try await store.message(id: "old-message"))
            #expect(original.content == [.text("Saved before reactions")])
            #expect(original.reactions.isEmpty)
            #expect(try await store.user(id: "alice")?.name == "Alice")
            #expect(try await store.member(groupID: "group", userID: "alice")?.role == .owner)
            let changed = try await store.setReaction(
                messageID: original.id, userID: "alice", reaction: reaction, added: true)
            #expect(changed?.reactions.first?.reaction == reaction)
        }
        let reopened = try ReiStore(path: url.path)
        let loaded = try #require(try await reopened.message(id: "old-message"))
        #expect(loaded.reactions == [MessageReaction(reaction: reaction, userIDs: ["alice"])])
        let next = try await reopened.append(
            Message(
                scene: .group, peerID: "group", senderID: "alice", selfID: "bot", content: [.text("new")],
                direction: .outgoing
            ))
        #expect(next.seq == 8)
    }

    @MainActor
    private func seedV1(at url: URL) throws {
        let schema = Schema(versionedSchema: ReiSchemaV1.self)
        let config = ModelConfiguration("Rei", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        context.insert(
            ReiSchemaV1.UserRecord(
                id: "alice", name: "Alice", nickname: "", avatar: nil, sex: "unknown", age: nil, sign: "",
                createdAt: .now
            ))
        context.insert(
            ReiSchemaV1.GroupMemberRecord(
                id: StorageIdentity.groupMember(groupID: "group", userID: "alice"), groupID: "group", userID: "alice",
                card: "", role: "owner", title: "",
                joinedAt: .now, lastSentAt: nil, mutedUntil: nil
            ))
        context.insert(
            ReiSchemaV1.MessageRecord(
                id: "old-message", seq: 7, scene: "group", peerID: "group", senderID: "alice", selfID: "bot",
                content: try JSONEncoder().encode([MessageSegment.text("Saved before reactions")]),
                time: .now, direction: "outgoing", recalledAt: nil, recalledBy: nil
            ))
        try context.save()
    }
}
