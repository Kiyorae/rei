import Foundation

public enum SharedFileEdit: Sendable {
    case rename(name: String, parentFolderID: String)
    case move(parentFolderID: String, targetFolderID: String)
    case makePermanent
}

public enum StoreMutationError: Error, LocalizedError, Sendable {
    case missingTarget(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .missingTarget(let reason), .conflict(let reason): return reason
        }
    }
}

public struct ConversationState: Hashable, Codable, Sendable, Identifiable {
    public var chat: Chat
    public var isPinned: Bool
    public var lastReadSequence: Int64
    public var id: String { chat.id }

    public init(chat: Chat, isPinned: Bool = false, lastReadSequence: Int64 = 0) {
        self.chat = chat
        self.isPinned = isPinned
        self.lastReadSequence = lastReadSequence
    }
}

public struct ProfileLike: Hashable, Codable, Sendable {
    public var userID: String
    public var operatorID: String
    public var count: Int64
    public var dailyCount: Int64
    public var updatedAt: Date

    public init(userID: String, operatorID: String, count: Int64, dailyCount: Int64 = 0, updatedAt: Date = .now) {
        self.userID = userID
        self.operatorID = operatorID
        self.count = count
        self.dailyCount = dailyCount
        self.updatedAt = updatedAt
    }
}

public struct GroupAnnouncement: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var groupID: String
    public var senderID: String
    public var time: Date
    public var content: String
    public var image: Asset?

    public init(
        id: String = UUID().uuidString, groupID: String, senderID: String, time: Date = .now, content: String,
        image: Asset? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.senderID = senderID
        self.time = time
        self.content = content
        self.image = image
    }
}

public struct MessageEssence: Hashable, Codable, Sendable, Identifiable {
    public var messageID: String
    public var chat: Chat
    public var operatorID: String
    public var time: Date
    public var id: String { messageID }

    public init(messageID: String, chat: Chat, operatorID: String, time: Date = .now) {
        self.messageID = messageID
        self.chat = chat
        self.operatorID = operatorID
        self.time = time
    }
}

/// A directory entry is distinct from its content-addressed asset. The same
/// bytes may be uploaded under different names, to different conversations.
public struct SharedFile: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var chat: Chat
    public var name: String
    public var folderID: String
    public var asset: Asset
    public var uploaderID: String
    public var uploadedAt: Date
    public var expiresAt: Date?
    public var downloadCount: Int
    public var fileHash: String
    public var isExpired: Bool { expiresAt.map { $0 <= .now } ?? false }

    public init(
        id: String = UUID().uuidString, chat: Chat, name: String, folderID: String = "/", asset: Asset,
        uploaderID: String, uploadedAt: Date = .now, expiresAt: Date? = nil, downloadCount: Int = 0,
        fileHash: String = ""
    ) {
        self.id = id
        self.chat = chat
        self.name = name
        self.folderID = folderID
        self.asset = asset
        self.uploaderID = uploaderID
        self.uploadedAt = uploadedAt
        self.expiresAt = expiresAt
        self.downloadCount = downloadCount
        self.fileHash = fileHash
    }
}

public struct GroupFolder: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var groupID: String
    public var name: String
    public var creatorID: String
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: String = UUID().uuidString, groupID: String, name: String, creatorID: String,
        createdAt: Date = .now, modifiedAt: Date = .now
    ) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.creatorID = creatorID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
