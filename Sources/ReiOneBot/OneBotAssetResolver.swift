import Foundation
import ReiCore
import ReiProtocol

/// Addresses assets the way each OneBot version expects.
///
/// The two versions differ in what a "file" is on the wire, and that difference is
/// the whole reason this type exists. v11 inherited QQ's habit of naming a file by
/// where it sits, so a framework is handed a filesystem path it can open directly,
/// with an HTTP URL alongside for anything running on another machine. v12 replaced
/// that with an opaque `file_id` minted by an upload action, which maps cleanly onto
/// the asset store's content hash.
///
/// All the actual media work belongs to `MediaService`; this only picks which of its
/// answers goes on the wire.
public struct OneBotAssetResolver: AssetResolver {
    private let media: MediaService
    private let conversion: MediaConversionService

    public init(media: MediaService, conversion: MediaConversionService? = nil) {
        self.media = media
        self.conversion = conversion ?? MediaConversionService(media: media)
    }

    // MARK: - Outbound

    public func reference(for asset: Asset, version: OneBotVersion) async -> AssetReference {
        let url = await media.url(for: asset)
        switch version {
        case .v11:
            return AssetReference(identifier: await media.path(for: asset.id), url: url)
        case .v12:
            // v12's `file_id` is exactly what the content hash already is.
            return AssetReference(identifier: asset.id, url: url)
        }
    }

    // MARK: - Inbound

    public func asset(forIdentifier identifier: String, kind: AssetKind) async -> Asset? {
        // This resolver issues content hashes, never paths or URLs. An unknown
        // opaque file_id must not turn into a new import or a filesystem lookup.
        guard identifier.count == 64,
            identifier.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            await media.exists(identifier)
        else { return nil }
        return await media.asset(id: identifier)
    }

    public func store(data: Data, name: String) async -> Asset? {
        await media.store(data: data, name: name)
    }

    public func data(for asset: Asset) async -> Data? {
        await media.data(for: asset.id)
    }

    public func data(for asset: Asset, range: Range<Int64>) async throws -> Data {
        try await media.data(for: asset.id, range: range)
    }

    public func read(from url: URL, headers: [String: String]) async throws -> Data {
        try await media.read(from: url, headers: headers)
    }

    public func convertAudio(_ asset: Asset, to format: String) async throws -> Asset {
        try await conversion.convertAudio(asset: asset, to: format)
    }

    public func configureResourceEndpoint(host: String, port: UInt16) async {
        await media.setBaseURL(host: host, port: port)
    }

    public func resource(id: String, token: String?) async -> ProtocolResource? {
        await media.resource(id: id, token: token)
    }

    public func asset(forReference reference: String, url: String?, kind: AssetKind) async -> Asset? {
        let fileURL: URL?
        if reference.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: reference)
        } else if let parsed = URL(string: reference), parsed.isFileURL {
            fileURL = parsed
        } else {
            fileURL = nil
        }
        if let fileURL, let known = await asset(forIdentifier: fileURL.lastPathComponent, kind: kind),
            fileURL.standardizedFileURL == URL(fileURLWithPath: await media.path(for: known.id)).standardizedFileURL
        {
            // V11 quotes our local path back to us. Re-importing that same file
            // under an invented fallback name would overwrite its metadata.
            return known
        }
        let hasSourceName =
            fileURL != nil
            || [reference, url].compactMap { $0 }
                .contains {
                    URL(string: $0).map {
                        !$0.lastPathComponent.isEmpty && ["http", "https"].contains($0.scheme ?? "")
                    } ?? false
                }
        // v11 sends a path, an http(s) URL, or a base64 payload under `file`, and a
        // segment often carries both `file` and `url` where only one resolves.
        // `MediaService` tries them in order.
        return try? await media.ingest(
            reference: reference,
            fallbackURL: url,
            suggestedName: hasSourceName ? nil : Self.fallbackName(for: kind)
        )
    }

    // MARK: - Naming

    /// A filename for content that arrived without one, so the stored asset and its
    /// MIME guess are not both blank.
    private static func fallbackName(for kind: AssetKind) -> String {
        switch kind {
        case .image: return "image.png"
        case .record: return "record.amr"
        case .video: return "video.mp4"
        case .file: return "file.bin"
        }
    }
}
