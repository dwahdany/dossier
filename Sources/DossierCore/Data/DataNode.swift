import Foundation

/// A display-ready tree node (key / type / value / children) shown by ``DataTreeView``.
/// Build one from a plist, NSKeyedArchiver graph, JSON document or protobuf message.
public struct DataNode: Identifiable, Sendable {
    /// Path-based identifier, stable across rebuilds of the same data.
    public let id: String
    public var key: String
    /// Short type label: "dict", "string", "varint", "message", ...
    public var kind: String
    /// Single-line value summary.
    public var value: String
    /// Secondary interpretation (e.g. a date guessed from a number).
    public var hint: String?
    public var children: [DataNode]?
    /// Raw bytes for data leaves (opens in the hex viewer / nested blob inspector).
    public var raw: Data?

    public init(id: String, key: String, kind: String, value: String, hint: String? = nil, children: [DataNode]? = nil, raw: Data? = nil) {
        self.id = id; self.key = key; self.kind = kind; self.value = value
        self.hint = hint; self.children = children; self.raw = raw
    }

    /// Total number of nodes (for "n nodes" footers).
    public var nodeCount: Int { 1 + (children?.reduce(0) { $0 + $1.nodeCount } ?? 0) }

    /// Plain-text rendering of the subtree (for copy).
    public func textDump(indent: Int = 0) -> String {
        var line = String(repeating: "  ", count: indent) + key
        if !value.isEmpty { line += ": " + value }
        if let hint { line += "  (" + hint + ")" }
        guard let children else { return line }
        return ([line] + children.map { $0.textDump(indent: indent + 1) }).joined(separator: "\n")
    }
}

public extension DataNode {
    /// Maximum children materialized per container (the rest is summarized in one node).
    static let childLimit = 2_000

    // MARK: Plist / JSON / NSKeyedArchiver

    /// Tree for a ``PlistValue``.
    static func from(_ value: PlistValue, key: String = "root", path: String = "$") -> DataNode {
        switch value {
        case .null:
            return DataNode(id: path, key: key, kind: "null", value: "null")
        case .bool(let b):
            return DataNode(id: path, key: key, kind: "bool", value: b ? "true" : "false")
        case .int(let i):
            return DataNode(id: path, key: key, kind: "int", value: String(i), hint: dateHint(Double(i), key: key))
        case .real(let d):
            return DataNode(id: path, key: key, kind: "real", value: Format.number(d, maxDigits: 6), hint: dateHint(d, key: key))
        case .string(let s):
            return DataNode(id: path, key: key, kind: "string", value: s)
        case .date(let d):
            return DataNode(id: path, key: key, kind: "date", value: DossierDate.sortable(d))
        case .uid(let i):
            return DataNode(id: path, key: key, kind: "uid", value: "UID(\(i))")
        case .data(let d):
            return dataLeaf(d, key: key, path: path)
        case .array(let items):
            var children: [DataNode] = []
            for (i, item) in items.prefix(childLimit).enumerated() {
                children.append(from(item, key: "[\(i)]", path: path + "/\(i)"))
            }
            if items.count > childLimit {
                children.append(DataNode(id: path + "/more", key: "…", kind: "", value: "\(items.count - childLimit) more items not shown"))
            }
            return DataNode(id: path, key: key, kind: "array", value: "\(items.count) item\(items.count == 1 ? "" : "s")", children: children)
        case .dict(let pairs):
            var children: [DataNode] = []
            for (i, pair) in pairs.prefix(childLimit).enumerated() {
                children.append(from(pair.value, key: pair.key, path: path + "/\(i)"))
            }
            if pairs.count > childLimit {
                children.append(DataNode(id: path + "/more", key: "…", kind: "", value: "\(pairs.count - childLimit) more keys not shown"))
            }
            let cls = pairs.first { $0.key == "$class" }?.value.string
            return DataNode(id: path, key: key, kind: cls ?? "dict", value: "\(pairs.count) key\(pairs.count == 1 ? "" : "s")", children: children)
        }
    }

    /// A data leaf; nested plists/archives/protobufs are expanded one level in place when
    /// small enough so the tree shows the real content rather than "n bytes".
    private static func dataLeaf(_ d: Data, key: String, path: String, depth: Int = 0) -> DataNode {
        let kind = BlobSniffer.sniff(d)
        var node = DataNode(id: path, key: key, kind: "data", value: "\(Format.bytes(d.count)) · \(kind.label)", raw: d)
        guard d.count <= 512 * 1024, depth < 4 else { return node }
        switch kind {
        case .binaryPlist, .keyedArchive, .xmlPlist:
            if let nested = PlistDecoder.decodeAny(d) {
                node.children = [from(nested, key: kind.label, path: path + "/decoded")]
            }
        case .protobuf:
            if let m = ProtoMessage(d) { node.children = from(m, path: path + "/pb") }
        case .json:
            if let nested = PlistDecoder.decodeJSON(d) {
                node.children = [from(nested, key: "JSON", path: path + "/json")]
            }
        default:
            break
        }
        return node
    }

    private static func dateHint(_ v: Double, key: String) -> String? {
        // Only hint when the key suggests a timestamp or the value is a non-integer double
        // in the Cocoa range; avoids decorating every integer with a bogus date.
        let k = key.lowercased()
        let named = k.contains("date") || k.contains("time") || k.contains("stamp") || k.hasSuffix("at")
        if named, let g = DossierDate.guess(v) { return DossierDate.sortable(g.date) + " · " + g.encoding }
        if v != v.rounded(), v > 2.0e8, v < 1.5e9 { return DossierDate.sortable(DossierDate.cocoa(v)) + " · Cocoa s" }
        return nil
    }

    // MARK: Protobuf

    /// Nodes for the fields of a protobuf message (keys are field numbers).
    static func from(_ message: ProtoMessage, path: String = "pb", depth: Int = 0) -> [DataNode] {
        var out: [DataNode] = []
        out.reserveCapacity(min(message.fields.count, childLimit))
        for (i, field) in message.fields.prefix(childLimit).enumerated() {
            let id = path + "/\(i)"
            let key = "#\(field.number)"
            switch field.value {
            case .varint(let v):
                let signed = Int64(bitPattern: v)
                out.append(DataNode(id: id, key: key, kind: "varint", value: String(signed), hint: v > 1_000_000 ? DossierDate.guess(Double(v)).map { DossierDate.sortable($0.date) + " · " + $0.encoding } : nil))
            case .fixed64(let v):
                let d = Double(bitPattern: v)
                if d.isFinite, abs(d) > 1e-6, abs(d) < 1e15 || d == 0 {
                    let date = field.cocoaDate
                    let hint: String? = (d > 1.0e8 && d < 1.5e9) ? date.map { DossierDate.sortable($0) + " · Cocoa s" } : nil
                    out.append(DataNode(id: id, key: key, kind: "double", value: Format.number(d, maxDigits: 6), hint: hint))
                } else {
                    out.append(DataNode(id: id, key: key, kind: "fixed64", value: String(Int64(bitPattern: v)), hint: d.isFinite && d != 0 ? "as double \(d)" : nil))
                }
            case .fixed32(let v):
                let f = Float(bitPattern: v)
                if f.isFinite, abs(f) > 1e-6, abs(f) < 1e9 {
                    out.append(DataNode(id: id, key: key, kind: "float", value: Format.number(Double(f), maxDigits: 5), hint: "int \(v)"))
                } else {
                    out.append(DataNode(id: id, key: key, kind: "fixed32", value: String(v)))
                }
            case .bytes(let d):
                switch field.guess {
                case .string(let s):
                    out.append(DataNode(id: id, key: key, kind: "string", value: s))
                case .message(let sub):
                    let children = depth < 24 ? from(sub, path: id, depth: depth + 1) : []
                    out.append(DataNode(id: id, key: key, kind: "message", value: "\(sub.fields.count) field\(sub.fields.count == 1 ? "" : "s")", children: children, raw: d))
                case .data, .number:
                    out.append(dataLeaf(d, key: key, path: id, depth: depth + 1))
                }
            }
        }
        if message.fields.count > childLimit {
            out.append(DataNode(id: path + "/more", key: "…", kind: "", value: "\(message.fields.count - childLimit) more fields not shown"))
        }
        return out
    }
}

// MARK: - Blob sniffing

/// Detects what an opaque blob contains.
public enum BlobSniffer {
    public enum Kind: Sendable, Hashable {
        case empty
        case binaryPlist
        case keyedArchive
        case xmlPlist
        case json
        case protobuf
        case text
        case image(String)
        case sqlite
        case segb
        case gzip
        case binary

        public var label: String {
            switch self {
            case .empty: return "empty"
            case .binaryPlist: return "binary plist"
            case .keyedArchive: return "NSKeyedArchiver"
            case .xmlPlist: return "XML plist"
            case .json: return "JSON"
            case .protobuf: return "protobuf"
            case .text: return "text"
            case .image(let t): return t + " image"
            case .sqlite: return "SQLite database"
            case .segb: return "SEGB"
            case .gzip: return "gzip"
            case .binary: return "binary"
            }
        }
    }

    /// Classifies `data` by magic numbers and structural checks. Cheap for the magic-based
    /// kinds; protobuf detection parses the top level (bounded by `data.count`).
    public static func sniff(_ data: Data) -> Kind {
        if data.isEmpty { return .empty }
        let head = [UInt8](data.prefix(16))
        func starts(_ bytes: [UInt8]) -> Bool { head.count >= bytes.count && Array(head.prefix(bytes.count)) == bytes }

        if starts(Array("bplist".utf8)) {
            // NSKeyedArchiver archives contain the "$archiver" key near the top or bottom.
            let needle = Data("$archiver".utf8)
            if data.prefix(4096).range(of: needle) != nil || data.suffix(4096).range(of: needle) != nil { return .keyedArchive }
            return .binaryPlist
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .image("PNG") }
        if starts([0xFF, 0xD8, 0xFF]) { return .image("JPEG") }
        if starts(Array("GIF8".utf8)) { return .image("GIF") }
        if head.count >= 12, Array(head[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            if brand.hasPrefix("hei") || brand.hasPrefix("mif") || brand.hasPrefix("avif") { return .image("HEIF") }
        }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .image("TIFF") }
        if starts(Array("SQLite format 3".utf8)) { return .sqlite }
        if starts(Array("SEGB".utf8)) { return .segb }
        if starts([0x1F, 0x8B]) { return .gzip }

        // Text-like formats.
        let sample = data.prefix(64 * 1024)
        if let text = String(data: sample, encoding: .utf8) ?? String(data: sample.dropLast(3), encoding: .utf8) {
            let trimmed = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<plist") || trimmed.hasPrefix("<!DOCTYPE plist") {
                return PlistDecoder.isXMLPlist(data) ? .xmlPlist : .text
            }
            if ProtoField.looksLikeText(text) {
                if let first = trimmed.first, first == "{" || first == "[",
                   data.count <= 32 * 1024 * 1024,
                   (try? JSONSerialization.jsonObject(with: data, options: [])) != nil {
                    return .json
                }
                return .text
            }
        }
        if data.count <= 32 * 1024 * 1024, let m = ProtoMessage(data), !m.fields.isEmpty, ProtoField.looksLikeMessage(m) {
            return .protobuf
        }
        return .binary
    }
}
