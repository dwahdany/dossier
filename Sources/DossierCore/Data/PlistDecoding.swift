import Foundation

/// A plain Swift tree for property-list-like data (binary/XML plists, NSKeyedArchiver
/// object graphs, JSON). Dictionaries keep their original key order.
public indirect enum PlistValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case uid(Int)
    case array([PlistValue])
    case dict([(key: String, value: PlistValue)])

    // MARK: Accessors

    public subscript(key: String) -> PlistValue? {
        guard case .dict(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    public subscript(index: Int) -> PlistValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .real(let d): return Format.number(d, maxDigits: 6)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .real(let d): return d.isFinite ? Int64(d) : nil
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .real(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return nil
        }
    }

    public var date: Date? {
        if case .date(let d) = self { return d }
        return nil
    }

    public var data: Data? {
        if case .data(let d) = self { return d }
        return nil
    }

    public var array: [PlistValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var dict: [(key: String, value: PlistValue)]? {
        if case .dict(let d) = self { return d }
        return nil
    }

    /// Walks a key path of dictionary keys.
    public func value(at keys: String...) -> PlistValue? {
        var current: PlistValue? = self
        for key in keys { current = current?[key] }
        return current
    }

    /// All string leaves (depth-first), for previews and search.
    public func allStrings(limit: Int = 128) -> [String] {
        var out: [String] = []
        func walk(_ v: PlistValue) {
            if out.count >= limit { return }
            switch v {
            case .string(let s): if !s.isEmpty { out.append(s) }
            case .array(let items): items.forEach(walk)
            case .dict(let pairs): pairs.forEach { walk($0.value) }
            default: break
            }
        }
        walk(self)
        return out
    }
}

/// Decoders for property lists and NSKeyedArchiver blobs that do not need the archived
/// classes to exist in this process.
public enum PlistDecoder {
    /// True if `data` starts with the binary-plist magic.
    public static func isBinaryPlist(_ data: Data) -> Bool { data.starts(with: Array("bplist".utf8)) }

    /// True if `data` looks like an XML plist.
    public static func isXMLPlist(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(256), encoding: .utf8) else { return false }
        return head.contains("<plist") || (head.contains("<?xml") && head.contains("DOCTYPE plist"))
    }

    /// Decodes a binary or XML plist into a ``PlistValue`` tree. NSKeyedArchiver UIDs are
    /// preserved as `.uid`; use ``decodeAny(_:)`` to also resolve archives.
    public static func decodePlist(_ data: Data) -> PlistValue? {
        if isBinaryPlist(data) {
            if let v = BinaryPlistParser(data).parse() { return v }
        }
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return convert(object)
    }

    /// True if the decoded plist is an NSKeyedArchiver container.
    public static func isKeyedArchive(_ plist: PlistValue) -> Bool {
        plist["$archiver"]?.string == "NSKeyedArchiver" && plist["$objects"]?.array != nil
    }

    /// Decodes a plist and, if it is an NSKeyedArchiver archive, resolves the object graph
    /// into plain values (see ``unarchive(_:)``).
    public static func decodeAny(_ data: Data) -> PlistValue? {
        guard let plist = decodePlist(data) else { return nil }
        if isKeyedArchive(plist) { return unarchive(plist) ?? plist }
        return plist
    }

    /// Resolves an NSKeyedArchiver container into a plain tree:
    /// * `NSArray`/`NSSet`/`NSOrderedSet` → `.array`
    /// * `NSDictionary` → `.dict`
    /// * `NSString`/`NSMutableString` → `.string`, `NSData` → `.data`, `NSDate` → `.date`
    /// * `NSURL` → `.string`, `NSUUID` → `.string`
    /// * any other object → `.dict` with a `"$class"` entry followed by its coded keys;
    ///   nested archives inside `NSData` values are left as data (decode them on demand).
    public static func unarchive(_ archive: PlistValue) -> PlistValue? {
        guard let objects = archive["$objects"]?.array, let top = archive["$top"] else { return nil }
        var resolver = ArchiveResolver(objects: objects)
        if case .dict(let pairs) = top {
            if pairs.count == 1, let only = pairs.first { return resolver.resolve(only.value, depth: 0) }
            return .dict(pairs.map { ($0.key, resolver.resolve($0.value, depth: 0)) })
        }
        return resolver.resolve(top, depth: 0)
    }

    /// Decodes JSON into a ``PlistValue`` tree (object key order is sorted).
    public static func decodeJSON(_ data: Data) -> PlistValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return convert(object)
    }

    /// Converts Foundation property-list / JSON objects into a ``PlistValue``.
    public static func convert(_ object: Any) -> PlistValue {
        switch object {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .real(n.doubleValue) }
            return .int(n.int64Value)
        case let d as Data: return .data(d)
        case let d as Date: return .date(d)
        case let a as [Any]: return .array(a.map(convert))
        case let d as [String: Any]:
            return .dict(d.keys.sorted().map { ($0, convert(d[$0]!)) })
        case let d as NSDictionary:
            var pairs: [(key: String, value: PlistValue)] = []
            for (k, v) in d { pairs.append(("\(k)", convert(v))) }
            return .dict(pairs.sorted { $0.key < $1.key })
        case is NSNull: return .null
        default:
            // CFKeyedArchiverUID from PropertyListSerialization: "<CFKeyedArchiverUID ...>{value = N}"
            let description = "\(object)"
            if let range = description.range(of: "value = "),
               let n = Int(description[range.upperBound...].prefix { $0.isNumber }) {
                return .uid(n)
            }
            return .string(description)
        }
    }
}

// MARK: - NSKeyedArchiver resolution

private struct ArchiveResolver {
    let objects: [PlistValue]
    var inProgress: Set<Int> = []
    var budget = 400_000   // node budget against pathological graphs

    init(objects: [PlistValue]) { self.objects = objects }

    mutating func resolve(_ value: PlistValue, depth: Int) -> PlistValue {
        budget -= 1
        if budget <= 0 || depth > 96 { return .string("…") }
        switch value {
        case .uid(let index):
            guard objects.indices.contains(index) else { return .null }
            if index == 0 { return .null }                     // "$null"
            if inProgress.contains(index) { return .string("↺ #\(index)") }
            inProgress.insert(index)
            defer { inProgress.remove(index) }
            return resolveObject(objects[index], depth: depth + 1)
        case .array(let items):
            return .array(items.map { resolve($0, depth: depth + 1) })
        case .dict(let pairs):
            return .dict(pairs.map { ($0.key, resolve($0.value, depth: depth + 1)) })
        default:
            return value
        }
    }

    private func className(of object: PlistValue) -> String? {
        guard case .uid(let classIndex)? = object["$class"], objects.indices.contains(classIndex) else { return nil }
        return objects[classIndex]["$classname"]?.string
    }

    private mutating func resolveObject(_ object: PlistValue, depth: Int) -> PlistValue {
        guard case .dict(let pairs) = object, let cls = className(of: object) else {
            if case .string(let s) = object, s == "$null" { return .null }
            return resolve(object, depth: depth)
        }
        func member(_ key: String) -> PlistValue? { pairs.first { $0.key == key }?.value }

        switch cls {
        case "NSArray", "NSMutableArray", "NSSet", "NSMutableSet", "NSOrderedSet", "NSMutableOrderedSet", "NSCountedSet":
            let items = member("NS.objects")?.array ?? []
            return .array(items.map { resolve($0, depth: depth) })
        case "NSDictionary", "NSMutableDictionary":
            let keys = member("NS.keys")?.array ?? []
            let values = member("NS.objects")?.array ?? []
            var out: [(key: String, value: PlistValue)] = []
            for (i, k) in keys.enumerated() where i < values.count {
                let key = resolve(k, depth: depth)
                out.append((key.string ?? PlistDecoder.describe(key), resolve(values[i], depth: depth)))
            }
            return .dict(out)
        case "NSString", "NSMutableString":
            if let s = member("NS.string") { return resolve(s, depth: depth) }
            if let d = member("NS.bytes")?.data, let s = String(data: d, encoding: .utf8) { return .string(s) }
        case "NSData", "NSMutableData":
            if let d = member("NS.data") { return resolve(d, depth: depth) }
            if let d = member("NS.bytes") { return d }
        case "NSDate":
            if let t = member("NS.time")?.double { return .date(Date(timeIntervalSinceReferenceDate: t)) }
        case "NSURL":
            let base = member("NS.base").map { resolve($0, depth: depth) }?.string
            let relative = member("NS.relative").map { resolve($0, depth: depth) }?.string ?? ""
            return .string((base ?? "") + relative)
        case "NSUUID":
            if let d = member("NS.uuidbytes")?.data, d.count == 16 {
                let uuid = d.withUnsafeBytes { NSUUID(uuidBytes: $0.bindMemory(to: UInt8.self).baseAddress) }
                return .string(uuid.uuidString)
            }
        case "NSNull":
            return .null
        default:
            break
        }
        var out: [(key: String, value: PlistValue)] = [("$class", .string(cls))]
        for pair in pairs where pair.key != "$class" {
            out.append((pair.key, resolve(pair.value, depth: depth)))
        }
        return .dict(out)
    }
}

extension PlistDecoder {
    /// Short single-line description of a value (used for dictionary keys and summaries).
    public static func describe(_ value: PlistValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .real(let d): return Format.number(d, maxDigits: 6)
        case .string(let s): return s
        case .data(let d): return "\(d.count) bytes"
        case .date(let d): return DossierDate.sortable(d)
        case .uid(let i): return "UID(\(i))"
        case .array(let a): return "[\(a.count) items]"
        case .dict(let d): return "{\(d.count) keys}"
        }
    }
}

// MARK: - Binary plist parser

/// Minimal `bplist00` parser (handles UIDs natively, keeps dictionary key order).
struct BinaryPlistParser {
    private let data: Data
    private var offsetSize = 0
    private var refSize = 0
    private var objectCount = 0
    private var topObject = 0
    private var tableOffset = 0

    init(_ data: Data) { self.data = data }

    func parse() -> PlistValue? {
        var copy = self
        return copy.run()
    }

    private mutating func run() -> PlistValue? {
        guard data.count >= 40, data.starts(with: Array("bplist".utf8)) else { return nil }
        let trailer = data.count - 32
        offsetSize = Int(byte(trailer + 6))
        refSize = Int(byte(trailer + 7))
        guard let count = uint(at: trailer + 8, size: 8), let top = uint(at: trailer + 16, size: 8),
              let table = uint(at: trailer + 24, size: 8) else { return nil }
        objectCount = count; topObject = top; tableOffset = table
        guard (1...8).contains(offsetSize), (1...8).contains(refSize), objectCount > 0, objectCount < 50_000_000,
              tableOffset >= 8, tableOffset + objectCount * offsetSize <= trailer, topObject < objectCount else { return nil }
        var budget = 2_000_000
        return object(topObject, depth: 0, budget: &budget)
    }

    @inline(__always) private func byte(_ offset: Int) -> UInt8 { data[data.startIndex + offset] }

    private func uint(at offset: Int, size: Int) -> Int? {
        guard offset >= 0, size > 0, size <= 8, offset + size <= data.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<size { v = (v << 8) | UInt64(byte(offset + i)) }
        return v > UInt64(Int.max) ? nil : Int(v)
    }

    private func sizedInt(at offset: Int, size: Int) -> Int64? {
        guard offset >= 0, offset + size <= data.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<min(size, 8) { v = (v << 8) | UInt64(byte(offset + (size > 8 ? size - 8 : 0) + i)) }
        switch size {
        case 1, 2, 4: return Int64(v)          // unsigned per spec
        default: return Int64(bitPattern: v)
        }
    }

    /// Reads a length that may be extended by a following int object. Returns (count, dataOffset).
    private func length(_ info: Int, at offset: Int) -> (Int, Int)? {
        if info != 0x0F { return (info, offset + 1) }
        guard offset + 1 < data.count else { return nil }
        let marker = byte(offset + 1)
        guard marker >> 4 == 0x1 else { return nil }
        let size = 1 << Int(marker & 0x0F)
        guard let n = uint(at: offset + 2, size: size) else { return nil }
        return (n, offset + 2 + size)
    }

    private func object(_ index: Int, depth: Int, budget: inout Int) -> PlistValue? {
        budget -= 1
        guard budget > 0, depth < 512, index < objectCount,
              let offset = uint(at: tableOffset + index * offsetSize, size: offsetSize), offset < data.count else { return nil }
        let marker = byte(offset)
        let type = marker >> 4
        let info = Int(marker & 0x0F)
        switch type {
        case 0x0:
            switch info {
            case 0x0: return .null
            case 0x8: return .bool(false)
            case 0x9: return .bool(true)
            default: return .null
            }
        case 0x1:
            let size = 1 << info
            guard let v = sizedInt(at: offset + 1, size: size) else { return nil }
            return .int(v)
        case 0x2:
            if info == 2, let bits = uint(at: offset + 1, size: 4) {
                return .real(Double(Float(bitPattern: UInt32(bits))))
            }
            guard info == 3, offset + 9 <= data.count else { return nil }
            var bits: UInt64 = 0
            for i in 0..<8 { bits = (bits << 8) | UInt64(byte(offset + 1 + i)) }
            return .real(Double(bitPattern: bits))
        case 0x3:
            guard offset + 9 <= data.count else { return nil }
            var bits: UInt64 = 0
            for i in 0..<8 { bits = (bits << 8) | UInt64(byte(offset + 1 + i)) }
            return .date(Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits)))
        case 0x4:
            guard let (n, start) = length(info, at: offset), start + n <= data.count else { return nil }
            return .data(data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + n)))
        case 0x5:
            guard let (n, start) = length(info, at: offset), start + n <= data.count else { return nil }
            let slice = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + n))
            return .string(String(data: slice, encoding: .ascii) ?? String(decoding: slice, as: UTF8.self))
        case 0x6:
            guard let (n, start) = length(info, at: offset), start + n * 2 <= data.count else { return nil }
            let slice = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + n * 2))
            return .string(String(data: slice, encoding: .utf16BigEndian) ?? "")
        case 0x7:
            guard let (n, start) = length(info, at: offset), start + n <= data.count else { return nil }
            let slice = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + n))
            return .string(String(decoding: slice, as: UTF8.self))
        case 0x8:
            guard let v = uint(at: offset + 1, size: info + 1) else { return nil }
            return .uid(v)
        case 0xA, 0xC:
            guard let (n, start) = length(info, at: offset), start + n * refSize <= data.count else { return nil }
            var items: [PlistValue] = []
            items.reserveCapacity(n)
            for i in 0..<n {
                guard let ref = uint(at: start + i * refSize, size: refSize),
                      let v = object(ref, depth: depth + 1, budget: &budget) else { return nil }
                items.append(v)
            }
            return .array(items)
        case 0xD:
            guard let (n, start) = length(info, at: offset), start + n * refSize * 2 <= data.count else { return nil }
            var pairs: [(key: String, value: PlistValue)] = []
            pairs.reserveCapacity(n)
            for i in 0..<n {
                guard let kref = uint(at: start + i * refSize, size: refSize),
                      let vref = uint(at: start + (n + i) * refSize, size: refSize),
                      let k = object(kref, depth: depth + 1, budget: &budget),
                      let v = object(vref, depth: depth + 1, budget: &budget) else { return nil }
                pairs.append((k.string ?? PlistDecoder.describe(k), v))
            }
            return .dict(pairs)
        default:
            return nil
        }
    }
}
