import Foundation

/// Schema-less protobuf wire-format decoder.
///
/// Biome payloads are protobuf messages whose `.proto` definitions are not public. This
/// decoder turns bytes into a tree of numbered fields and offers heuristics to interpret
/// length-delimited fields as nested message / UTF-8 string / raw bytes and fixed64 fields
/// as doubles / Cocoa dates.
///
/// ```swift
/// guard let msg = ProtoMessage(payload) else { return }
/// let bundleID = msg[2]?.string          // first field #2 as string
/// let start    = msg[4]?.cocoaDate       // fixed64 double, seconds since 2001
/// let nested   = msg[7]?.message?[1]?.string
/// let all      = msg.all(3).compactMap(\.string)
/// let deep     = msg.string(at: 7, 1)     // path accessor
/// ```
public struct ProtoMessage: Sendable {
    public let fields: [ProtoField]

    /// Strict parse: returns nil unless the *entire* buffer is a well-formed message.
    public init?(_ data: Data, maxFields: Int = 200_000) {
        guard let fields = ProtoMessage.parse(data, maxFields: maxFields) else { return nil }
        self.fields = fields
    }

    private init(fields: [ProtoField]) { self.fields = fields }

    /// First field with the given number.
    public subscript(number: Int) -> ProtoField? { fields.first { $0.number == number } }

    /// All fields with the given number (repeated fields), in wire order.
    public func all(_ number: Int) -> [ProtoField] { fields.filter { $0.number == number } }

    /// Follows nested message fields along `path` and returns the final field.
    public func field(at path: Int...) -> ProtoField? { field(atPath: path) }

    public func field(atPath path: [Int]) -> ProtoField? {
        guard let first = path.first else { return nil }
        guard let f = self[first] else { return nil }
        if path.count == 1 { return f }
        return f.message?.field(atPath: Array(path.dropFirst()))
    }

    public func string(at path: Int...) -> String? { field(atPath: path)?.string }
    public func int(at path: Int...) -> Int64? { field(atPath: path)?.int }
    public func double(at path: Int...) -> Double? { field(atPath: path)?.double }
    public func cocoaDate(at path: Int...) -> Date? { field(atPath: path)?.cocoaDate }

    public var isEmpty: Bool { fields.isEmpty }

    /// All string leaves in depth-first order (handy for previews and search).
    public func allStrings(maxDepth: Int = 6, limit: Int = 64) -> [String] {
        var out: [String] = []
        func walk(_ m: ProtoMessage, _ depth: Int) {
            for f in m.fields {
                if out.count >= limit { return }
                guard case .bytes = f.value else { continue }
                switch f.guess {
                case .string(let s): if !s.isEmpty { out.append(s) }
                case .message(let sub): if depth < maxDepth { walk(sub, depth + 1) }
                default: break
                }
            }
        }
        walk(self, 0)
        return out
    }

    // MARK: Parsing

    private static func parse(_ data: Data, maxFields: Int) -> [ProtoField]? {
        if data.isEmpty { return [] }
        return data.withUnsafeBytes { raw -> [ProtoField]? in
            let count = raw.count
            var pos = 0
            var fields: [ProtoField] = []

            @inline(__always) func readVarint() -> UInt64? {
                var result: UInt64 = 0
                var shift: UInt64 = 0
                while pos < count {
                    let b = raw[pos]; pos += 1
                    result |= UInt64(b & 0x7F) << shift
                    if b & 0x80 == 0 { return result }
                    shift += 7
                    if shift > 63 { return nil }
                }
                return nil
            }

            while pos < count {
                guard let key = readVarint() else { return nil }
                let number = Int(key >> 3)
                let wire = Int(key & 7)
                guard number > 0, number < (1 << 29) else { return nil }
                switch wire {
                case 0:
                    guard let v = readVarint() else { return nil }
                    fields.append(ProtoField(number: number, value: .varint(v)))
                case 1:
                    guard pos + 8 <= count else { return nil }
                    let v = raw.loadUnaligned(fromByteOffset: pos, as: UInt64.self)
                    pos += 8
                    fields.append(ProtoField(number: number, value: .fixed64(UInt64(littleEndian: v))))
                case 2:
                    guard let len = readVarint(), len <= UInt64(count - pos) else { return nil }
                    let n = Int(len)
                    let slice = Data(bytes: raw.baseAddress!.advanced(by: pos), count: n)
                    pos += n
                    fields.append(ProtoField(number: number, value: .bytes(slice)))
                case 5:
                    guard pos + 4 <= count else { return nil }
                    let v = raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self)
                    pos += 4
                    fields.append(ProtoField(number: number, value: .fixed32(UInt32(littleEndian: v))))
                default:
                    return nil  // groups (3/4) and reserved wire types are not used by Apple's messages
                }
                if fields.count > maxFields { return nil }
            }
            return fields
        }
    }
}

/// Raw wire value of a field.
public enum ProtoValue: Sendable, Hashable {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(Data)

    public var wireTypeName: String {
        switch self {
        case .varint: return "varint"
        case .fixed64: return "fixed64"
        case .fixed32: return "fixed32"
        case .bytes: return "bytes"
        }
    }
}

/// Heuristic interpretation of a length-delimited field.
public enum ProtoGuess: Sendable {
    case string(String)
    case message(ProtoMessage)
    case data(Data)
    case number
}

public struct ProtoField: Sendable {
    public let number: Int
    public let value: ProtoValue

    // MARK: Scalars

    /// Unsigned varint / fixed value.
    public var uint: UInt64? {
        switch value {
        case .varint(let v): return v
        case .fixed64(let v): return v
        case .fixed32(let v): return UInt64(v)
        case .bytes: return nil
        }
    }

    /// Signed interpretation (two's complement, as for int32/int64 fields).
    public var int: Int64? {
        switch value {
        case .varint(let v): return Int64(bitPattern: v)
        case .fixed64(let v): return Int64(bitPattern: v)
        case .fixed32(let v): return Int64(Int32(bitPattern: v))
        case .bytes: return nil
        }
    }

    /// ZigZag-decoded value (sint32/sint64 fields).
    public var sint: Int64? {
        guard case .varint(let v) = value else { return nil }
        return Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
    }

    public var bool: Bool? { uint.map { $0 != 0 } }

    /// fixed64 → Double, fixed32 → Float, varint → integer value.
    public var double: Double? {
        switch value {
        case .fixed64(let v): return Double(bitPattern: v)
        case .fixed32(let v): return Double(Float(bitPattern: v))
        case .varint(let v): return Double(Int64(bitPattern: v))
        case .bytes: return nil
        }
    }

    public var float: Float? {
        if case .fixed32(let v) = value { return Float(bitPattern: v) }
        return nil
    }

    /// Seconds since 2001 (double or integer) → Date, if plausible.
    public var cocoaDate: Date? {
        guard let d = double, d.isFinite, d != 0 else { return nil }
        let date = DossierDate.cocoa(d)
        return DossierDate.isPlausible(date) ? date : nil
    }

    /// Seconds since 1970 → Date, if plausible.
    public var unixDate: Date? {
        guard let d = double, d.isFinite, d != 0 else { return nil }
        let date = DossierDate.unix(d)
        return DossierDate.isPlausible(date) ? date : nil
    }

    // MARK: Length-delimited

    /// Raw bytes of a length-delimited field.
    public var data: Data? {
        if case .bytes(let d) = value { return d }
        return nil
    }

    /// UTF-8 string (strict: nil if the bytes are not valid UTF-8).
    public var string: String? {
        guard case .bytes(let d) = value else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Nested message (strict parse of the bytes).
    public var message: ProtoMessage? {
        guard case .bytes(let d) = value else { return nil }
        return ProtoMessage(d)
    }

    /// Packed repeated varints.
    public var packedVarints: [UInt64]? {
        guard case .bytes(let d) = value else { return nil }
        var out: [UInt64] = []
        var result: UInt64 = 0, shift: UInt64 = 0
        var complete = true
        for b in d {
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { out.append(result); result = 0; shift = 0; complete = true }
            else { shift += 7; complete = false; if shift > 63 { return nil } }
        }
        return complete ? out : nil
    }

    /// Best guess at what a length-delimited field contains: printable UTF-8 text wins,
    /// then a well-formed nested message, otherwise raw data.
    public var guess: ProtoGuess {
        guard case .bytes(let d) = value else { return .number }
        if d.isEmpty { return .string("") }
        if let s = String(data: d, encoding: .utf8), ProtoField.looksLikeText(s) { return .string(s) }
        if let m = ProtoMessage(d), !m.fields.isEmpty, ProtoField.looksLikeMessage(m) { return .message(m) }
        if let s = String(data: d, encoding: .utf8), !s.unicodeScalars.contains(where: { $0.value == 0 }) , d.count > 3 {
            // Valid UTF-8 containing a few control characters.
            let controls = s.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r" }.count
            if controls * 10 < s.unicodeScalars.count { return .string(s) }
        }
        return .data(d)
    }

    static func looksLikeText(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            if u.value < 0x20 && u != "\n" && u != "\t" && u != "\r" { return false }
            if u.value == 0x7F || u.value == 0xFFFD { return false }
        }
        return true
    }

    static func looksLikeMessage(_ m: ProtoMessage) -> Bool {
        // Reject absurd field numbers that typically come from random bytes.
        m.fields.allSatisfy { $0.number < 20_000 }
    }
}
