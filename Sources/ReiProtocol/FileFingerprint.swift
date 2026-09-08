import CryptoKit
import Foundation

/// QQ's private-file fingerprint: SHA1 over either the complete file (<=30 MiB)
/// or 10 MiB samples at the beginning, middle, and end, followed by its 64-bit
/// little-endian length. The algorithm is documented by Lagrange.Core's
/// Utility/Cryptography/TriSha1Provider.cs stream implementation.
public enum FileFingerprint {
    public static func triSHA1(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let chunk = 10 * 1024 * 1024
        var hash = Insecure.SHA1()
        let samples: [(UInt64, Int)]
        if size <= UInt64(3 * chunk) {
            samples = [(0, Int(size))]
        } else {
            let middle = size / 2 - UInt64(chunk / 2)
            let end = size - UInt64(chunk)
            samples = [(0, chunk), (middle, chunk), (end, chunk)]
        }
        for (offset, count) in samples {
            try handle.seek(toOffset: offset)
            guard let bytes = try handle.read(upToCount: count), bytes.count == count else {
                if count == 0 { continue }
                throw CocoaError(.fileReadCorruptFile)
            }
            hash.update(data: bytes)
        }
        var littleEndianSize = size.littleEndian
        withUnsafeBytes(of: &littleEndianSize) { hash.update(bufferPointer: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
