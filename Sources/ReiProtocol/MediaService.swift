import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ReiCore

/// The media brain both protocol adapters delegate to.
///
/// OneBot and Milky disagree on how a file is named on the wire (a path, an ID, a
/// `resource_id` with dimensions attached), but every one of those forms is a view
/// of the same stored bytes. This actor owns that single view: ingesting whatever a
/// peer sent, resolving an ID back to an `Asset`, and answering the two questions
/// the wire formats ask about it (where can it be fetched, how big is the picture).
/// The per-protocol shaping stays in the resolvers.
///
/// The HTTP base address is settable rather than fixed because the listening port is
/// only known once a session has started. URLs produced here point at
/// `/assets/<id>`, which whichever server the app runs for media is expected to
/// serve.
public actor MediaService {
    /// Pixel dimensions, as Milky's `width`/`height` fields want them.
    public struct PixelSize: Sendable, Hashable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    private let assetStore: AssetStore
    private let store: ReiStore
    private let session: URLSession
    private var host: String = "127.0.0.1"
    private var port: UInt16 = ConnectionSettings.defaultPort
    private var resourceKey = SymmetricKey(size: .bits256)

    /// Measured dimensions, keyed by asset ID. Safe to cache for the life of the
    /// process because the asset store is content-addressed: an ID names one exact
    /// byte sequence forever. `nil` is cached too, since "not an image" costs the
    /// same file probe to rediscover.
    private var pixelSizes: [String: PixelSize?] = [:]

    public init(assetStore: AssetStore, store: ReiStore, session: URLSession = .shared) {
        self.assetStore = assetStore
        self.store = store
        self.session = session
    }

    // MARK: - Addressing

    /// Points generated URLs at the address a session is actually reachable on.
    public func setBaseURL(host: String, port: UInt16) {
        self.host = host
        self.port = port
        resourceKey = SymmetricKey(size: .bits256)
    }

    public var baseURL: String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host == "0.0.0.0" || host == "::" ? "127.0.0.1" : host
        components.port = Int(port)
        return components.string ?? ""
    }

    /// An HTTP URL for a stored asset.
    public func url(for id: String) -> String {
        resourceURL(id: id, filename: "")
    }

    /// Names belong to the attachment or shared-file entry, while bytes belong to
    /// the content hash. Keep the requested name in this URL's signed grant rather
    /// than overwriting metadata used by another entry with identical contents.
    public func url(for asset: Asset) -> String {
        resourceURL(id: asset.id, filename: asset.name)
    }

    private func resourceURL(id: String, filename: String) -> String {
        let expires = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let name = Data(filename.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let message = Data("\(id):\(expires):\(name)".utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: resourceKey)
            .map { String(format: "%02x", $0) }.joined()
        return "\(baseURL)/assets/\(id)?token=\(expires).\(name).\(signature)"
    }

    /// A temporary URL authorizes exactly one stored content hash. It carries no
    /// protocol API secret, and cannot be changed to read another resource.
    public func resource(id: String, token: String?) async -> ProtocolResource? {
        guard Self.isAssetID(id), let token else { return nil }
        let fields = token.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, let expires = Int64(fields[0]),
            expires >= Int64(Date().timeIntervalSince1970), fields[2].count == 64
        else { return nil }
        let signatureText = Array(fields[2].utf8)
        var signature = Data()
        for index in stride(from: 0, to: signatureText.count, by: 2) {
            guard let byte = UInt8(String(decoding: signatureText[index..<(index + 2)], as: UTF8.self), radix: 16)
            else {
                return nil
            }
            signature.append(byte)
        }
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                signature, authenticating: Data("\(id):\(fields[0]):\(fields[1])".utf8), using: resourceKey
            )
        else { return nil }
        var base64Name = fields[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64Name += String(repeating: "=", count: (4 - base64Name.count % 4) % 4)
        guard let nameData = Data(base64Encoded: base64Name), let filename = String(data: nameData, encoding: .utf8),
            let asset = await asset(id: id), let contents = await data(for: id)
        else { return nil }
        return ProtocolResource(
            data: contents, mimeType: asset.mimeType, filename: filename.isEmpty ? asset.name : filename)
    }

    private static func isAssetID(_ id: String) -> Bool {
        id.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The asset's path on disk. OneBot v11 hands this to the framework directly so
    /// it can read the file without an HTTP round trip.
    public func path(for id: String) async -> String {
        await assetStore.location(of: id).path
    }

    // MARK: - Ingesting

    /// Reads an upload source without publishing an asset before the protocol's
    /// checksum validation has succeeded.
    public func read(from url: URL, headers: [String: String] = [:]) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url, options: .mappedIfSafe) }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Takes an inbound reference in any form a peer might use and returns the stored
    /// asset.
    ///
    /// Parsing `base64://`, `data:`, `file://`, bare paths, and http(s) downloads is
    /// `AssetStore`'s job; what this adds is the database row, without which a later
    /// lookup by ID would find bytes but no name or MIME type.
    public func ingest(
        reference: String,
        fallbackURL: String? = nil,
        suggestedName: String? = nil
    ) async throws -> Asset? {
        guard
            let asset = try await assetStore.ingest(
                reference: reference,
                fallbackURL: fallbackURL,
                suggestedName: suggestedName
            )
        else { return nil }
        try await store.save(asset)
        return asset
    }

    /// Stores raw bytes a peer uploaded inline.
    public func store(data: Data, name: String, mimeType: String? = nil) async -> Asset? {
        do {
            let asset = try await assetStore.store(data, name: name, mimeType: mimeType)
            try await store.save(asset)
            return asset
        } catch {
            return nil
        }
    }

    // MARK: - Resolving

    /// Resolves an asset ID a peer quoted back at us.
    public func asset(id: String) async -> Asset? {
        if let stored = (try? await store.asset(id: id)) ?? nil { return stored }

        // A file can outlive its row: the cache directory survives a store rebuild.
        // Reconstructing a minimal asset serves the bytes rather than reporting a
        // file the peer can plainly see is there as missing.
        guard await assetStore.exists(id) else { return nil }
        let location = await assetStore.location(of: id)
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size]) as? Int
        return Asset(
            id: id,
            name: id,
            mimeType: AssetStore.mimeType(forFileName: location.lastPathComponent),
            byteCount: byteCount ?? 0,
            source: .local(path: location.path)
        )
    }

    public func data(for id: String) async -> Data? {
        try? await assetStore.data(for: id)
    }

    /// Reads only the requested bytes for fragmented transfers.
    public func data(for id: String, range: Range<Int64>) async throws -> Data {
        guard Self.isAssetID(id), range.lowerBound >= 0,
            let count = Int(exactly: range.upperBound - range.lowerBound)
        else { throw CocoaError(.fileReadInvalidFileName) }
        let handle = try FileHandle(forReadingFrom: await assetStore.location(of: id))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        let bytes = try handle.read(upToCount: count) ?? Data()
        guard bytes.count == count else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }

    public func exists(_ id: String) async -> Bool {
        await assetStore.exists(id)
    }

    // MARK: - Image dimensions

    public func pixelSize(of asset: Asset) async -> PixelSize? {
        await pixelSize(ofAssetID: asset.id, mimeType: asset.mimeType)
    }

    public func pixelSize(ofAssetID id: String, mimeType: String? = nil) async -> PixelSize? {
        if let cached = pixelSizes[id] { return cached }
        let measured = await measure(id: id, mimeType: mimeType)
        pixelSizes[id] = measured
        return measured
    }

    /// Reads dimensions out of the file header.
    ///
    /// ImageIO rather than a full decode: dimensions are metadata, and measuring a
    /// large photo should not cost the memory of decompressing it.
    private func measure(id: String, mimeType: String?) async -> PixelSize? {
        if let mimeType, !mimeType.hasPrefix("image/") { return nil }

        let location = await assetStore.location(of: id)
        guard FileManager.default.fileExists(atPath: location.path),
            let source = CGImageSourceCreateWithURL(location as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }

        return PixelSize(width: width, height: height)
    }
}
