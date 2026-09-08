import CryptoKit
import Foundation
import ReiCore
import ReiProtocol

enum OneBotFileError: Error, LocalizedError {
    case invalid(String)
    case unsupported(String)
    case unavailable(String)
    case unknownFile

    var retcode: Int {
        switch self {
        case .invalid: 10003
        case .unsupported: 10004
        case .unavailable: 32000
        case .unknownFile: 35000
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .unsupported(let message), .unavailable(let message): message
        case .unknownFile: "Unknown file_id"
        }
    }
}

/// File-transfer state belongs to the connection implementation. Completed files
/// are handed to the shared asset store, while partial uploads have no public ID.
actor OneBotFileService {
    private struct Upload {
        let name: String
        let size: Int64
        let location: URL
        var ranges: [Range<Int64>] = []
    }

    private let resolver: AssetResolver
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "rei-upload-\(UUID().uuidString)")
    private var uploads: [String: Upload] = [:]

    init(resolver: AssetResolver) { self.resolver = resolver }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func upload(_ call: ProtocolCall) async throws -> ProtocolReply {
        let name = try string("name", from: call)
        let data: Data
        switch try string("type", from: call) {
        case "data":
            data = try bytes(from: call)
        case "path":
            let path = try string("path", from: call)
            guard path.hasPrefix("/") else { throw OneBotFileError.invalid("path must be absolute") }
            data = try await resolver.read(from: URL(fileURLWithPath: path), headers: [:])
        case "url":
            let address = try string("url", from: call)
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw OneBotFileError.invalid("url must use HTTP or HTTPS")
            }
            var headers: [String: String] = [:]
            if let rawHeaders = call.parameters["headers"] {
                guard let values = rawHeaders.objectValue else {
                    throw OneBotFileError.invalid("headers must be a map")
                }
                for (key, value) in values {
                    guard case .string(let text) = value else {
                        throw OneBotFileError.invalid("headers values must be strings")
                    }
                    headers[key] = text
                }
            }
            data = try await resolver.read(from: url, headers: headers)
        default:
            throw OneBotFileError.unsupported("Unsupported upload type")
        }
        try verify(data, expected: call.parameters["sha256"])
        let asset = try await store(data, name: name)
        return .success(["file_id": .string(asset.id)])
    }

    func get(_ call: ProtocolCall) async throws -> ProtocolReply {
        let asset = try await asset(from: call)
        var result: [String: JSONValue] = ["name": .string(asset.name), "sha256": .string(asset.id)]
        switch try string("type", from: call) {
        case "url":
            let reference = await resolver.reference(for: asset, version: .v12)
            result["url"] = .string(reference.url)
        case "path":
            let reference = await resolver.reference(for: asset, version: .v11)
            result["path"] = .string(reference.identifier)
        case "data":
            result["data"] = .string(try await data(for: asset).base64EncodedString())
        default:
            throw OneBotFileError.unsupported("Unsupported download type")
        }
        return .success(.object(result))
    }

    func uploadFragmented(_ call: ProtocolCall) async throws -> ProtocolReply {
        switch try string("stage", from: call) {
        case "prepare":
            let name = try string("name", from: call)
            let size = try nonnegativeInteger("total_size", from: call)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let location = directory.appendingPathComponent(id)
            try Data().write(to: location)
            uploads[id] = Upload(name: name, size: size, location: location)
            return .success(["file_id": .string(id)])
        case "transfer":
            let id = try string("file_id", from: call)
            guard var upload = uploads[id] else { throw OneBotFileError.invalid("Unknown upload file_id") }
            let offset = try nonnegativeInteger("offset", from: call)
            let data = try bytes(from: call)
            guard offset <= upload.size, Int64(data.count) <= upload.size - offset else {
                throw OneBotFileError.invalid("Chunk exceeds total_size")
            }
            let handle = try FileHandle(forWritingTo: upload.location)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            if !data.isEmpty {
                upload.ranges = Self.merged(upload.ranges + [offset..<(offset + Int64(data.count))])
            }
            uploads[id] = upload
            return .success(.null)
        case "finish":
            let id = try string("file_id", from: call)
            guard let upload = uploads[id] else { throw OneBotFileError.invalid("Unknown upload file_id") }
            guard upload.size == 0 || upload.ranges == [0..<upload.size] else {
                throw OneBotFileError.invalid("Upload still has missing chunks")
            }
            let expected = try string("sha256", from: call)
            let contents = try Data(contentsOf: upload.location, options: .mappedIfSafe)
            try verify(contents, expected: .string(expected))
            // Consume the completed session before suspending so concurrent finish
            // calls cannot independently complete the same temporary upload.
            uploads[id] = nil
            do {
                let asset = try await store(contents, name: upload.name)
                try FileManager.default.removeItem(at: upload.location)
                return .success(["file_id": .string(asset.id)])
            } catch {
                uploads[id] = upload
                throw error
            }
        default:
            throw OneBotFileError.unsupported("Unsupported upload stage")
        }
    }

    func getFragmented(_ call: ProtocolCall) async throws -> ProtocolReply {
        let asset = try await asset(from: call)
        switch try string("stage", from: call) {
        case "prepare":
            return .success([
                "name": .string(asset.name), "total_size": .number(Double(asset.byteCount)),
                "sha256": .string(asset.id),
            ])
        case "transfer":
            let offset = try nonnegativeInteger("offset", from: call)
            let size = try nonnegativeInteger("size", from: call)
            guard offset <= asset.byteCount, size <= Int64(asset.byteCount) - offset else {
                throw OneBotFileError.invalid("Requested range exceeds file size")
            }
            let slice = try await resolver.data(for: asset, range: offset..<(offset + size))
            return .success(["data": .string(slice.base64EncodedString())])
        default:
            throw OneBotFileError.unsupported("Unsupported download stage")
        }
    }

    private func asset(from call: ProtocolCall) async throws -> Asset {
        let id = try string("file_id", from: call)
        guard let asset = await resolver.asset(forIdentifier: id, kind: .file) else {
            throw OneBotFileError.unknownFile
        }
        return asset
    }

    private func store(_ data: Data, name: String) async throws -> Asset {
        guard let asset = await resolver.store(data: data, name: name) else {
            throw OneBotFileError.unavailable("Could not store uploaded file")
        }
        return asset
    }

    private func data(for asset: Asset) async throws -> Data {
        guard let data = await resolver.data(for: asset) else {
            throw OneBotFileError.unavailable("File is unavailable")
        }
        return data
    }

    private func string(_ key: String, from call: ProtocolCall) throws -> String {
        guard case .string(let value) = call.parameters[key] else {
            throw OneBotFileError.invalid("Missing or invalid \(key)")
        }
        return value
    }

    private func nonnegativeInteger(_ key: String, from call: ProtocolCall) throws -> Int64 {
        guard case .number(let value) = call.parameters[key], value.isFinite,
            value >= 0, value.rounded(.towardZero) == value, let integer = Int64(exactly: value)
        else { throw OneBotFileError.invalid("\(key) must be a nonnegative integer") }
        return integer
    }

    private func bytes(from call: ProtocolCall) throws -> Data {
        guard let data = Data(base64Encoded: try string("data", from: call)) else {
            throw OneBotFileError.invalid("data must be Base64 encoded")
        }
        return data
    }

    private func verify(_ data: Data, expected: JSONValue?) throws {
        guard let expected else { return }
        guard case .string(let hash) = expected, hash == Self.sha256(data) else {
            throw OneBotFileError.invalid("SHA256 checksum mismatch")
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func merged(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        var result: [Range<Int64>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
