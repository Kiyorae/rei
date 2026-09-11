import Foundation
import ReiCore

struct MentionTarget: Identifiable, Hashable {
    let userID: User.ID?

    var id: String {
        userID.map { "user:\($0)" } ?? "everyone"
    }

    var isEveryone: Bool { userID == nil }
}

struct ComposerDraft: Equatable {
    var text = ""
    var mentions: [MentionTarget] = []
    var attachments: [Asset] = []
    var replyTo: Message.ID?
    var focusRequest: UUID?
    var attachmentImportCount = 0
    var isSending = false

    var isEmpty: Bool {
        text.isEmpty && mentions.isEmpty && attachments.isEmpty && replyTo == nil
            && attachmentImportCount == 0 && !isSending
    }

    func messageContent(
        allowedMentionUserIDs: Set<User.ID>? = nil
    ) -> [MessageSegment] {
        var content = mentions.compactMap { target -> MessageSegment? in
            if let userID = target.userID,
                allowedMentionUserIDs.map({ !$0.contains(userID) }) == true
            {
                return nil
            }
            return .mention(userID: target.userID)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            content.append(.text(trimmed))
        }
        content.append(contentsOf: attachments.map(Self.segment(for:)))
        // A reply is context, not a sendable message on its own.
        if !content.isEmpty, let replyTo { content.insert(.reply(messageID: replyTo), at: 0) }
        return content
    }

    @discardableResult
    mutating func addMention(userID: User.ID?) -> Bool {
        let target = MentionTarget(userID: userID)
        guard !mentions.contains(target) else { return false }
        if target.isEveryone {
            mentions = [target]
        } else {
            mentions.removeAll(where: \.isEveryone)
            mentions.append(target)
        }
        return true
    }

    mutating func removeInvalidMentions(validUserIDs: Set<User.ID>) {
        mentions.removeAll { target in
            target.userID.map({ !validUserIDs.contains($0) }) ?? false
        }
    }

    private static func segment(for asset: Asset) -> MessageSegment {
        guard let mime = asset.mimeType else { return .file(asset) }
        if mime.hasPrefix("image/") { return .image(asset) }
        if mime.hasPrefix("audio/") { return .record(asset, duration: nil) }
        if mime.hasPrefix("video/") { return .video(asset) }
        return .file(asset)
    }
}

struct ComposerDraftKey: Hashable {
    let chat: Chat
    let senderID: User.ID?
}
