import Foundation
import ReiCore
import ReiProtocol
import Testing

@testable import ReiLogging
@testable import ReiUI

@Suite("Conversation Management", .serialized)
@MainActor
struct ConversationManagementTests {
    @Test("V11 and Milky expose group profiles and requests; V12 has neither standard contract")
    func protocolCapabilities() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        for choice in ProtocolChoice.allCases {
            fixture.environment.selectedProtocol = choice
            #expect(fixture.environment.supportsGroupProfiles == (choice != .oneBotV12))
            #expect(fixture.environment.supportsRequestEvents == (choice != .oneBotV12))
        }
    }

    @Test("Group profile permissions distinguish self card, lower role card, and owner titles")
    func profilePermissions() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try await seed(fixture.environment)
        let environment = fixture.environment
        let chat = groupChat
        let owner = try #require(environment.members[.init(groupID: "group", userID: "owner")])
        let member = try #require(environment.members[.init(groupID: "group", userID: "member")])

        environment.activeUserID = "member"
        #expect(!environment.canRenameGroup(in: chat))
        #expect(environment.canEditMemberCard(member, in: chat))
        #expect(!environment.canEditMemberCard(owner, in: chat))
        #expect(!environment.canEditMemberTitle(member, in: chat))

        environment.activeUserID = "owner"
        #expect(environment.canRenameGroup(in: chat))
        #expect(environment.canEditMemberCard(member, in: chat))
        #expect(environment.canEditMemberTitle(owner, in: chat))
        environment.selectedProtocol = .oneBotV12
        #expect(!environment.canRenameGroup(in: chat))
        #expect(!environment.canEditMemberCard(member, in: chat))
        #expect(!environment.canEditMemberTitle(member, in: chat))
    }

    @Test("Profile edits use the selected actor and persist the fields read by protocol APIs")
    func profileEdits() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try await seed(fixture.environment)
        let environment = fixture.environment
        environment.activeUserID = "owner"
        try await environment.renameGroup(in: groupChat, name: " Renamed ")
        try await environment.editMemberCard("member", in: groupChat, card: "Display Name")
        try await environment.editMemberTitle("member", in: groupChat, title: "Expert")
        #expect(try await environment.store.group(id: "group")?.name == "Renamed")
        #expect(try await environment.store.member(groupID: "group", userID: "member")?.card == "Display Name")
        #expect(try await environment.store.member(groupID: "group", userID: "member")?.title == "Expert")

        environment.activeUserID = "member"
        await #expect(throws: PlatformError.self) {
            try await environment.renameGroup(in: groupChat, name: "Refused")
        }
        await #expect(throws: PlatformError.self) {
            try await environment.editMemberTitle("member", in: groupChat, title: "Refused")
        }
        try await environment.editMemberCard("member", in: groupChat, card: "")
        #expect(try await environment.store.member(groupID: "group", userID: "member")?.card == "")
    }

    @Test("Requests persist pending friend and join requests without accepting them")
    func incomingRequests() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try await seed(fixture.environment)
        let environment = fixture.environment
        environment.activeUserID = "outsider"
        let chat = Chat(scene: .temp, peerID: "outsider", selfID: "bot")
        #expect(environment.canSendFriendRequest(in: chat))
        #expect(environment.canRequestToJoinGroup(in: groupChat))
        let friend = try await environment.sendFriendRequest(in: chat, comment: "Hello")
        let join = try await environment.requestToJoinGroup(in: groupChat, comment: "Let me join")
        #expect(friend.kind == .friend && friend.requesterID == "outsider" && friend.selfID == "bot")
        #expect(friend.comment == "Hello" && friend.resolution == nil)
        #expect(join.kind == .groupJoin && join.groupID == "group" && join.selfID == "bot")
        #expect(join.resolution == nil)
        #expect(try await environment.store.friendship(userID: "bot", friendID: "outsider") == nil)
        #expect(try await environment.store.member(groupID: "group", userID: "outsider") == nil)
        await #expect(throws: PlatformError.self) {
            try await environment.sendFriendRequest(in: chat, comment: "Duplicate")
        }
        await #expect(throws: PlatformError.self) {
            try await environment.requestToJoinGroup(in: groupChat, comment: "Duplicate")
        }
    }

    @Test("Invitation targets the absent bot and requires the active persona to belong to the group")
    func groupInvitation() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try await seed(fixture.environment)
        let environment = fixture.environment
        try await environment.store.removeMember(groupID: "group", userID: "bot")
        _ = try await environment.groupMembers(in: "group")
        environment.activeUserID = "member"
        #expect(environment.canInviteBotToGroup(in: groupChat))
        let request = try await environment.inviteBotToGroup(in: groupChat, comment: "Join us")
        #expect(request.kind == .groupInvite && request.requesterID == "member" && request.selfID == "bot")
        #expect(try await environment.store.member(groupID: "group", userID: "bot") == nil)
        environment.activeUserID = "outsider"
        #expect(!environment.canInviteBotToGroup(in: groupChat))
        await #expect(throws: PlatformError.self) {
            try await environment.inviteBotToGroup(in: groupChat, comment: "Refused")
        }
    }

    @Test("Unsupported protocols and mismatched bot scopes reject mutations before storage changes")
    func requestScope() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try await seed(fixture.environment)
        let environment = fixture.environment
        environment.activeUserID = "outsider"
        environment.selectedProtocol = .oneBotV12
        await #expect(throws: PlatformError.self) {
            try await environment.sendFriendRequest(
                in: Chat(scene: .temp, peerID: "outsider", selfID: "bot"), comment: "Refused")
        }
        environment.selectedProtocol = .milky
        await #expect(throws: PlatformError.self) {
            try await environment.requestToJoinGroup(
                in: Chat(scene: .group, peerID: "group", selfID: "other-bot"), comment: "Refused")
        }
        #expect(try await environment.store.pendingRequests(selfID: "bot").isEmpty)
    }

    @Test("Platform request boundaries reject absent identities, outsiders, and existing members")
    func platformRequestValidation() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try await seed(fixture.environment)
        let platform = fixture.environment.platform
        await #expect(throws: PlatformError.self) {
            try await platform.requestFriend(requesterID: "bot", targetID: "bot")
        }
        await #expect(throws: PlatformError.self) {
            try await platform.requestJoinGroup(groupID: "group", requesterID: "missing", targetBotID: "bot")
        }
        await #expect(throws: PlatformError.self) {
            try await platform.requestJoinGroup(groupID: "group", requesterID: "outsider", targetBotID: "missing")
        }
        await #expect(throws: PlatformError.self) {
            try await platform.requestJoinGroup(groupID: "group", requesterID: "member", targetBotID: "bot")
        }
        await #expect(throws: PlatformError.self) {
            try await platform.inviteToGroup(groupID: "group", inviterID: "outsider", inviteeID: "bot")
        }
        await #expect(throws: PlatformError.self) {
            try await platform.inviteToGroup(groupID: "group", inviterID: "member", inviteeID: "bot")
        }
        await #expect(throws: PlatformError.self) {
            try await platform.inviteToGroup(groupID: "group", inviterID: "member", inviteeID: "missing")
        }
        #expect(try await fixture.environment.store.pendingRequests(selfID: "bot").isEmpty)
    }

    private var groupChat: Chat { Chat(scene: .group, peerID: "group", selfID: "bot") }

    private func seed(_ environment: AppEnvironment) async throws {
        for id in ["owner", "bot", "member", "outsider"] {
            try await environment.store.save(User(id: id, name: id))
        }
        try await environment.store.save(ReiCore.Group(id: "group", name: "Group"))
        for (id, role) in [("owner", GroupMember.Role.owner), ("bot", .admin), ("member", .member)] {
            try await environment.store.save(GroupMember(groupID: "group", userID: id, role: role))
        }
        for _ in 0..<100 where environment.users.count < 4 { await Task.yield() }
        _ = await environment.setBotUser("bot")
        environment.selectedProtocol = .milky
        environment.friendshipsAreLoaded = true
        _ = try await environment.groupMembers(in: "group")
    }

    private func fixture() throws -> ManagementFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Rei-Management-\(UUID())")
        let defaultsName = "dev.rei.tests.management.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        return ManagementFixture(
            root: root, defaultsName: defaultsName, defaults: defaults,
            environment: AppEnvironment(
                store: try ReiStore(), assetStore: try AssetStore(directory: root.appendingPathComponent("Assets")),
                appLog: AppLog(directory: root, emitUnifiedLog: false), defaults: defaults))
    }
}

@MainActor
private struct ManagementFixture {
    let root: URL
    let defaultsName: String
    let defaults: UserDefaults
    let environment: AppEnvironment

    func remove() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
