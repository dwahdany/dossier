import Foundation
import Compression

/// Minimal read-only ZIP reader for small in-memory archives (the `.pkpass` bundles that
/// Suggestions embeds in its database). Supports stored and deflated entries, sizes are
/// taken from the central directory (so entries written with a data descriptor work).
struct ZipArchive: Sendable {
    struct Entry: Sendable, Hashable, Identifiable {
        var id: String { name }
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let data: Data
    let entries: [Entry]

    /// Upper bound for a single inflated entry (passes are a few hundred kB at most).
    static let maxEntrySize = 16 << 20

    init?(_ data: Data) {
        let bytes = Data(data) // re-base indices to 0
        guard bytes.count >= 22 else { return nil }
        // End-of-central-directory record: search backwards for its signature.
        var eocd = -1
        let lowest = max(0, bytes.count - 22 - 65_535)
        var i = bytes.count - 22
        while i >= lowest {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = Int(ZipArchive.u16(bytes, eocd + 10))
        var offset = Int(ZipArchive.u32(bytes, eocd + 16))
        var list: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, ZipArchive.u32(bytes, offset) == 0x0201_4b50 else { break }
            let method = ZipArchive.u16(bytes, offset + 10)
            let compressed = Int(ZipArchive.u32(bytes, offset + 20))
            let uncompressed = Int(ZipArchive.u32(bytes, offset + 24))
            let nameLength = Int(ZipArchive.u16(bytes, offset + 28))
            let extraLength = Int(ZipArchive.u16(bytes, offset + 30))
            let commentLength = Int(ZipArchive.u16(bytes, offset + 32))
            let local = Int(ZipArchive.u32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { break }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            list.append(Entry(name: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: local))
            offset += 46 + nameLength + extraLength + commentLength
        }
        guard !list.isEmpty else { return nil }
        self.data = bytes
        self.entries = list
    }

    func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// Contents of an entry; nil if it is corrupt, encrypted, too large or uses an
    /// unsupported compression method.
    func contents(of entry: Entry) -> Data? {
        let o = entry.localHeaderOffset
        guard o >= 0, o + 30 <= data.count, ZipArchive.u32(data, o) == 0x0403_4b50 else { return nil }
        let nameLength = Int(ZipArchive.u16(data, o + 26))
        let extraLength = Int(ZipArchive.u16(data, o + 28))
        let start = o + 30 + nameLength + extraLength
        guard start >= 0, entry.compressedSize >= 0, start + entry.compressedSize <= data.count else { return nil }
        let raw = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return raw
        case 8:
            guard entry.uncompressedSize >= 0, entry.uncompressedSize <= ZipArchive.maxEntrySize else { return nil }
            if entry.uncompressedSize == 0 { return Data() }
            return ZipArchive.inflate(raw, expected: entry.uncompressedSize)
        default:
            return nil
        }
    }

    func contents(named name: String) -> Data? { entry(named: name).flatMap(contents(of:)) }

    private static func inflate(_ raw: Data, expected: Int) -> Data? {
        var output = Data(count: expected)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expected, s, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { return nil }
        return output
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
}
