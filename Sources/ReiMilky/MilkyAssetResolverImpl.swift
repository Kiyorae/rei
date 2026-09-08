import Foundation
import ReiCore
import ReiProtocol

/// Media and cross-reference lookups for Milky. Each lookup carries its complete
/// conversation identity, so concurrent requests cannot change one another's scope.
public struct MilkyAssetResolverImpl: MilkyAssetResolver {
    private let media: MediaService
    private let store: ReiStore

    public init(media: MediaService, store: ReiStore) {
        self.media = media
        self.store = store
    }

    // MARK: - Media

    public func resource(for asset: Asset) async -> MilkyResource {
        // Dimensions are only meaningful for images, and `MediaService` returns nil for
        // anything else, so video segments go out with the zeros the coder substitutes.
        let size = await media.pixelSize(of: asset)
        return MilkyResource(
            resourceID: asset.id,
            tempURL: await media.url(for: asset),
            width: size?.width,
            height: size?.height
        )
    }

    public func ingest(uri: String, kind: AssetKind) async -> Asset? {
        try? await media.ingest(
            reference: uri,
            suggestedName: Self.fallbackName(for: kind)
        )
    }

    /// A filename for content that arrived with none, so the MIME guess has something
    /// to work from.
    private static func fallbackName(for kind: AssetKind) -> String {
        switch kind {
        case .image: return "image.png"
        case .record: return "record.silk"
        case .video: return "video.mp4"
        case .file: return "file.bin"
        }
    }

    // MARK: - Names

    /// The name for a mention segment.
    ///
    /// Milky 1.2 changed this field to exclude the `@`, so any leading marker is
    /// stripped rather than passed through. A client that adds its own would otherwise
    /// render `@@name`.
    public func displayName(for userID: String) async -> String {
        guard let user = (try? await store.user(id: userID)) ?? nil else { return userID }
        let name = user.displayName.trimmingCharacters(in: .whitespaces)
        let stripped = name.hasPrefix("@") ? String(name.dropFirst()) : name
        return stripped.isEmpty ? userID : stripped
    }

    // MARK: - Replies

    public func replyReference(messageID: String) async -> MilkyReplyReference? {
        guard let message = try? await store.message(id: messageID), !message.isRecalled else { return nil }
        return MilkyReplyReference(
            seq: message.seq,
            senderID: message.senderID,
            time: message.time,
            content: message.content
        )
    }

    public func messageID(forSeq seq: Int64, in chat: Chat) async -> String? {
        guard
            let message = try? await store.message(
                scene: chat.scene, peerID: chat.peerID, seq: seq, selfID: chat.selfID
            ), !message.isRecalled
        else { return nil }
        return message.id
    }

    public func configureResourceEndpoint(host: String, port: UInt16) async {
        await media.setBaseURL(host: host, port: port)
    }

    public func resource(id: String, token: String?) async -> ProtocolResource? {
        await media.resource(id: id, token: token)
    }

    public func fileHash(for asset: Asset) async throws -> String {
        guard await media.exists(asset.id) else { throw CocoaError(.fileNoSuchFile) }
        return try FileFingerprint.triSHA1(at: URL(fileURLWithPath: await media.path(for: asset.id)))
    }
}
