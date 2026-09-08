import Foundation
import SwiftData

/// Adds reaction membership without rewriting the original schema.
enum ReiSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            ReiSchemaV1.UserRecord.self,
            ReiSchemaV1.GroupRecord.self,
            ReiSchemaV1.GroupMemberRecord.self,
            ReiSchemaV1.FriendshipRecord.self,
            MessageRecord.self,
            ReiSchemaV1.PendingRequestRecord.self,
            ReiSchemaV1.AssetRecord.self,
        ]
    }

    @Model
    final class MessageRecord {
        #Index<MessageRecord>(
            [\.scene, \.peerID, \.selfID, \.seq],
            [\.selfID, \.time],
            [\.time]
        )

        @Attribute(.unique) var id: String
        var seq: Int64
        var scene: String
        var peerID: String
        var senderID: String
        var selfID: String
        /// Explicit JSON bytes keep the segment persistence format under our control.
        var content: Data
        var time: Date
        var direction: String
        var recalledAt: Date?
        var recalledBy: String?
        var reactions: Data?

        init(
            id: String,
            seq: Int64,
            scene: String,
            peerID: String,
            senderID: String,
            selfID: String,
            content: Data,
            time: Date,
            direction: String,
            recalledAt: Date?,
            recalledBy: String?,
            reactions: Data?
        ) {
            self.id = id
            self.seq = seq
            self.scene = scene
            self.peerID = peerID
            self.senderID = senderID
            self.selfID = selfID
            self.content = content
            self.time = time
            self.direction = direction
            self.recalledAt = recalledAt
            self.recalledBy = recalledBy
            self.reactions = reactions
        }
    }

}
