import Foundation
import ReiCore
import ReiProtocol

extension MilkyProtocolImplementation {
    func getPeerPins(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard case .object = call.parameters else {
            throw PlatformError.invalidParameter("API parameters must be a JSON object")
        }
        let states = try await platform.store.conversationStates(selfID: selfID)
        var friends: [JSONValue] = []
        var groups: [JSONValue] = []
        var seenFriends: Set<String> = []
        for state in states.filter(\.isPinned).sorted(by: { $0.chat.id < $1.chat.id }) {
            let chat = state.chat
            if chat.scene == .group {
                if let group = try await platform.store.group(id: chat.peerID),
                    try await platform.store.member(groupID: chat.peerID, userID: selfID) != nil
                {
                    groups.append(await entityEncoder.group(group))
                }
            } else if !seenFriends.contains(chat.peerID), let user = try await platform.store.user(id: chat.peerID) {
                let friendship = try await platform.store.friendship(userID: selfID, friendID: chat.peerID)
                friends.append(await entityEncoder.friend(user, remark: friendship?.remark ?? ""))
                seenFriends.insert(chat.peerID)
            }
        }
        return .success(["friends": .array(friends), "groups": .array(groups)])
    }

    func setPeerPin(_ call: ProtocolCall) async throws -> ProtocolReply {
        let parameters = try MilkyParameters(call)
        let chat = try parameters.chat(selfID: selfID)
        let isPinned = try parameters.bool("is_pinned", default: true)
        try await platform.setPeerPin(in: chat, isPinned: isPinned)
        return .success()
    }

    func markMessageAsRead(_ call: ProtocolCall) async throws -> ProtocolReply {
        let parameters = try MilkyParameters(call)
        let chat = try parameters.chat(selfID: selfID)
        let sequence = try parameters.int64("message_seq", minimum: 1)
        try await platform.markRead(in: chat, through: sequence)
        return .success()
    }

    func sendProfileLike(_ call: ProtocolCall) async throws -> ProtocolReply {
        let parameters = try MilkyParameters(call)
        let userID = try parameters.id("user_id")
        let count = try parameters.int32("count", default: 1, minimum: 1)
        try await platform.likeProfile(userID: userID, operatorID: selfID, count: count)
        return .success()
    }

    func getGroupAnnouncements(_ call: ProtocolCall) async throws -> ProtocolReply {
        let groupID = try MilkyParameters(call).id("group_id")
        try await requireMilkyGroupMembership(groupID)
        let announcements = try await platform.store.announcements(groupID: groupID)
        var values: [JSONValue] = []
        for announcement in announcements {
            let imageURL: String?
            if let image = announcement.image {
                imageURL = await assetResolver.resource(for: image).tempURL
            } else {
                imageURL = nil
            }
            values.append(entityEncoder.announcement(announcement, imageURL: imageURL))
        }
        return .success(["announcements": .array(values)])
    }

    func sendGroupAnnouncement(_ call: ProtocolCall) async throws -> ProtocolReply {
        let parameters = try MilkyParameters(call)
        let groupID = try parameters.id("group_id")
        let content = try parameters.string("content")
        let imageURI = try parameters.optionalString("image_uri")
        try await requireMilkyGroupMembership(groupID)
        guard let actor = try await platform.store.member(groupID: groupID, userID: selfID), actor.role > .member else {
            throw PlatformError.notPermitted("Administrator privileges are required")
        }
        let image: Asset?
        if let imageURI {
            guard !imageURI.isEmpty, let ingested = await assetResolver.ingest(uri: imageURI, kind: .image) else {
                throw PlatformError.invalidParameter("image_uri could not be read")
            }
            image = ingested
        } else {
            image = nil
        }
        try await platform.postAnnouncement(groupID: groupID, operatorID: selfID, content: content, image: image)
        return .success()
    }

    func deleteGroupAnnouncement(_ call: ProtocolCall) async throws -> ProtocolReply {
        let parameters = try MilkyParameters(call)
        let groupID = try parameters.id("group_id")
        let announcementID = try parameters.string("announcement_id")
        guard !announcementID.isEmpty else { throw PlatformError.invalidParameter("announcement_id cannot be empty") }
        try await platform.deleteAnnouncement(id: announcementID, groupID: groupID, operatorID: selfID)
        return .success()
    }

    func setGroupEssenceMessage(_ call: ProtocolCall) async throws -> ProtocolReply {
        let parameters = try MilkyParameters(call)
        let groupID = try parameters.id("group_id")
        let sequence = try parameters.int64("message_seq", minimum: 1)
        let isSet = try parameters.bool("is_set", default: true)
        guard
            let message = try await platform.store.message(
                scene: .group, peerID: groupID, seq: sequence, selfID: selfID)
        else {
            throw PlatformError.messageNotFound("\(groupID):\(sequence)")
        }
        try await platform.setMessageEssence(messageID: message.id, operatorID: selfID, isSet: isSet)
        return .success()
    }

    func getGroupEssenceMessages(_ call: ProtocolCall) async throws -> ProtocolReply {
        let parameters = try MilkyParameters(call)
        let groupID = try parameters.id("group_id")
        let pageIndex = try parameters.int32("page_index")
        let pageSize = try parameters.int32("page_size", minimum: 1)
        try await requireMilkyGroupMembership(groupID)
        let chat = Chat(scene: .group, peerID: groupID, selfID: selfID)
        let essences = try await platform.store.essences(in: chat)
        var available: [(MessageEssence, Message)] = []
        for essence in essences {
            if let message = try await platform.store.message(id: essence.messageID), message.chat == chat,
                !message.isRecalled
            {
                available.append((essence, message))
            }
        }
        // Both factors are nonnegative int32 values, so the product fits in int64.
        let offset = pageIndex * pageSize
        guard offset < available.count else { return .success(["messages": .array([]), "is_end": true]) }
        let end = offset + min(pageSize, available.count - offset)
        var messages: [JSONValue] = []
        for (essence, message) in available[offset..<end] {
            let sender = try await platform.store.user(id: message.senderID)
            let actor = try await platform.store.user(id: essence.operatorID)
            messages.append(
                entityEncoder.essence(
                    essence, message: message, senderName: sender?.displayName ?? message.senderID,
                    operatorName: actor?.displayName ?? essence.operatorID,
                    segments: await segmentCoder.encodeIncoming(message.content)))
        }
        return .success(["messages": .array(messages), "is_end": .bool(end == available.count)])
    }

    func requireMilkyGroupMembership(_ groupID: String) async throws {
        guard try await platform.store.group(id: groupID) != nil else { throw PlatformError.groupNotFound(groupID) }
        guard try await platform.store.member(groupID: groupID, userID: selfID) != nil else {
            throw PlatformError.notAMember(groupID: groupID, userID: selfID)
        }
    }
}

/// Milky declares JSON types explicitly. OneBot's permissive parameter coercions
/// must not turn strings, booleans or fractional values into valid Milky IDs.
struct MilkyParameters {
    private let values: [String: JSONValue]

    init(_ call: ProtocolCall) throws {
        guard case .object(let values) = call.parameters else {
            throw PlatformError.invalidParameter("API parameters must be a JSON object")
        }
        self.values = values
    }

    func string(_ key: String) throws -> String {
        guard case .string(let value) = values[key] else {
            throw PlatformError.invalidParameter("\(key) must be a string")
        }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key], value != .null else { return nil }
        return try string(key)
    }

    func int64(_ key: String, default defaultValue: Int64? = nil, minimum: Int64 = 0) throws -> Int64 {
        if values[key] == nil, let defaultValue { return defaultValue }
        guard case .number(let number) = values[key], let value = Int64(exactly: number), value >= minimum else {
            throw PlatformError.invalidParameter("\(key) must be an integer of at least \(minimum)")
        }
        return value
    }

    func int32(_ key: String, default defaultValue: Int? = nil, minimum: Int = 0) throws -> Int {
        let value = try int64(key, default: defaultValue.map(Int64.init), minimum: Int64(minimum))
        guard value <= Int32.max else { throw PlatformError.invalidParameter("\(key) must fit in int32") }
        return Int(value)
    }

    func id(_ key: String) throws -> String { String(try int64(key, minimum: 1)) }

    func bool(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = values[key] else { return defaultValue }
        guard case .bool(let result) = value else { throw PlatformError.invalidParameter("\(key) must be a boolean") }
        return result
    }

    func chat(selfID: String) throws -> Chat {
        guard let scene = ChatScene(rawValue: try string("message_scene")) else {
            throw PlatformError.invalidParameter("message_scene must be friend, group or temp")
        }
        return Chat(scene: scene, peerID: try id("peer_id"), selfID: selfID)
    }
}
