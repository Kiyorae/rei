import Foundation
import Observation
import ReiCore
import ReiProtocol

enum ConversationContentSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case announcements = "Announcements"
    case files = "Files"
    case essence = "Highlights"

    var id: String { rawValue }
}

struct ConversationContentCapabilities {
    let protocolChoice: ProtocolChoice
    let scene: ChatScene
    let canInteract: Bool
    let role: GroupMember.Role?

    var supportsState: Bool { protocolChoice == .milky }
    var supportsGroupContent: Bool { protocolChoice == .milky && scene == .group }
    var supportsProfileLikes: Bool {
        scene.isPrivate && (protocolChoice == .oneBotV11 || protocolChoice == .milky && scene == .friend)
    }
    var supportsFiles: Bool {
        protocolChoice == .milky && scene != .temp || protocolChoice == .oneBotV11 && scene == .group
    }
    var canManageGroupContent: Bool { supportsGroupContent && canInteract && role.map { $0 > .member } == true }
    var sections: [ConversationContentSection] {
        var result: [ConversationContentSection] = []
        if supportsState || supportsProfileLikes { result.append(.overview) }
        if supportsGroupContent { result.append(.announcements) }
        if supportsFiles { result.append(.files) }
        if supportsGroupContent { result.append(.essence) }
        return result
    }
}

/// Scene-owned state for content browsing. Mutations recheck the current protocol
/// and identity before handing ownership and permission checks to PlatformService.
@Observable
@MainActor
final class ConversationContentModel {
    let environment: AppEnvironment
    let chat: Chat
    var state: ConversationState
    var announcements: [GroupAnnouncement]?
    var files: [SharedFile]?
    var folders: [GroupFolder] = []
    var highlightedMessages: [Message]?
    var recentMessages: [Message] = []
    var profileLikes: [ProfileLike]?
    var selectedFolderID = "/"
    var isWorking = false
    var errorMessage: String?

    init(environment: AppEnvironment, chat: Chat) {
        self.environment = environment
        self.chat = chat
        state = ConversationState(chat: chat)
    }

    var capabilities: ConversationContentCapabilities {
        ConversationContentCapabilities(
            protocolChoice: environment.effectiveProtocol, scene: chat.scene,
            canInteract: environment.canInteract(in: chat)
                && (environment.activeBotUserID == nil || environment.activeBotUserID == chat.selfID),
            role: environment.activeUserID.flatMap { environment.role(of: $0, in: chat.peerID) }
        )
    }

    var profileUserID: String? { environment.activeUserID.flatMap { chat.counterpartID(for: $0) } }
    var visibleFiles: [SharedFile]? {
        files.map { values in
            capabilities.supportsGroupContent ? values.filter { $0.folderID == selectedFolderID } : values
        }
    }

    func canEdit(_ file: SharedFile) -> Bool {
        capabilities.supportsGroupContent && capabilities.canInteract
            && (file.uploaderID == environment.activeUserID || capabilities.canManageGroupContent)
    }

    func observeState() async {
        await consume(environment.store.observeConversationState(in: chat)) { state = $0 }
    }

    func observeMessages() async {
        await consume(environment.store.observeMessages(in: chat)) { recentMessages = $0 }
    }

    func observeAnnouncements() async {
        await consume(environment.store.observeAnnouncements(groupID: chat.peerID)) { announcements = $0 }
    }

    func observeFiles() async {
        await consume(environment.store.observeSharedFiles(in: chat)) { files = $0 }
    }

    func observeFolders() async {
        await consume(environment.store.observeFolders(groupID: chat.peerID)) { values in
            folders = values
            if selectedFolderID != "/", !values.contains(where: { $0.id == selectedFolderID }) {
                selectedFolderID = "/"
            }
        }
    }

    func observeHighlights() async {
        do {
            for try await values in environment.store.observeEssences(in: chat) {
                var messages: [Message] = []
                for value in values {
                    if let message = try await environment.store.message(id: value.messageID),
                        message.chat == chat, !message.isRecalled
                    {
                        messages.append(message)
                    }
                }
                try Task.checkCancellation()
                highlightedMessages = messages
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func observeLikes(for userID: String?) async {
        profileLikes = nil
        guard let userID else {
            profileLikes = []
            return
        }
        await consume(environment.store.observeProfileLikes(userID: userID)) { profileLikes = $0 }
    }

    func setPinned(_ pinned: Bool) async throws {
        try require(capabilities.supportsState && capabilities.canInteract)
        try await environment.platform.setPeerPin(in: chat, isPinned: pinned)
    }

    func markRead() async throws {
        try require(capabilities.supportsState && capabilities.canInteract)
        guard let latest = try await environment.store.messages(in: chat, limit: 1).last else { return }
        try await environment.platform.markRead(in: chat, through: latest.seq)
    }

    func likeProfile(count: Int) async throws {
        let actor = try requireActor(capabilities.supportsProfileLikes && capabilities.canInteract)
        guard let target = chat.counterpartID(for: actor) else {
            throw PlatformError.notPermitted("No profile is selected")
        }
        try await environment.platform.likeProfile(
            userID: target, operatorID: actor, count: count,
            dailyLimit: environment.effectiveProtocol == .oneBotV11 ? 10 : nil
        )
    }

    func postAnnouncement(content: String, image: Asset?) async throws {
        let actor = try requireActor(capabilities.canManageGroupContent)
        try await environment.platform.postAnnouncement(
            groupID: chat.peerID, operatorID: actor, content: content, image: image)
    }

    func deleteAnnouncement(_ announcement: GroupAnnouncement) async throws {
        let actor = try requireActor(capabilities.canManageGroupContent)
        try await environment.platform.deleteAnnouncement(id: announcement.id, groupID: chat.peerID, operatorID: actor)
    }

    func importImage(at url: URL) async throws -> Asset {
        try require(capabilities.canManageGroupContent)
        let asset = try await importAttachment(at: url)
        let cached = try await environment.attachmentURL(for: asset)
        _ = try await AttachmentImages.thumbnail(at: cached)
        return asset
    }

    func uploadFile(at url: URL) async throws {
        let actor = try requireActor(capabilities.supportsFiles && capabilities.canInteract)
        let folderID = capabilities.supportsGroupContent ? selectedFolderID : "/"
        let asset = try await importAttachment(at: url)
        var fingerprint = ""
        if chat.scene == .friend {
            let source = try await environment.attachmentURL(for: asset)
            fingerprint = try await Task.detached { try FileFingerprint.triSHA1(at: source) }.value
        }
        try await environment.platform.shareFile(
            in: chat, operatorID: actor, asset: asset, name: url.lastPathComponent, folderID: folderID,
            fileHash: fingerprint
        )
    }

    func download(_ file: SharedFile) async throws {
        let actor = try requireActor(capabilities.supportsFiles && capabilities.canInteract)
        _ = try await environment.platform.downloadSharedFile(id: file.id, in: chat, operatorID: actor)
    }

    func renameFile(_ file: SharedFile, to name: String) async throws {
        let actor = try requireActor(canEdit(file))
        try await environment.platform.renameGroupFile(
            id: file.id, groupID: chat.peerID, folderID: file.folderID, name: name, operatorID: actor
        )
    }

    func moveFile(_ file: SharedFile, to folderID: String) async throws {
        let actor = try requireActor(canEdit(file))
        try await environment.platform.moveGroupFile(
            id: file.id, groupID: chat.peerID, from: file.folderID, to: folderID, operatorID: actor
        )
    }

    func deleteFile(_ file: SharedFile) async throws {
        let actor = try requireActor(canEdit(file))
        try await environment.platform.deleteGroupFile(id: file.id, groupID: chat.peerID, operatorID: actor)
    }

    func keepFile(_ file: SharedFile) async throws {
        let actor = try requireActor(canEdit(file))
        try await environment.platform.persistGroupFile(id: file.id, groupID: chat.peerID, operatorID: actor)
    }

    func createFolder(name: String) async throws {
        let actor = try requireActor(capabilities.canManageGroupContent)
        try await environment.platform.createGroupFolder(groupID: chat.peerID, name: name, operatorID: actor)
    }

    func renameFolder(_ folder: GroupFolder, to name: String) async throws {
        let actor = try requireActor(capabilities.canManageGroupContent)
        try await environment.platform.renameGroupFolder(
            id: folder.id, groupID: chat.peerID, name: name, operatorID: actor)
    }

    func deleteFolder(_ folder: GroupFolder) async throws {
        let actor = try requireActor(capabilities.canManageGroupContent)
        try await environment.platform.deleteGroupFolder(id: folder.id, groupID: chat.peerID, operatorID: actor)
    }

    func setHighlight(_ message: Message, enabled: Bool) async throws {
        let actor = try requireActor(capabilities.canManageGroupContent)
        guard message.chat == chat else { throw PlatformError.messageNotFound(message.id) }
        try await environment.platform.setMessageEssence(messageID: message.id, operatorID: actor, isSet: enabled)
    }

    func reveal(_ message: Message) async -> Bool {
        guard message.chat == chat else { return false }
        environment.selectChat(chat)
        return await environment.revealMessage(id: message.id, in: chat)
    }

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await operation() } catch is CancellationError {} catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func require(_ condition: Bool) throws {
        guard condition else {
            throw PlatformError.notPermitted("This action is unavailable for the current conversation and identity")
        }
    }

    private func requireActor(_ condition: Bool) throws -> String {
        try require(condition)
        guard let actor = environment.activeUserID else {
            throw PlatformError.notPermitted("Select a sending identity")
        }
        return actor
    }

    private func importAttachment(at url: URL) async throws -> Asset {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let asset = await environment.ingestAttachment(at: url) else {
            throw CocoaError(.fileReadUnknown)
        }
        return asset
    }

    private func consume<Value>(_ observation: StoreObservation<Value>, update: (Value) -> Void) async {
        do {
            for try await value in observation {
                try Task.checkCancellation()
                update(value)
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
