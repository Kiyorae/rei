import CSilk
import Foundation

/// Parses the Skype/Tencent SILK V3 framing before calling the bundled SDK.
enum SilkAudioDecoder {
    private static let header = Array("#!SILK_V3".utf8)

    static func recognizes(_ data: Data) -> Bool {
        data.starts(with: header) || data.starts(with: [2] + header)
    }

    static func wave(from data: Data) throws -> Data {
        guard recognizes(data), let decoder = rei_silk_decoder_create() else {
            throw MediaConversionError.invalidAudio
        }
        defer { rei_silk_decoder_destroy(decoder) }
        var offset = data.first == 2 ? header.count + 1 : header.count
        var pcm = Data()
        var samples = [Int16](repeating: 0, count: 480)
        while offset < data.count {
            guard data.count - offset >= 2 else { throw MediaConversionError.invalidAudio }
            let length = Int(Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8))
            offset += 2
            if length == -1 {
                guard offset == data.count else { throw MediaConversionError.invalidAudio }
                break
            }
            guard length >= 0, length <= 1_024, length <= data.count - offset else {
                throw MediaConversionError.invalidAudio
            }
            var more: Int32 = 0
            var frames = 0
            repeat {
                guard frames < 5 else { throw MediaConversionError.invalidAudio }
                var sampleCount: Int16 = 480
                let result = data.withUnsafeBytes { bytes in
                    rei_silk_decode_frame(
                        decoder, bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), length,
                        &samples, &sampleCount, &more
                    )
                }
                guard result == 0, sampleCount > 0, sampleCount <= 480 else {
                    throw MediaConversionError.invalidAudio
                }
                samples.withUnsafeBytes { pcm.append(contentsOf: $0.prefix(Int(sampleCount) * 2)) }
                frames += 1
            } while more != 0
            offset += length
        }
        guard !pcm.isEmpty, pcm.count <= Int(UInt32.max) - 36 else { throw MediaConversionError.invalidAudio }
        var wave = Data()
        func text(_ value: String) { wave.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wave.append(contentsOf: $0) }
        }
        text("RIFF")
        integer(UInt32(pcm.count + 36))
        text("WAVEfmt ")
        integer(UInt32(16))
        integer(UInt16(1))
        integer(UInt16(1))
        integer(UInt32(24_000))
        integer(UInt32(48_000))
        integer(UInt16(2))
        integer(UInt16(16))
        text("data")
        integer(UInt32(pcm.count))
        wave.append(pcm)
        return wave
    }
}
