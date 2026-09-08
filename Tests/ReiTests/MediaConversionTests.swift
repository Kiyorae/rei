import AVFoundation
import Foundation
import ReiCore
import Testing

@testable import ReiProtocol

@Suite("Media Conversion")
struct MediaConversionTests {
    @Test("Tencent and standard SILK V3 frames decode to real playable PCM without FFmpeg")
    func silkConversion() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = MediaService(assetStore: try AssetStore(directory: directory), store: try ReiStore())
        let converter = MediaConversionService(media: media, ffmpegURL: URL(fileURLWithPath: "/missing/ffmpeg"))
        let tencent = try #require(Data(base64Encoded: Self.tencentSilk))
        var standard = Data(tencent.dropFirst())
        standard.append(contentsOf: [255, 255])
        for data in [tencent, standard] {
            let source = try #require(await media.store(data: data, name: "voice.silk", mimeType: "audio/silk"))
            let wave = try await converter.convertAudio(asset: source, to: "wav")
            #expect(wave.mimeType == "audio/wav")
            #expect(wave.name == "voice.wav")
            let url = URL(fileURLWithPath: await media.path(for: wave.id))
            let audio = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "audio/wav"])
            #expect(try await audio.load(.isPlayable))
            #expect(abs(try await audio.load(.duration).seconds - 0.2) < 0.01)
            let bytes = try #require(await media.data(for: wave.id))
            #expect(bytes.starts(with: Array("RIFF".utf8)))
            #expect(bytes.count == 44 + 9_600)
            #expect(bytes.dropFirst(44).contains(where: { $0 != 0 }))
            let cached = try await converter.convertAudio(asset: source, to: "wav")
            #expect(cached.id == wave.id)
        }
    }

    @Test("SILK framing rejects truncated packets, oversized frames, and invalid trailers")
    func malformedSilk() throws {
        let valid = try #require(Data(base64Encoded: Self.tencentSilk))
        for data in [
            Data("#!SILK_V3".utf8),
            Data(valid.dropLast()),
            Data("#!SILK_V3".utf8) + Data([255, 127]),
            Data("#!SILK_V3".utf8) + Data([255, 255, 0]),
        ] {
            #expect(throws: MediaConversionError.self) { try SilkAudioDecoder.wave(from: data) }
        }
    }

    @Test("The bundled converter decodes AMR and produces every OneBot V11 record output format")
    func amrAndOutputFormats() async throws {
        guard let path = ProcessInfo.processInfo.environment["REI_TEST_FFMPEG"] else {
            Issue.record("REI_TEST_FFMPEG is required; run the repository's make test workflow.")
            return
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = MediaService(assetStore: try AssetStore(directory: directory), store: try ReiStore())
        let converter = MediaConversionService(media: media, ffmpegURL: URL(fileURLWithPath: path))
        // AMR-NB MIME framing: ten 20 ms, 12.2 kbps speech frames, Q=1.
        // The zero codewords are a synthetic encoded signal, not a recording.
        let amr =
            Data("#!AMR\n".utf8)
            + Data(Array(repeating: [UInt8(0x3c)] + [UInt8](repeating: 0, count: 31), count: 10).joined())
        let source = try #require(await media.store(data: amr, name: "voice.amr", mimeType: "audio/amr"))
        let decoded = try await converter.convertAudio(asset: source, to: "wav")
        let decodedURL = URL(fileURLWithPath: await media.path(for: decoded.id))
        let audio = AVURLAsset(url: decodedURL, options: [AVURLAssetOverrideMIMETypeKey: "audio/wav"])
        #expect(try await audio.load(.isPlayable))
        #expect(abs(try await audio.load(.duration).seconds - 0.2) < 0.01)

        for format in ["mp3", "amr", "wma", "m4a", "spx", "ogg", "wav", "flac"] {
            let result = try await converter.convertAudio(asset: decoded, to: format)
            #expect(result.name.hasSuffix("." + format))
            #expect(result.byteCount > 0)
            #expect(await media.exists(result.id))
            let roundTrip = try await converter.convertAudio(asset: result, to: "wav")
            let roundTripURL = URL(fileURLWithPath: await media.path(for: roundTrip.id))
            let roundTripAudio = AVURLAsset(url: roundTripURL, options: [AVURLAssetOverrideMIMETypeKey: "audio/wav"])
            #expect(try await roundTripAudio.load(.isPlayable))
        }
    }

    @Test("Unsupported output formats fail before spawning an executable")
    func invalidOutput() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = MediaService(assetStore: try AssetStore(directory: directory), store: try ReiStore())
        let converter = MediaConversionService(media: media, ffmpegURL: URL(fileURLWithPath: "/missing/ffmpeg"))
        let source = Asset(id: "missing", name: "voice.wav", source: .inline)
        await #expect(throws: MediaConversionError.self) {
            try await converter.convertAudio(asset: source, to: "wav; touch /tmp/injected")
        }
    }

    @Test("Video conversion retains the picture, dimensions, and duration in a playable MP4")
    func videoConversion() async throws {
        guard let path = ProcessInfo.processInfo.environment["REI_TEST_FFMPEG"] else {
            Issue.record("REI_TEST_FFMPEG is required; run the repository's make test workflow.")
            return
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = MediaService(assetStore: try AssetStore(directory: directory), store: try ReiStore())
        let converter = MediaConversionService(media: media, ffmpegURL: URL(fileURLWithPath: path))
        let bytes = try #require(Data(base64Encoded: Self.ffv1Video))
        let source = try #require(await media.store(data: bytes, name: "video.mkv", mimeType: "video/x-matroska"))
        let converted = try await converter.convertVideo(asset: source)
        #expect(converted.mimeType == "video/mp4")
        let url = URL(fileURLWithPath: await media.path(for: converted.id))
        let video = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        #expect(try await video.load(.isPlayable))
        #expect(abs(try await video.load(.duration).seconds - 0.2) < 0.01)
        let tracks = try await video.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 32, height: 32))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Rei-MediaConversion-\(UUID().uuidString)")
    }

    // Generated from a 0.2-second 440 Hz tone with the pinned SDK's encoder:
    // encoder tone.pcm voice.silk -Fs_API 24000 -rate 24000 -tencent -quiet
    private static let tencentSilk =
        "AiMhU0lMS19WMyUAg9cYgovZWromSIoxdKHkN4yDtsEpEVZr29gwi7WCZ04MVlxz/y4AfrR+sRgw4FVCSh42PXJKWghkQ1A1S82T9ol7LE9CL/vt/QHmc5JyMdoVrJQgrzUAfoTnl+6QKWVt3sqEdx1gV49bL5QuezIHy6/yINi/5okG/tzoOW8g+FBL2OXP+c6FEsyVrf9AAH6DPLRebib/l1dsxRdVIGshQ1K7x8RxRohj3mOv77DlgV6UUQRoVeGeP+E18Yhy6JHIhKcyOsB6aQJCZsxQ6f8mAH6DPFWzT+PAEn+WZl7BT6vDcNbKHu/7FlqwL+JONmtad4PkHS9pOAB+gzyvwrOLRNdjtTlRldHMOXA5xc5sIpHQja7Vw8c3ojL2/n+xOOPIBqkqnVlzuVtX3gX16J0VvyYAfoTnl+6Saqtlr4uGrj4kRzuWdaHnjAt8MaDizcPqgRd7xVO0kx9GAH6DPLRebib/l1eCDi5/fkQqCAbrKLsAPZ1/zOFKXmMNPl31M56n7eE3kJu+/csSP9yQeVSkDENRCTNz7/n20rePVQ4wmbtGAH6DPLRebib/l1deC8TNfR8ZKWDXHEj47ATvZicDoFvhnX+ep//K5BZ1J7F9yFShFKEjW3k8gZ8zfnIv231LAaDGnsjwa58+AH6DPFWzT+PAEn+bnQmR+oENe37Elhfd9RZQBGrV4WU1dkwxlfpK9AFaqZZENPDAxT+6B49rP5A/oGcAe/Zf"
    // Synthetic two-frame FFV1 Matroska, generated with FFmpeg from a 32x32 teal color source.
    private static let ffv1Video =
        "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAC1hFNm3TAv4QrAsu8TbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yBzE27jFOrhBJUw2dTrIIBXU27jFOrhBxTu2tTrIICuuwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZqa/hBsTTFoq17GDD0JATYCETGF2ZldBhExhdmZEiYhAaQAAAAAAABZUrmtAi7+EMiR6ya4BAAAAAAAAfNeBAXPFiAAAAAAAAAABnIEAIrWcg3VuZIiBAIaGVl9GRlYxg4EBI+ODhAX14QDgkLCBILqBIJqBAlWwhFW5gQFV7oEA7AEAAAAAAAACAABjoqpWK4TRnAUvQTxgJulcN29dG3aXnTrJxCBDHoufVSBRL074oWg7mxcTfAMSVMNn1L+EBs/SznNzy2PAi2PFiAAAAAAAAAABZ8iWRaOHRU5DT0RFUkSHiUxhdmMgZmZ2MWfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDAuMjAwMDAwMDAwAB9DtnVA/r+EmQ4lReeBAKNAgIEAAID8FYAABWyv/5////4ADOlfP//ih/v//gAAFwAy7R2BPd6AAAVsr/+f///+AAzpXz//4of7//4AABcAAssARpwckwAFbK//n////gAM6V8//+KH+//+AAAXAJACXv8Qvz0ABWyv/5////4ADOlfP//ih/v//gAAFwAmiPuko/CBAGQAfJWAHb//3////hZ/3//yR////gAAEwBp2A1XPd6AHb//3////hZ/3//yR////gAAEwBr2G1wnByTHb//3////hZ/3//yR////gAAEwBKrNlxEL89Hb//3////hZ/3//yR////gAAEwBevN2+HFO7a5e/hLW6iQC7j7OBALeK94EB8YIBtvCBCQ=="

}
