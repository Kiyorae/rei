import Foundation
import SwiftData

/// Adds independently addressable platform state. Existing V1/V2 records retain
/// their exact schema identities, allowing lightweight, non-destructive migration.
enum ReiSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        ReiSchemaV2.models + [
            ConversationStateRecord.self, ProfileLikeRecord.self, AnnouncementRecord.self,
            EssenceRecord.self, SharedFileRecord.self, GroupFolderRecord.self,
        ]
    }

    @Model final class ConversationStateRecord {
        @Attribute(.unique) var id: String
        var selfID: String
        var payload: Data
        init(id: String, selfID: String, payload: Data) {
            self.id = id
            self.selfID = selfID
            self.payload = payload
        }
    }

    @Model final class ProfileLikeRecord {
        @Attribute(.unique) var id: String
        var userID: String
        var operatorID: String
        var count: Int64
        var dailyCount: Int64 = 0
        var updatedAt: Date
        init(id: String, userID: String, operatorID: String, count: Int64, updatedAt: Date) {
            self.id = id
            self.userID = userID
            self.operatorID = operatorID
            self.count = count
            self.updatedAt = updatedAt
        }
    }

    @Model final class AnnouncementRecord {
        @Attribute(.unique) var id: String
        var groupID: String
        var time: Date
        var payload: Data
        init(id: String, groupID: String, time: Date, payload: Data) {
            self.id = id
            self.groupID = groupID
            self.time = time
            self.payload = payload
        }
    }

    @Model final class EssenceRecord {
        @Attribute(.unique) var id: String
        var groupID: String
        var selfID: String
        var time: Date
        var payload: Data
        init(id: String, groupID: String, selfID: String, time: Date, payload: Data) {
            self.id = id
            self.groupID = groupID
            self.selfID = selfID
            self.time = time
            self.payload = payload
        }
    }

    @Model final class SharedFileRecord {
        @Attribute(.unique) var id: String
        var scene: String
        var peerID: String
        var selfID: String
        var folderID: String
        var assetID: String
        var time: Date
        var payload: Data
        init(
            id: String, scene: String, peerID: String, selfID: String, folderID: String, assetID: String, time: Date,
            payload: Data
        ) {
            self.id = id
            self.scene = scene
            self.peerID = peerID
            self.selfID = selfID
            self.folderID = folderID
            self.assetID = assetID
            self.time = time
            self.payload = payload
        }
    }

    @Model final class GroupFolderRecord {
        @Attribute(.unique) var id: String
        var groupID: String
        var time: Date
        var payload: Data
        init(id: String, groupID: String, time: Date, payload: Data) {
            self.id = id
            self.groupID = groupID
            self.time = time
            self.payload = payload
        }
    }
}

typealias ConversationStateRecord = ReiSchemaV3.ConversationStateRecord
typealias ProfileLikeRecord = ReiSchemaV3.ProfileLikeRecord
typealias AnnouncementRecord = ReiSchemaV3.AnnouncementRecord
typealias EssenceRecord = ReiSchemaV3.EssenceRecord
typealias SharedFileRecord = ReiSchemaV3.SharedFileRecord
typealias GroupFolderRecord = ReiSchemaV3.GroupFolderRecord
