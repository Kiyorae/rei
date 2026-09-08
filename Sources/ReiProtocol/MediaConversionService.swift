import Darwin
import Foundation
import ReiCore

/// Shared audio conversion for playback and protocol media retrieval.
/// The app ships its own FFmpeg; callers can explicitly inject a tool for tests.
public actor MediaConversionService {
    public static let supportedAudioFormats: Set<String> = ["mp3", "amr", "wma", "m4a", "spx", "ogg", "wav", "flac"]

    private let media: MediaService
    private let ffmpegURL: URL?
    private var conversions: [ConversionKey: Task<Asset, any Error>] = [:]

    public init(media: MediaService, ffmpegURL: URL? = nil) {
        self.media = media
        self.ffmpegURL = ffmpegURL ?? Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")
    }

    public func convertAudio(asset: Asset, to format: String) async throws -> Asset {
        guard Self.supportedAudioFormats.contains(format) else { throw MediaConversionError.unsupportedFormat(format) }
        return try await convert(asset: asset, format: format, isVideo: false)
    }

    public func convertVideo(asset: Asset) async throws -> Asset {
        try await convert(asset: asset, format: "mp4", isVideo: true)
    }

    private func convert(asset: Asset, format: String, isVideo: Bool) async throws -> Asset {
        let key = ConversionKey(assetID: asset.id, format: format, isVideo: isVideo)
        if let conversion = conversions[key] { return try await conversion.value }
        let media = media
        let executable = ffmpegURL
        let task = Task {
            guard await media.exists(asset.id), let data = await media.data(for: asset.id) else {
                throw MediaConversionError.missingAttachment
            }
            let source = URL(fileURLWithPath: await media.path(for: asset.id))
            let converted = try await Task.detached(priority: .userInitiated) {
                try Self.convert(data: data, source: source, format: format, isVideo: isVideo, executable: executable)
            }.value
            let name = ((asset.name as NSString).lastPathComponent as NSString).deletingPathExtension + "." + format
            guard let result = await media.store(data: converted, name: name, mimeType: Self.mimeType(for: format))
            else {
                throw MediaConversionError.storageFailure
            }
            return result
        }
        conversions[key] = task
        do {
            return try await task.value
        } catch {
            conversions[key] = nil
            throw error
        }
    }

    private struct ConversionKey: Hashable {
        var assetID: String
        var format: String
        var isVideo: Bool
    }

    private static func convert(data: Data, source: URL, format: String, isVideo: Bool, executable: URL?) throws -> Data
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rei-Conversion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var input = source
        if !isVideo, SilkAudioDecoder.recognizes(data) {
            let wave = try SilkAudioDecoder.wave(from: data)
            if format == "wav" { return wave }
            input = directory.appendingPathComponent("decoded.wav")
            try wave.write(to: input)
        }
        guard let executable, executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MediaConversionError.converterUnavailable
        }
        let output = directory.appendingPathComponent("converted." + format)
        // Restrict input to self-contained media. Playlist and concat demuxers can
        // read unrelated files or URLs and are never valid voice attachments.
        let demuxers = "aac,ac3,aiff,amr,asf,au,avi,flac,matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,mp3,ogg,wav"
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-protocol_whitelist", "file,pipe", "-format_whitelist", demuxers,
            "-i", input.path, "-sn", "-dn", "-map_metadata", "-1",
        ]
        if isVideo {
            arguments += [
                "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "h264_videotoolbox", "-allow_sw", "1",
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart",
            ]
        } else {
            arguments += ["-map", "0:a:0", "-vn"] + encodingArguments(for: format)
        }
        arguments += [output.path]
        try run(executable: executable, arguments: arguments, in: directory)
        let result = try Data(contentsOf: output)
        guard !result.isEmpty else { throw MediaConversionError.invalidAudio }
        return result
    }

    private static func encodingArguments(for format: String) -> [String] {
        switch format {
        case "mp3": return ["-c:a", "libmp3lame"]
        case "amr": return ["-c:a", "libopencore_amrnb", "-ar", "8000", "-ac", "1", "-b:a", "12.2k"]
        case "wma": return ["-c:a", "wmav2"]
        case "m4a": return ["-c:a", "aac"]
        case "spx": return ["-c:a", "libspeex", "-ar", "16000", "-ac", "1"]
        case "ogg": return ["-c:a", "vorbis", "-strict", "experimental", "-ac", "2"]
        case "flac": return ["-c:a", "flac"]
        default: return ["-c:a", "pcm_s16le"]
        }
    }

    private static func mimeType(for format: String) -> String {
        switch format {
        case "mp3": return "audio/mpeg"
        case "amr": return "audio/amr"
        case "wma": return "audio/x-ms-wma"
        case "m4a": return "audio/mp4"
        case "spx", "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        case "mp4": return "video/mp4"
        default: return "audio/wav"
        }
    }

    /// A temporary stderr file avoids pipe-buffer deadlocks. The bounded wait runs
    /// on a detached worker and always reaps the child before deleting its files.
    private static func run(executable: URL, arguments: [String], in directory: URL) throws {
        let stderrURL = directory.appendingPathComponent("stderr.log")
        guard FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw MediaConversionError.storageFailure
        }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw MediaConversionError.timedOut
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw MediaConversionError.failed(process.terminationStatus)
        }
    }
}

public enum MediaConversionError: Error, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case converterUnavailable
    case missingAttachment
    case invalidAudio
    case storageFailure
    case timedOut
    case failed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): return "Unsupported audio output format: \(format)."
        case .converterUnavailable: return "The bundled media converter is missing. Reinstall Rei to restore playback."
        case .missingAttachment: return "The attachment is no longer available in the media cache."
        case .invalidAudio: return "The attachment does not contain valid audio."
        case .storageFailure: return "The converted attachment could not be saved."
        case .timedOut: return "Media conversion took too long."
        case .failed(let status): return "Media conversion failed (status \(status))."
        }
    }
}
