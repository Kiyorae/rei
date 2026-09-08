import Foundation
import ReiCore

extension PlatformService {
    public func setPeerPin(in chat: Chat, isPinned: Bool) async throws {
        try await requireParticipant(chat.selfID, in: chat)
        guard try await store.setPinned(isPinned, in: chat) else { return }
        publish(DomainEvent(selfID: chat.selfID, payload: .peerPinChanged(chat: chat, isPinned: isPinned)))
    }

    public func markRead(in chat: Chat, through sequence: Int64) async throws {
        try await requireParticipant(chat.selfID, in: chat)
        guard sequence > 0,
            let target = try await store.message(
                scene: chat.scene, peerID: chat.peerID, seq: sequence, selfID: chat.selfID)
        else {
            throw PlatformError.messageNotFound("\(chat.id):\(sequence)")
        }
        try await store.markRead(in: chat, through: sequence, expectedMessageID: target.id)
    }

    @discardableResult
    public func likeProfile(userID: String, operatorID: String, count: Int, dailyLimit: Int? = nil) async throws
        -> ProfileLike
    {
        guard count > 0, count <= Int32.max else {
            throw PlatformError.invalidParameter("count must be a positive int32")
        }
        for id in [userID, operatorID] {
            guard try await store.user(id: id) != nil else { throw PlatformError.userNotFound(id) }
        }
        guard userID != operatorID else { throw PlatformError.notPermitted("You cannot like your own profile") }
        guard
            let result = try await store.addProfileLikes(
                userID: userID, operatorID: operatorID, count: Int64(count), dailyLimit: dailyLimit.map(Int64.init))
        else {
            throw PlatformError.notPermitted("The daily profile-like limit has been reached")
        }
        return result
    }

    @discardableResult
    public func postAnnouncement(groupID: String, operatorID: String, content: String, image: Asset? = nil) async throws
        -> GroupAnnouncement
    {
        try await requireGroupAdministrator(operatorID, groupID: groupID)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil else {
            throw PlatformError.invalidParameter("An announcement needs text or an image")
        }
        let announcement = GroupAnnouncement(groupID: groupID, senderID: operatorID, content: content, image: image)
        try await store.save(announcement)
        return announcement
    }

    public func deleteAnnouncement(id: String, groupID: String, operatorID: String) async throws {
        try await requireGroupAdministrator(operatorID, groupID: groupID)
        guard try await store.deleteAnnouncement(id: id, groupID: groupID) else {
            throw PlatformError.invalidParameter("Announcement not found in this group")
        }
    }

    public func setMessageEssence(messageID: String, operatorID: String, isSet: Bool) async throws {
        guard let message = try await store.message(id: messageID), message.scene == .group, !message.isRecalled else {
            throw PlatformError.messageNotFound(messageID)
        }
        try await requireGroupAdministrator(operatorID, groupID: message.peerID)
        guard
            try await store.setEssence(
                MessageEssence(messageID: messageID, chat: message.chat, operatorID: operatorID), isSet: isSet)
        else { return }
        publish(
            DomainEvent(
                selfID: message.selfID,
                payload: .messageEssenceChanged(.init(message: message, operatorID: operatorID, isSet: isSet))),
            origin: operatorID)
    }

    @discardableResult
    public func shareFile(
        in chat: Chat, operatorID: String, asset: Asset, name: String, folderID: String = "/", fileHash: String = ""
    ) async throws -> SharedFile {
        try await requireParticipant(operatorID, in: chat)
        let name = try validatedEntryName(name)
        guard chat.scene != .temp else {
            throw PlatformError.notPermitted("Files require a group or friend conversation")
        }
        if chat.scene == .group {
            try await requireFolder(folderID, groupID: chat.peerID)
        } else if fileHash.isEmpty {
            throw PlatformError.invalidParameter("Private files require a content fingerprint")
        }
        let file = SharedFile(
            chat: chat, name: name, folderID: folderID, asset: asset, uploaderID: operatorID, fileHash: fileHash)
        if try await store.asset(id: asset.id) == nil { try await store.save(asset) }
        try await store.save(file)
        if chat.scene == .group {
            var namedAsset = asset
            namedAsset.name = name
            try await publishToGroupBots(
                groupID: chat.peerID,
                payload: .groupFileUploaded(
                    .init(groupID: chat.peerID, userID: operatorID, asset: namedAsset, fileID: file.id)),
                origin: operatorID)
        } else {
            publish(
                DomainEvent(selfID: chat.selfID, payload: .privateFileUploaded(.init(file: file))), origin: operatorID)
        }
        return file
    }

    public func groupFile(id: String, groupID: String, operatorID: String) async throws -> SharedFile {
        try await requireGroupMember(operatorID, groupID: groupID)
        guard let file = try await store.sharedFile(id: id), file.chat.scene == .group, file.chat.peerID == groupID,
            !file.isExpired
        else {
            throw PlatformError.invalidParameter("File not found in this group")
        }
        return file
    }

    /// Records a successful request to retrieve a shared file. Transport failures
    /// after issuing a URL are outside the platform's download-request counter.
    public func downloadSharedFile(id: String, in chat: Chat, operatorID: String) async throws -> SharedFile {
        try await requireParticipant(operatorID, in: chat)
        guard let file = try await store.sharedFile(id: id), !file.isExpired,
            file.chat.scene == chat.scene, file.chat.peerID == chat.peerID,
            chat.scene == .group || file.chat.selfID == chat.selfID
        else { throw PlatformError.invalidParameter("File not found in this conversation") }
        guard let updated = try await store.recordFileDownload(id: id) else {
            throw PlatformError.invalidParameter("File is no longer available")
        }
        return updated
    }

    public func moveGroupFile(
        id: String, groupID: String, from folderID: String, to targetFolderID: String, operatorID: String
    ) async throws {
        let file = try await editableGroupFile(id: id, groupID: groupID, operatorID: operatorID)
        guard file.folderID == folderID else {
            throw PlatformError.invalidParameter("File is not in the supplied parent folder")
        }
        try await requireFolder(targetFolderID, groupID: groupID)
        try await store.editSharedFile(
            id: id, groupID: groupID, edit: .move(parentFolderID: folderID, targetFolderID: targetFolderID))
    }

    public func renameGroupFile(id: String, groupID: String, folderID: String, name: String, operatorID: String)
        async throws
    {
        let file = try await editableGroupFile(id: id, groupID: groupID, operatorID: operatorID)
        guard file.folderID == folderID else {
            throw PlatformError.invalidParameter("File is not in the supplied parent folder")
        }
        try await store.editSharedFile(
            id: id, groupID: groupID, edit: .rename(name: validatedEntryName(name), parentFolderID: folderID))
    }

    public func deleteGroupFile(id: String, groupID: String, operatorID: String) async throws {
        let file = try await editableGroupFile(id: id, groupID: groupID, operatorID: operatorID)
        try await store.deleteSharedFile(id: file.id)
    }

    public func persistGroupFile(id: String, groupID: String, operatorID: String) async throws {
        let file = try await editableGroupFile(id: id, groupID: groupID, operatorID: operatorID)
        try await store.editSharedFile(id: file.id, groupID: groupID, edit: .makePermanent)
    }

    @discardableResult
    public func createGroupFolder(groupID: String, name: String, operatorID: String) async throws -> GroupFolder {
        try await requireGroupAdministrator(operatorID, groupID: groupID)
        let name = try validatedEntryName(name)
        guard try await !store.folders(groupID: groupID).contains(where: { $0.name == name }) else {
            throw PlatformError.alreadyExists("A folder with this name already exists")
        }
        let folder = GroupFolder(groupID: groupID, name: name, creatorID: operatorID)
        try await store.save(folder)
        return folder
    }

    public func renameGroupFolder(id: String, groupID: String, name: String, operatorID: String) async throws {
        try await requireGroupAdministrator(operatorID, groupID: groupID)
        guard try await store.folders(groupID: groupID).contains(where: { $0.id == id }) else {
            throw PlatformError.invalidParameter("Folder not found in this group")
        }
        let name = try validatedEntryName(name)
        guard try await !store.folders(groupID: groupID).contains(where: { $0.name == name && $0.id != id }) else {
            throw PlatformError.alreadyExists("A folder with this name already exists")
        }
        try await store.renameFolder(id: id, groupID: groupID, name: name)
    }

    public func deleteGroupFolder(id: String, groupID: String, operatorID: String) async throws {
        try await requireGroupAdministrator(operatorID, groupID: groupID)
        guard id != "/" else { throw PlatformError.notPermitted("The root folder cannot be removed") }
        try await requireFolder(id, groupID: groupID)
        try await store.deleteFolder(id: id, groupID: groupID)
    }

    func requireParticipant(_ userID: String, in chat: Chat) async throws {
        guard try await store.user(id: chat.selfID) != nil else { throw PlatformError.userNotFound(chat.selfID) }
        if chat.scene == .group {
            try await requireGroupMember(userID, groupID: chat.peerID)
        } else {
            guard try await store.user(id: chat.peerID) != nil else { throw PlatformError.userNotFound(chat.peerID) }
            guard chat.counterpartID(for: userID) != nil else {
                throw PlatformError.notPermitted("User is not a participant in this conversation")
            }
        }
    }

    func requireGroupMember(_ userID: String, groupID: String) async throws {
        guard try await store.group(id: groupID) != nil else { throw PlatformError.groupNotFound(groupID) }
        guard try await store.member(groupID: groupID, userID: userID) != nil else {
            throw PlatformError.notAMember(groupID: groupID, userID: userID)
        }
    }

    private func requireGroupAdministrator(_ userID: String, groupID: String) async throws {
        try await requireGroupMember(userID, groupID: groupID)
        guard let member = try await store.member(groupID: groupID, userID: userID), member.role > .member else {
            throw PlatformError.notPermitted("Administrator privileges are required")
        }
    }

    private func editableGroupFile(id: String, groupID: String, operatorID: String) async throws -> SharedFile {
        let file = try await groupFile(id: id, groupID: groupID, operatorID: operatorID)
        if file.uploaderID != operatorID { try await requireGroupAdministrator(operatorID, groupID: groupID) }
        return file
    }

    private func requireFolder(_ id: String, groupID: String) async throws {
        if id == "/" { return }
        guard try await store.folders(groupID: groupID).contains(where: { $0.id == id }) else {
            throw PlatformError.invalidParameter("Folder not found in this group")
        }
    }

    private func validatedEntryName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\\"),
            !trimmed.contains("\0")
        else {
            throw PlatformError.invalidParameter("Use a nonempty file or folder name without path separators")
        }
        return trimmed
    }
}
