import Foundation
import ReiCore
import ReiProtocol

extension MilkyProtocolImplementation {
    func uploadPrivateFile(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        let chat = Chat(scene: .friend, peerID: try input.id("user_id"), selfID: selfID)
        guard try await platform.store.user(id: chat.peerID) != nil else {
            throw PlatformError.userNotFound(chat.peerID)
        }
        let name = try input.string("file_name")
        guard var asset = await assetResolver.ingest(uri: try input.string("file_uri"), kind: .file) else {
            throw PlatformError.invalidParameter("The file URI could not be read")
        }
        asset.name = name
        let hash = try await assetResolver.fileHash(for: asset)
        let file = try await platform.shareFile(in: chat, operatorID: selfID, asset: asset, name: name, fileHash: hash)
        return .success(["file_id": .string(file.id)])
    }

    func uploadGroupFile(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        let groupID = try input.id("group_id")
        try await requireFileGroup(groupID)
        let folderID = try defaultFolder(in: call, key: "parent_folder_id")
        try await validateFolder(folderID, groupID: groupID)
        let name = try input.string("file_name")
        guard var asset = await assetResolver.ingest(uri: try input.string("file_uri"), kind: .file) else {
            throw PlatformError.invalidParameter("The file URI could not be read")
        }
        asset.name = name
        let file = try await platform.shareFile(
            in: Chat(scene: .group, peerID: groupID, selfID: selfID), operatorID: selfID, asset: asset, name: name,
            folderID: folderID)
        return .success(["file_id": .string(file.id)])
    }

    func getPrivateFileDownloadURL(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        let peerID = try input.id("user_id")
        let fileID = try input.string("file_id")
        let hash = try input.string("file_hash")
        let isSelfSend = try input.bool("is_self_send", default: false)
        let chat = Chat(scene: .friend, peerID: peerID, selfID: selfID)
        guard let file = try await platform.store.sharedFile(id: fileID), file.chat == chat,
            file.fileHash == hash, (file.uploaderID == selfID) == isSelfSend
        else { throw PlatformError.messageNotFound("Private file \(fileID)") }
        let available = try await platform.downloadSharedFile(id: fileID, in: chat, operatorID: selfID)
        return .success(["download_url": .string(await resourceURL(for: available))])
    }

    func getGroupFileDownloadURL(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        let chat = Chat(scene: .group, peerID: try input.id("group_id"), selfID: selfID)
        let file = try await platform.downloadSharedFile(id: input.string("file_id"), in: chat, operatorID: selfID)
        return .success(["download_url": .string(await resourceURL(for: file))])
    }

    func getGroupFiles(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        let groupID = try input.id("group_id")
        try await requireFileGroup(groupID)
        let parentID = try defaultFolder(in: call, key: "parent_folder_id")
        try await validateFolder(parentID, groupID: groupID)
        let chat = Chat(scene: .group, peerID: groupID, selfID: selfID)
        let allFiles = try await platform.store.sharedFiles(in: chat)
        let files = allFiles.filter { $0.folderID == parentID }.map(fileEntity)
        let folders = parentID == "/" ? try await platform.store.folders(groupID: groupID) : []
        return .success([
            "files": .array(files),
            "folders": .array(
                folders.map { folder in
                    [
                        "group_id": MilkyEntityEncoder.uin(groupID), "folder_id": .string(folder.id),
                        "parent_folder_id": "/",
                        "folder_name": .string(folder.name),
                        "created_time": MilkyEntityEncoder.timestamp(folder.createdAt),
                        "last_modified_time": MilkyEntityEncoder.timestamp(folder.modifiedAt),
                        "creator_id": MilkyEntityEncoder.uin(folder.creatorID),
                        "file_count": .number(Double(allFiles.filter { $0.folderID == folder.id }.count)),
                    ]
                }),
        ])
    }

    func moveGroupFile(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        try await platform.moveGroupFile(
            id: input.string("file_id"), groupID: input.id("group_id"),
            from: defaultFolder(in: call, key: "parent_folder_id"),
            to: defaultFolder(in: call, key: "target_folder_id"), operatorID: selfID)
        return .success()
    }

    func renameGroupFile(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        try await platform.renameGroupFile(
            id: input.string("file_id"), groupID: input.id("group_id"),
            folderID: defaultFolder(in: call, key: "parent_folder_id"), name: input.string("new_file_name"),
            operatorID: selfID)
        return .success()
    }

    func deleteGroupFile(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        try await platform.deleteGroupFile(
            id: input.string("file_id"), groupID: input.id("group_id"), operatorID: selfID)
        return .success()
    }

    func persistGroupFile(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        try await platform.persistGroupFile(
            id: input.string("file_id"), groupID: input.id("group_id"), operatorID: selfID)
        return .success()
    }

    func createGroupFolder(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        let folder = try await platform.createGroupFolder(
            groupID: input.id("group_id"), name: input.string("folder_name"), operatorID: selfID)
        return .success(["folder_id": .string(folder.id)])
    }

    func renameGroupFolder(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        try await platform.renameGroupFolder(
            id: input.string("folder_id"), groupID: input.id("group_id"), name: input.string("new_folder_name"),
            operatorID: selfID)
        return .success()
    }

    func deleteGroupFolder(_ call: ProtocolCall) async throws -> ProtocolReply {
        let input = try MilkyParameters(call)
        try await platform.deleteGroupFolder(
            id: input.string("folder_id"), groupID: input.id("group_id"), operatorID: selfID)
        return .success()
    }

    private func defaultFolder(in call: ProtocolCall, key: String) throws -> String {
        call.parameters[key] == nil ? "/" : try MilkyParameters(call).string(key)
    }

    private func requireFileGroup(_ groupID: String) async throws {
        guard try await platform.store.group(id: groupID) != nil else { throw PlatformError.groupNotFound(groupID) }
        guard try await platform.store.member(groupID: groupID, userID: selfID) != nil else {
            throw PlatformError.notAMember(groupID: groupID, userID: selfID)
        }
    }

    private func validateFolder(_ folderID: String, groupID: String) async throws {
        if folderID == "/" { return }
        guard try await platform.store.folders(groupID: groupID).contains(where: { $0.id == folderID }) else {
            throw PlatformError.invalidParameter("Folder not found in this group")
        }
    }

    private func fileEntity(_ file: SharedFile) -> JSONValue {
        var payload: [String: JSONValue] = [
            "group_id": MilkyEntityEncoder.uin(file.chat.peerID), "file_id": .string(file.id),
            "file_name": .string(file.name),
            "parent_folder_id": .string(file.folderID), "file_size": .number(Double(file.asset.byteCount)),
            "uploaded_time": MilkyEntityEncoder.timestamp(file.uploadedAt),
            "uploader_id": MilkyEntityEncoder.uin(file.uploaderID),
            "downloaded_times": .number(Double(file.downloadCount)),
        ]
        if let expiration = file.expiresAt { payload["expire_time"] = MilkyEntityEncoder.timestamp(expiration) }
        return .object(payload)
    }

    private func resourceURL(for file: SharedFile) async -> String {
        var asset = file.asset
        asset.name = file.name
        return await assetResolver.resource(for: asset).tempURL
    }
}
