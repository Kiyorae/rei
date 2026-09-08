import Foundation
import ReiCore
import ReiLogging
import ReiProtocol

extension AppEnvironment {
    var supportsGroupProfiles: Bool { effectiveProtocol != .oneBotV12 }
    var supportsRequestEvents: Bool { effectiveProtocol != .oneBotV12 }

    func canRenameGroup(in chat: Chat) -> Bool {
        guard supportsGroupProfiles, canInteract(in: chat), chat.scene == .group, let activeUserID else { return false }
        return role(of: activeUserID, in: chat.peerID).map { $0 > .member } ?? false
    }

    func canEditMemberCard(_ member: GroupMember, in chat: Chat) -> Bool {
        guard supportsGroupProfiles, canInteract(in: chat), chat.scene == .group,
            member.groupID == chat.peerID, let activeUserID
        else { return false }
        return activeUserID == member.userID || canRemoveGroupMember(member, from: chat.peerID)
    }

    func canEditMemberTitle(_ member: GroupMember, in chat: Chat) -> Bool {
        guard supportsGroupProfiles, canInteract(in: chat), chat.scene == .group,
            member.groupID == chat.peerID, let activeUserID
        else { return false }
        return role(of: activeUserID, in: chat.peerID) == .owner
    }

    func canSendFriendRequest(in chat: Chat) -> Bool {
        supportsRequestEvents && canManageConversation(chat) && chat.scene.isPrivate
            && chat.peerID == activeUserID && activeUserID != botUserID && !isFriend(chat.peerID)
    }

    func canRequestToJoinGroup(in chat: Chat) -> Bool {
        guard supportsRequestEvents, canManageConversation(chat), chat.scene == .group,
            let activeUserID, activeUserID != botUserID
        else { return false }
        return role(of: activeUserID, in: chat.peerID) == nil
    }

    func canInviteBotToGroup(in chat: Chat) -> Bool {
        guard supportsRequestEvents, canManageConversation(chat), chat.scene == .group,
            let activeUserID, let botUserID, activeUserID != botUserID
        else { return false }
        return role(of: activeUserID, in: chat.peerID) != nil && role(of: botUserID, in: chat.peerID) == nil
    }

    func renameGroup(in chat: Chat, name: String) async throws {
        try await performThrowing(.renameGroup) {
            let actor = try self.managementActor(in: chat, groupProfile: true)
            try await self.platform.setGroupName(groupID: chat.peerID, operatorID: actor, name: name)
        }
    }

    func editMemberCard(_ userID: User.ID, in chat: Chat, card: String) async throws {
        try await performThrowing(.setMemberCard) {
            let actor = try self.managementActor(in: chat, groupProfile: true)
            try await self.platform.setMemberCard(groupID: chat.peerID, userID: userID, operatorID: actor, card: card)
        }
        _ = try await groupMembers(in: chat.peerID)
    }

    func editMemberTitle(_ userID: User.ID, in chat: Chat, title: String) async throws {
        try await performThrowing(.setMemberTitle) {
            let actor = try self.managementActor(in: chat, groupProfile: true)
            try await self.platform.setMemberTitle(
                groupID: chat.peerID, userID: userID, operatorID: actor, title: title)
        }
        _ = try await groupMembers(in: chat.peerID)
    }

    @discardableResult
    func sendFriendRequest(in chat: Chat, comment: String) async throws -> PendingRequest {
        try await performThrowing(.requestFriend) {
            let actor = try self.managementActor(in: chat)
            guard chat.scene.isPrivate, chat.peerID == actor, actor != chat.selfID else {
                throw PlatformError.notPermitted("Select a persona speaking to the bot to send a friend request")
            }
            return try await self.platform.requestFriend(requesterID: actor, targetID: chat.selfID, comment: comment)
        }
    }

    @discardableResult
    func requestToJoinGroup(in chat: Chat, comment: String) async throws -> PendingRequest {
        try await performThrowing(.requestGroupJoin) {
            let actor = try self.managementActor(in: chat)
            guard chat.scene == .group, actor != chat.selfID else {
                throw PlatformError.notPermitted("Select a persona to request admission from the bot")
            }
            return try await self.platform.requestJoinGroup(
                groupID: chat.peerID, requesterID: actor, targetBotID: chat.selfID, comment: comment)
        }
    }

    @discardableResult
    func inviteBotToGroup(in chat: Chat, comment: String) async throws -> PendingRequest {
        try await performThrowing(.inviteBotToGroup) {
            let actor = try self.managementActor(in: chat)
            guard chat.scene == .group, actor != chat.selfID else {
                throw PlatformError.notPermitted("Select a group member to invite the bot")
            }
            return try await self.platform.inviteToGroup(
                groupID: chat.peerID, inviterID: actor, inviteeID: chat.selfID, comment: comment)
        }
    }

    private func canManageConversation(_ chat: Chat) -> Bool {
        canSubmitMessages && activeUserID != nil && chat.selfID == botUserID
            && (activeBotUserID == nil || activeBotUserID == chat.selfID)
    }

    private func managementActor(in chat: Chat, groupProfile: Bool = false) throws -> User.ID {
        guard canManageConversation(chat), let activeUserID else {
            throw PlatformError.notPermitted("Select a sending identity and wait for the matching bot connection")
        }
        guard groupProfile ? supportsGroupProfiles && chat.scene == .group : supportsRequestEvents else {
            throw PlatformError.notPermitted("This operation is unavailable with the current protocol")
        }
        return activeUserID
    }

}
