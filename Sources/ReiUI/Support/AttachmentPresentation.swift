import AVFoundation
import AppKit
import Foundation
import ImageIO
import ReiCore

/// File I/O for native previews and exports. All inputs are resolved cache files;
/// an attachment's original URL never becomes an executable or a navigation target.
enum AttachmentFiles {
    static func fileName(for asset: Asset) -> String {
        let leaf = (asset.name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let cleaned = leaf.components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "Attachment" }
        let fileExtension = (cleaned as NSString).pathExtension
        let suffix = fileExtension.utf8.count <= 32 && !fileExtension.isEmpty ? "." + fileExtension : ""
        var stem = suffix.isEmpty ? cleaned : String(cleaned.dropLast(suffix.count))
        while stem.utf8.count + suffix.utf8.count > 240 { stem.removeLast() }
        return stem + suffix
    }

    /// Quick Look needs the original file extension, while stored assets are named
    /// by their hash. The unique directory is owned by the presenting view.
    static func previewCopy(of asset: Asset, from source: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Rei-Preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(fileName(for: asset))
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    /// NSSavePanel has already obtained the destination and any overwrite consent.
    /// Atomic replacement keeps the previous file intact if writing fails.
    static func save(from source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard source.isFileURL, destination.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            try data.write(to: destination, options: .atomic)
        }.value
    }
}

@MainActor
enum AttachmentSavePanel {
    static func destination(for asset: Asset) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Attachment"
        panel.nameFieldStringValue = AttachmentFiles.fileName(for: asset)
        panel.canCreateDirectories = true
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

enum AttachmentImages {
    static func thumbnail(at url: URL) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480,
                    ] as CFDictionary
                )
            else { throw CocoaError(.fileReadCorruptFile) }
            return image
        }.value
    }
}

@MainActor
enum AttachmentPlayback {
    static func load(from url: URL, mimeType: String? = nil) async throws -> AVPlayer {
        let options = mimeType.map { [AVURLAssetOverrideMIMETypeKey: $0] }
        let asset = AVURLAsset(url: url, options: options)
        guard try await asset.load(.isPlayable) else { throw PlaybackError.unsupportedFormat }
        try Task.checkCancellation()
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    enum PlaybackError: LocalizedError {
        case unsupportedFormat

        var errorDescription: String? { "This media format could not be played." }
    }
}
