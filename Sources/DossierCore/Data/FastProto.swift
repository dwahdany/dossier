import Foundation
import Compression

// MARK: - Allocation-free protobuf field walker

/// A wire value inside a memory buffer (no copies; valid only inside the walk closure).
public enum PBValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(UnsafeRawBufferPointer)
}

/// Minimal protobuf reader for hot paths (aggregations over 100k+ records, table cells):
/// walks fields in place instead of building a ``ProtoMessage`` tree, which allocates an
/// array per record.
///
/// ```swift
/// FastProto.scan(record.payload) { field, value in
///     switch (field, value) {
///     case (2, .fixed64(let bits)): time = FastProto.double(bits)
///     case (6, .bytes(let b)): bundle = FastProto.string(b)
///     default: break
///     }
/// }
/// ```
public enum FastProto {
    /// Calls `body` for every top-level field. Returns false if the buffer is malformed
    /// (fields seen before the error have already been reported).
    @discardableResult
    public static func forEach(_ buf: UnsafeRawBufferPointer, _ body: (Int, PBValue) -> Void) -> Bool {
        let count = buf.count
        var pos = 0

        @inline(__always) func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while pos < count {
                let b = buf[pos]; pos += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        while pos < count {
            guard let key = readVarint() else { return false }
            let number = Int(key >> 3)
            guard number > 0, number < (1 << 29) else { return false }
            switch key & 7 {
            case 0:
                guard let v = readVarint() else { return false }
                body(number, .varint(v))
            case 1:
                guard pos + 8 <= count else { return false }
                body(number, .fixed64(UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: pos, as: UInt64.self))))
                pos += 8
            case 2:
                guard let len = readVarint(), len <= UInt64(count - pos) else { return false }
                let n = Int(len)
                body(number, .bytes(UnsafeRawBufferPointer(rebasing: buf[pos..<(pos + n)])))
                pos += n
            case 5:
                guard pos + 4 <= count else { return false }
                body(number, .fixed32(UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: pos, as: UInt32.self))))
                pos += 4
            default:
                return false
            }
        }
        return true
    }

    /// ``forEach(_:_:)`` over a `Data` payload.
    @discardableResult
    public static func scan(_ data: Data, _ body: (Int, PBValue) -> Void) -> Bool {
        data.withUnsafeBytes { forEach($0, body) }
    }

    /// Visits every value found at `path`, following repeated fields at each level.
    public static func collect(_ buf: UnsafeRawBufferPointer, path: ArraySlice<Int>, _ visit: (PBValue) -> Void) {
        guard let first = path.first else { return }
        let rest = path.dropFirst()
        forEach(buf) { number, value in
            guard number == first else { return }
            if rest.isEmpty {
                visit(value)
            } else if case .bytes(let sub) = value {
                collect(sub, path: rest, visit)
            }
        }
    }

    /// First UTF-8 string at `path` (nil if absent or not valid UTF-8).
    public static func string(_ buf: UnsafeRawBufferPointer, _ path: [Int]) -> String? {
        var out: String?
        collect(buf, path: path[...]) { value in
            if out == nil, case .bytes(let b) = value { out = String(bytes: b, encoding: .utf8) }
        }
        return out
    }

    /// First numeric value at `path` as a double (fixed64 → double, varint → integer).
    public static func double(_ buf: UnsafeRawBufferPointer, _ path: [Int]) -> Double? {
        var out: Double?
        collect(buf, path: path[...]) { value in
            guard out == nil else { return }
            switch value {
            case .fixed64(let v): out = Double(bitPattern: v)
            case .varint(let v): out = Double(Int64(bitPattern: v))
            case .fixed32(let v): out = Double(Float(bitPattern: v))
            case .bytes: break
            }
        }
        return out
    }

    /// Lossy UTF-8 decoding of a length-delimited value (invalid bytes become U+FFFD).
    public static func string(_ bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// The double stored in a fixed64 field.
    public static func double(_ bits: UInt64) -> Double { Double(bitPattern: bits) }
}

/// Case-insensitive (ASCII) substring search over raw bytes. Works on undecoded payloads,
/// so it finds text inside nested messages as well.
public struct ByteNeedle: Sendable {
    private let lower: [UInt8]
    public init(_ text: String) { lower = Array(text.lowercased().utf8) }
    public var isEmpty: Bool { lower.isEmpty }

    public func matches(_ data: Data) -> Bool {
        if lower.isEmpty { return true }
        return data.withUnsafeBytes { raw -> Bool in
            let n = raw.count, m = lower.count
            guard n >= m else { return false }
            let first = lower[0]
            var i = 0
            let last = n - m
            while i <= last {
                var c = raw[i]
                if c >= 65 && c <= 90 { c += 32 }
                if c == first {
                    var j = 1
                    while j < m {
                        var d = raw[i + j]
                        if d >= 65 && d <= 90 { d += 32 }
                        if d != lower[j] { break }
                        j += 1
                    }
                    if j == m { return true }
                }
                i += 1
            }
            return false
        }
    }
}

// MARK: - LZFSE

public enum LZFSE {
    /// Decompresses an LZFSE stream (`bvx…` blocks). Returns nil when the input is not a
    /// valid stream or would expand beyond `limit` bytes.
    public static func decode(_ input: Data, limit: Int = 64 << 20) -> Data? {
        if input.isEmpty { return Data() }
        var capacity = max(input.count * 6, 16 << 10)
        while true {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            let written = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(buffer, capacity, base, input.count, nil, COMPRESSION_LZFSE)
            }
            if written == 0 { buffer.deallocate(); return nil }
            if written < capacity {
                return Data(bytesNoCopy: buffer, count: written, deallocator: .custom { pointer, _ in
                    pointer.assumingMemoryBound(to: UInt8.self).deallocate()
                })
            }
            buffer.deallocate()
            if capacity >= limit { return nil }
            capacity = min(capacity * 4, limit)
        }
    }

    /// An LZFSE stream that stores `data` uncompressed (`bvx-` block + `bvx$` end marker):
    /// the form the demo-data generators write, since they have no LZFSE encoder.
    public static func stored(_ data: Data) -> Data {
        var out = Data([0x62, 0x76, 0x78, 0x2D])
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(data)
        out.append(contentsOf: [0x62, 0x76, 0x78, 0x24])
        return out
    }

    /// Self-test: the system decoder reads a stored-block stream like a compressed one.
    public static func selfTest() -> [SelfTestLine] {
        let sample = Data((0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let decoded = decode(stored(sample))
        return [.check("LZFSE: uncompressed-block stream decodes", decoded == sample,
                       decoded == sample ? "\(sample.count) bytes round-trip through bvx- / bvx$ framing" : "decoder returned \(decoded?.count ?? -1) bytes")]
    }
}
