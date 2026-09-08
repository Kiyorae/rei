import Foundation
import SwiftData

extension ReiStore {
    public func conversationState(in chat: Chat) async throws -> ConversationState {
        try await executor.conversationState(in: chat)
    }
    public func conversationStates(selfID: String) async throws -> [ConversationState] {
        try await executor.conversationStates(selfID: selfID)
    }
    public func setPinned(_ pinned: Bool, in chat: Chat) async throws -> Bool {
        try await executor.setPinned(pinned, in: chat)
    }
    public func markRead(in chat: Chat, through sequence: Int64, expectedMessageID: String? = nil) async throws {
        try await executor.markRead(in: chat, through: sequence, expectedMessageID: expectedMessageID)
    }
    public func addProfileLikes(userID: String, operatorID: String, count: Int64, dailyLimit: Int64? = nil) async throws
        -> ProfileLike?
    {
        try await executor.addProfileLikes(userID: userID, operatorID: operatorID, count: count, dailyLimit: dailyLimit)
    }
    public func profileLikes(userID: String) async throws -> [ProfileLike] {
        try await executor.profileLikes(userID: userID)
    }
    public func save(_ announcement: GroupAnnouncement) async throws { try await executor.save(announcement) }
    public func announcements(groupID: String) async throws -> [GroupAnnouncement] {
        try await executor.announcements(groupID: groupID)
    }
    public func deleteAnnouncement(id: String, groupID: String) async throws -> Bool {
        try await executor.deleteAnnouncement(id: id, groupID: groupID)
    }
    public func setEssence(_ essence: MessageEssence, isSet: Bool) async throws -> Bool {
        try await executor.setEssence(essence, isSet: isSet)
    }
    public func essences(in chat: Chat) async throws -> [MessageEssence] {
        try await executor.essences(in: chat)
    }
    public func save(_ file: SharedFile) async throws { try await executor.save(file) }
    public func sharedFile(id: String) async throws -> SharedFile? { try await executor.sharedFile(id: id) }
    public func sharedFiles(in chat: Chat, folderID: String? = nil) async throws -> [SharedFile] {
        try await executor.sharedFiles(in: chat, folderID: folderID)
    }
    public func deleteSharedFile(id: String) async throws { try await executor.deleteSharedFile(id: id) }
    public func recordFileDownload(id: String) async throws -> SharedFile? {
        try await executor.recordFileDownload(id: id)
    }
    public func editSharedFile(id: String, groupID: String, edit: SharedFileEdit) async throws {
        try await executor.editSharedFile(id: id, groupID: groupID, edit: edit)
    }
    public func renameFolder(id: String, groupID: String, name: String) async throws {
        try await executor.renameFolder(id: id, groupID: groupID, name: name)
    }
    public func save(_ folder: GroupFolder) async throws { try await executor.save(folder) }
    public func folders(groupID: String) async throws -> [GroupFolder] { try await executor.folders(groupID: groupID) }
    public func deleteFolder(id: String, groupID: String) async throws {
        try await executor.deleteFolder(id: id, groupID: groupID)
    }
}

extension StoreExecutor {
    func deleteGroupFeatures(groupID: String) throws {
        for record in try modelContext.fetch(
            FetchDescriptor<AnnouncementRecord>(predicate: #Predicate { $0.groupID == groupID }))
        { modelContext.delete(record) }
        for record in try modelContext.fetch(
            FetchDescriptor<EssenceRecord>(predicate: #Predicate { $0.groupID == groupID }))
        { modelContext.delete(record) }
        for record in try modelContext.fetch(
            FetchDescriptor<GroupFolderRecord>(predicate: #Predicate { $0.groupID == groupID }))
        { modelContext.delete(record) }
        for record in try modelContext.fetch(
            FetchDescriptor<SharedFileRecord>(predicate: #Predicate { $0.scene == "group" && $0.peerID == groupID }))
        { modelContext.delete(record) }
        for record in try modelContext.fetch(FetchDescriptor<ConversationStateRecord>()) {
            let state = try PersistenceCodec.decode(ConversationState.self, from: record.payload)
            if state.chat.scene == .group && state.chat.peerID == groupID { modelContext.delete(record) }
        }
    }

    func deleteUserFeatures(userID: String) throws {
        for record in try modelContext.fetch(
            FetchDescriptor<ProfileLikeRecord>(predicate: #Predicate { $0.userID == userID || $0.operatorID == userID })
        ) { modelContext.delete(record) }
        for record in try modelContext.fetch(
            FetchDescriptor<EssenceRecord>(predicate: #Predicate { $0.selfID == userID }))
        { modelContext.delete(record) }
        for record in try modelContext.fetch(
            FetchDescriptor<SharedFileRecord>(
                predicate: #Predicate { $0.scene != "group" && ($0.selfID == userID || $0.peerID == userID) }))
        { modelContext.delete(record) }
        for record in try modelContext.fetch(FetchDescriptor<ConversationStateRecord>()) {
            let state = try PersistenceCodec.decode(ConversationState.self, from: record.payload)
            if state.chat.selfID == userID || (state.chat.scene != .group && state.chat.peerID == userID) {
                modelContext.delete(record)
            }
        }
    }

    func removeEssence(messageID: String) throws {
        for record in try modelContext.fetch(
            FetchDescriptor<EssenceRecord>(predicate: #Predicate { $0.id == messageID }))
        { modelContext.delete(record) }
    }

    func resetReadMarker(in chat: Chat) throws {
        var state = try conversationState(in: chat)
        if state.lastReadSequence != 0 {
            state.lastReadSequence = 0
            try saveConversationState(state)
        }
    }
    func conversationState(in chat: Chat) throws -> ConversationState {
        let id = chat.id
        let record = try modelContext.fetch(
            FetchDescriptor<ConversationStateRecord>(predicate: #Predicate { $0.id == id })
        ).first
        return try record.map { try PersistenceCodec.decode(ConversationState.self, from: $0.payload) }
            ?? ConversationState(chat: chat)
    }

    func conversationStates(selfID: String) throws -> [ConversationState] {
        try modelContext.fetch(FetchDescriptor<ConversationStateRecord>(predicate: #Predicate { $0.selfID == selfID }))
            .map { try PersistenceCodec.decode(ConversationState.self, from: $0.payload) }
    }

    private func saveConversationState(_ state: ConversationState) throws {
        let id = state.chat.id
        let data = try PersistenceCodec.encode(state)
        if let record = try modelContext.fetch(
            FetchDescriptor<ConversationStateRecord>(predicate: #Predicate { $0.id == id })
        ).first {
            record.payload = data
        } else {
            modelContext.insert(ConversationStateRecord(id: id, selfID: state.chat.selfID, payload: data))
        }
        try modelContext.save()
        publish([.chatState, .conversations])
    }

    func setPinned(_ pinned: Bool, in chat: Chat) throws -> Bool {
        guard try userRecord(id: chat.selfID) != nil else {
            throw StoreMutationError.missingTarget("The bot account no longer exists")
        }
        if chat.scene == .group {
            guard try groupRecord(id: chat.peerID) != nil else {
                throw StoreMutationError.missingTarget("The group no longer exists")
            }
        } else {
            guard try userRecord(id: chat.peerID) != nil else {
                throw StoreMutationError.missingTarget("The peer no longer exists")
            }
        }
        var state = try conversationState(in: chat)
        guard state.isPinned != pinned else { return false }
        state.isPinned = pinned
        try saveConversationState(state)
        return true
    }

    func markRead(in chat: Chat, through sequence: Int64, expectedMessageID: String?) throws {
        guard let target = try message(scene: chat.scene, peerID: chat.peerID, seq: sequence, selfID: chat.selfID),
            expectedMessageID == nil || target.id == expectedMessageID
        else {
            throw StoreMutationError.missingTarget("The read target is no longer in this conversation")
        }
        var state = try conversationState(in: chat)
        guard state.lastReadSequence < sequence else { return }
        state.lastReadSequence = sequence
        try saveConversationState(state)
    }

    func addProfileLikes(userID: String, operatorID: String, count: Int64, dailyLimit: Int64?) throws -> ProfileLike? {
        let record = try modelContext.fetch(
            FetchDescriptor<ProfileLikeRecord>(
                predicate: #Predicate {
                    $0.userID == userID && $0.operatorID == operatorID
                })
        ).first
        let (total, overflow) = (record?.count ?? 0).addingReportingOverflow(count)
        guard !overflow, count > 0 else {
            throw StorePersistenceError.invalidRawValue(type: "ProfileLike.count", value: String(count))
        }
        let now = Date.now
        let sameDay =
            record.map { Int64($0.updatedAt.timeIntervalSince1970 / 86400) == Int64(now.timeIntervalSince1970 / 86400) }
            ?? false
        let daily = (sameDay ? record?.dailyCount ?? 0 : 0) + count
        if let dailyLimit, daily > dailyLimit { return nil }
        let value = ProfileLike(userID: userID, operatorID: operatorID, count: total, dailyCount: daily, updatedAt: now)
        if let record {
            record.count = total
            record.dailyCount = daily
            record.updatedAt = value.updatedAt
        } else {
            let record = ProfileLikeRecord(
                id: UUID().uuidString, userID: userID, operatorID: operatorID, count: total, updatedAt: value.updatedAt)
            record.dailyCount = daily
            modelContext.insert(record)
        }
        try modelContext.save()
        publish(.profileLikes)
        return value
    }

    func profileLikes(userID: String) throws -> [ProfileLike] {
        try modelContext.fetch(FetchDescriptor<ProfileLikeRecord>(predicate: #Predicate { $0.userID == userID }))
            .map {
                ProfileLike(
                    userID: $0.userID, operatorID: $0.operatorID, count: $0.count, dailyCount: $0.dailyCount,
                    updatedAt: $0.updatedAt)
            }
    }

    func save(_ announcement: GroupAnnouncement) throws {
        let id = announcement.id
        let data = try PersistenceCodec.encode(announcement)
        if let record = try modelContext.fetch(
            FetchDescriptor<AnnouncementRecord>(predicate: #Predicate { $0.id == id })
        ).first {
            record.payload = data
        } else {
            modelContext.insert(
                AnnouncementRecord(id: id, groupID: announcement.groupID, time: announcement.time, payload: data))
        }
        try modelContext.save()
        publish(.groupContent)
    }

    func announcements(groupID: String) throws -> [GroupAnnouncement] {
        try modelContext.fetch(
            FetchDescriptor<AnnouncementRecord>(
                predicate: #Predicate { $0.groupID == groupID }, sortBy: [SortDescriptor(\.time, order: .reverse)])
        )
        .map { try PersistenceCodec.decode(GroupAnnouncement.self, from: $0.payload) }
    }

    func deleteAnnouncement(id: String, groupID: String) throws -> Bool {
        guard
            let record = try modelContext.fetch(
                FetchDescriptor<AnnouncementRecord>(predicate: #Predicate { $0.id == id && $0.groupID == groupID })
            ).first
        else { return false }
        modelContext.delete(record)
        try modelContext.save()
        publish(.groupContent)
        return true
    }

    func setEssence(_ essence: MessageEssence, isSet: Bool) throws -> Bool {
        let id = essence.messageID
        if isSet {
            guard let message = try message(id: id), !message.isRecalled, message.chat == essence.chat else {
                throw StoreMutationError.missingTarget("The highlight target is no longer available")
            }
        }
        let record = try modelContext.fetch(FetchDescriptor<EssenceRecord>(predicate: #Predicate { $0.id == id })).first
        guard (record != nil) != isSet else { return false }
        if let record {
            modelContext.delete(record)
        } else {
            modelContext.insert(
                EssenceRecord(
                    id: id, groupID: essence.chat.peerID, selfID: essence.chat.selfID, time: essence.time,
                    payload: try PersistenceCodec.encode(essence)))
        }
        try modelContext.save()
        publish(.groupContent)
        return true
    }

    func essences(in chat: Chat) throws -> [MessageEssence] {
        guard chat.scene == .group else { return [] }
        let groupID = chat.peerID
        let selfID = chat.selfID
        return try modelContext.fetch(
            FetchDescriptor<EssenceRecord>(
                predicate: #Predicate { $0.groupID == groupID && $0.selfID == selfID },
                sortBy: [SortDescriptor(\.time, order: .reverse)])
        )
        .compactMap { record in
            guard let message = try message(id: record.id), !message.isRecalled else { return nil }
            return try PersistenceCodec.decode(MessageEssence.self, from: record.payload)
        }
    }

    func save(_ file: SharedFile) throws {
        let id = file.id
        let data = try PersistenceCodec.encode(file)
        if let record = try modelContext.fetch(FetchDescriptor<SharedFileRecord>(predicate: #Predicate { $0.id == id }))
            .first
        {
            record.folderID = file.folderID
            record.payload = data
        } else {
            if file.chat.scene == .group {
                guard try groupRecord(id: file.chat.peerID) != nil else {
                    throw StoreMutationError.missingTarget("The group no longer exists")
                }
                try validateStoredFolder(file.folderID, groupID: file.chat.peerID)
            }
            modelContext.insert(
                SharedFileRecord(
                    id: id, scene: file.chat.scene.rawValue, peerID: file.chat.peerID, selfID: file.chat.selfID,
                    folderID: file.folderID, assetID: file.asset.id, time: file.uploadedAt, payload: data))
        }
        try touchStoredFolder(file.folderID, groupID: file.chat.peerID)
        try modelContext.save()
        publish(.files)
    }

    func sharedFile(id: String) throws -> SharedFile? {
        try modelContext.fetch(FetchDescriptor<SharedFileRecord>(predicate: #Predicate { $0.id == id })).first
            .map { try PersistenceCodec.decode(SharedFile.self, from: $0.payload) }
    }

    func sharedFiles(in chat: Chat, folderID: String?) throws -> [SharedFile] {
        let scene = chat.scene.rawValue
        let peerID = chat.peerID
        let selfID = chat.selfID
        let isGroup = chat.scene == .group
        return try modelContext.fetch(
            FetchDescriptor<SharedFileRecord>(
                predicate: #Predicate {
                    $0.scene == scene && $0.peerID == peerID && (isGroup || $0.selfID == selfID)
                }, sortBy: [SortDescriptor(\.time, order: .reverse)])
        )
        .map { try PersistenceCodec.decode(SharedFile.self, from: $0.payload) }
        .filter { !($0.isExpired) && (folderID == nil || $0.folderID == folderID) }
    }

    func deleteSharedFile(id: String) throws {
        guard
            let record = try modelContext.fetch(
                FetchDescriptor<SharedFileRecord>(predicate: #Predicate { $0.id == id })
            ).first
        else { return }
        try touchStoredFolder(record.folderID, groupID: record.peerID)
        modelContext.delete(record)
        try modelContext.save()
        publish(.files)
    }

    func recordFileDownload(id: String) throws -> SharedFile? {
        guard
            let record = try modelContext.fetch(
                FetchDescriptor<SharedFileRecord>(predicate: #Predicate { $0.id == id })
            ).first
        else { return nil }
        var file = try PersistenceCodec.decode(SharedFile.self, from: record.payload)
        guard !file.isExpired else { return nil }
        file.downloadCount += 1
        record.payload = try PersistenceCodec.encode(file)
        try modelContext.save()
        publish(.files)
        return file
    }

    func editSharedFile(id: String, groupID: String, edit: SharedFileEdit) throws {
        guard
            let record = try modelContext.fetch(
                FetchDescriptor<SharedFileRecord>(
                    predicate: #Predicate { $0.id == id && $0.peerID == groupID && $0.scene == "group" })
            ).first
        else {
            throw StoreMutationError.missingTarget("The file no longer exists in this group")
        }
        var file = try PersistenceCodec.decode(SharedFile.self, from: record.payload)
        guard !file.isExpired else { throw StoreMutationError.missingTarget("The file has expired") }
        let originalFolderID = file.folderID
        switch edit {
        case .rename(let name, let parentFolderID):
            guard file.folderID == parentFolderID else {
                throw StoreMutationError.conflict("The file was moved to another folder")
            }
            file.name = name
        case .move(let parentFolderID, let targetFolderID):
            guard file.folderID == parentFolderID else {
                throw StoreMutationError.conflict("The file was moved to another folder")
            }
            try validateStoredFolder(targetFolderID, groupID: groupID)
            file.folderID = targetFolderID
        case .makePermanent:
            file.expiresAt = nil
        }
        record.folderID = file.folderID
        record.payload = try PersistenceCodec.encode(file)
        try touchStoredFolder(originalFolderID, groupID: groupID)
        if originalFolderID != file.folderID { try touchStoredFolder(file.folderID, groupID: groupID) }
        try modelContext.save()
        publish(.files)
    }

    private func validateStoredFolder(_ id: String, groupID: String) throws {
        if id == "/" { return }
        guard
            try modelContext.fetch(
                FetchDescriptor<GroupFolderRecord>(predicate: #Predicate { $0.id == id && $0.groupID == groupID })
            ).first != nil
        else {
            throw StoreMutationError.missingTarget("The folder no longer exists in this group")
        }
    }

    private func touchStoredFolder(_ id: String, groupID: String) throws {
        guard id != "/",
            let record = try modelContext.fetch(
                FetchDescriptor<GroupFolderRecord>(predicate: #Predicate { $0.id == id && $0.groupID == groupID })
            ).first
        else { return }
        var folder = try PersistenceCodec.decode(GroupFolder.self, from: record.payload)
        folder.modifiedAt = .now
        record.payload = try PersistenceCodec.encode(folder)
    }

    func save(_ folder: GroupFolder) throws {
        guard try groupRecord(id: folder.groupID) != nil else {
            throw StoreMutationError.missingTarget("The group no longer exists")
        }
        guard try !folders(groupID: folder.groupID).contains(where: { $0.name == folder.name && $0.id != folder.id })
        else {
            throw StoreMutationError.conflict("A folder with that name already exists")
        }
        let id = folder.id
        let data = try PersistenceCodec.encode(folder)
        if let record = try modelContext.fetch(
            FetchDescriptor<GroupFolderRecord>(predicate: #Predicate { $0.id == id })
        ).first {
            record.payload = data
        } else {
            modelContext.insert(
                GroupFolderRecord(id: id, groupID: folder.groupID, time: folder.createdAt, payload: data))
        }
        try modelContext.save()
        publish(.files)
    }

    func renameFolder(id: String, groupID: String, name: String) throws {
        guard
            let record = try modelContext.fetch(
                FetchDescriptor<GroupFolderRecord>(predicate: #Predicate { $0.id == id && $0.groupID == groupID })
            ).first
        else {
            throw StoreMutationError.missingTarget("The folder no longer exists in this group")
        }
        guard try !folders(groupID: groupID).contains(where: { $0.id != id && $0.name == name }) else {
            throw StoreMutationError.conflict("A folder with that name already exists")
        }
        var folder = try PersistenceCodec.decode(GroupFolder.self, from: record.payload)
        folder.name = name
        folder.modifiedAt = .now
        record.payload = try PersistenceCodec.encode(folder)
        try modelContext.save()
        publish(.files)
    }

    func folders(groupID: String) throws -> [GroupFolder] {
        try modelContext.fetch(
            FetchDescriptor<GroupFolderRecord>(
                predicate: #Predicate { $0.groupID == groupID }, sortBy: [SortDescriptor(\.time)])
        )
        .map { try PersistenceCodec.decode(GroupFolder.self, from: $0.payload) }
    }

    func deleteFolder(id: String, groupID: String) throws {
        guard
            let record = try modelContext.fetch(
                FetchDescriptor<GroupFolderRecord>(predicate: #Predicate { $0.id == id && $0.groupID == groupID })
            ).first
        else { return }
        try modelContext.transaction {
            let files = try modelContext.fetch(
                FetchDescriptor<SharedFileRecord>(
                    predicate: #Predicate { $0.folderID == id && $0.peerID == groupID && $0.scene == "group" }))
            for file in files { modelContext.delete(file) }
            modelContext.delete(record)
            try modelContext.save()
        }
        publish(.files)
    }
}
