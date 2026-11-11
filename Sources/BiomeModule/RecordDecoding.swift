import Foundation
import DossierCore

// MARK: - Typed decoding driven by the registry

enum RecordDecoder {
    /// Display strings of all values at the field's path.
    static func values(_ field: BiomeField, in payload: Data, limit: Int = 12) -> [String] {
        var out: [String] = []
        payload.withUnsafeBytes { raw in
            FastProto.collect(raw, path: field.path[...]) { value in
                guard out.count <= limit else { return }
                if let text = format(value, kind: field.kind), !text.isEmpty, !out.contains(text) { out.append(text) }
            }
        }
        return out
    }

    /// True for strings shaped like a bundle identifier (reverse-DNS, no spaces or path
    /// separators). Fields documented as `.app` occasionally hold a process name or path.
    static func looksLikeBundleID(_ text: String) -> Bool {
        guard text.count <= 160, text.contains("."), !text.hasPrefix("."), !text.hasSuffix(".") else { return false }
        return !text.unicodeScalars.contains { $0 == " " || $0 == "/" || $0 == ":" || $0.value < 0x21 }
    }

    /// App name for a bundle identifier through the shared `AppDirectory`; anything that
    /// is not shaped like an identifier is returned unchanged.
    static func appName(_ identifier: String) -> String {
        looksLikeBundleID(identifier) ? AppDirectory.name(identifier) : identifier
    }

    /// One cell: the values joined. Bundle identifiers (`.app` fields) are resolved to
    /// app names unless `raw` is set.
    static func display(_ field: BiomeField, in payload: Data, limit: Int = 8, raw: Bool = false) -> String {
        var all = values(field, in: payload, limit: limit)
        if !raw, case .app = field.kind { all = all.map(appName) }
        if all.count > limit { return all.prefix(limit).joined(separator: ", ") + ", …" }
        return all.joined(separator: ", ")
    }

    /// One-line description of a record: the schema's headline fields, or the string
    /// leaves of the message when the stream has no schema.
    static func summary(_ schema: BiomeStreamSchema?, payload: Data, max: Int = 220) -> String {
        if let schema {
            let parts = schema.headlines.compactMap { field -> String? in
                let text = display(field, in: payload, limit: 4)
                if text.isEmpty { return nil }
                switch field.kind {
                case .bool: return text == "Yes" ? field.name.lowercased() : "not " + field.name.lowercased()
                case .integer, .number, .percent: return "\(field.name.lowercased()) \(text)"
                default: return text
                }
            }
            if !parts.isEmpty { return Format.oneLine(parts.joined(separator: "  ·  "), max: max) }
        }
        return genericPreview(payload, max: max)
    }

    /// String leaves of the protobuf message, or the blob kind.
    static func genericPreview(_ payload: Data, max: Int = 220) -> String {
        if payload.isEmpty { return "" }
        if PlistDecoder.isBinaryPlist(payload), let plist = PlistDecoder.decodeAny(payload) { return plistPreview(plist, max: max) }
        if let message = ProtoMessage(payload), !message.fields.isEmpty {
            let strings = message.allStrings(limit: 10).filter { $0.count > 1 }
            if !strings.isEmpty { return Format.oneLine(strings.joined(separator: "  ·  "), max: max) }
            return "\(message.fields.count) field\(message.fields.count == 1 ? "" : "s"), no text"
        }
        if let plist = PlistDecoder.decodeAny(payload) { return plistPreview(plist, max: max) }
        return BlobSniffer.sniff(payload).label
    }

    /// Preview of an archived object. App Intents transcript records
    /// (`LNTranscriptActionRecord`: `bundleIdentifier`, `resolvedAction.identifier`,
    /// `resolvedAction.parameters`) get a dedicated one-liner.
    static func plistPreview(_ plist: PlistValue, max: Int = 220) -> String {
        let action = plist.value(at: "resolvedAction", "identifier")?.string ?? plist.value(at: "originalAction", "identifier")?.string
        if let action {
            var parts = [action]
            if let bundle = plist["bundleIdentifier"]?.string { parts.append(bundle) }
            if let label = plist["clientLabel"]?.string, !label.isEmpty { parts.append(label) }
            return Format.oneLine(parts.joined(separator: "  ·  "), max: max)
        }
        let strings = plist.allStrings(limit: 40).filter { $0.count > 1 && !$0.hasPrefix("$") && !$0.hasPrefix("NS") }
        if strings.isEmpty { return "property list" }
        return Format.oneLine(strings.prefix(8).joined(separator: "  ·  "), max: max)
    }

    static func format(_ value: PBValue, kind: BiomeFieldKind) -> String? {
        switch kind {
        case .string, .app:
            if case .bytes(let b) = value { return String(bytes: b, encoding: .utf8) }
            return number(value).map { Format.number($0, maxDigits: 6) }
        case .integer:
            if case .varint(let v) = value { return String(Int64(bitPattern: v)) }
            return number(value).map { Format.number($0, maxDigits: 6) }
        case .bool:
            if case .varint(let v) = value { return v != 0 ? "Yes" : "No" }
            return nil
        case .number:
            return number(value).map { Format.number($0, maxDigits: 4) }
        case .percent:
            return number(value).map { "\(Int($0)) %" }
        case .cocoaDate:
            guard let d = number(value), d.isFinite, d != 0 else { return nil }
            let date = DossierDate.cocoa(d)
            return DossierDate.isPlausible(date) ? DossierDate.sortable(date) : Format.number(d, maxDigits: 3)
        case .unixDate:
            guard let d = number(value), d.isFinite, d != 0 else { return nil }
            let date = DossierDate.unix(d)
            return DossierDate.isPlausible(date) ? DossierDate.sortable(date) : Format.number(d, maxDigits: 3)
        case .seconds:
            guard let d = number(value), d.isFinite, d > 0 else { return nil }
            return Format.duration(d)
        case .enumeration(let labels):
            guard case .varint(let v) = value else { return nil }
            let key = Int64(bitPattern: v)
            return labels[key] ?? String(key)
        case .uuidBytes:
            guard case .bytes(let b) = value else { return nil }
            if b.count == 16 {
                let bytes = Array(b)
                return NSUUID(uuidBytes: bytes).uuidString
            }
            return String(bytes: b, encoding: .utf8) ?? "\(b.count) bytes"
        case .json(let key):
            guard case .bytes(let b) = value else { return nil }
            guard let key else { return String(bytes: b, encoding: .utf8) }
            let data = Data(b)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let s = object[key] as? String { return s }
            if let n = object[key] as? NSNumber { return n.stringValue }
            return nil
        case .plist:
            guard case .bytes(let b) = value, !b.isEmpty else { return nil }
            guard let plist = PlistDecoder.decodeAny(Data(b)) else { return "\(b.count) bytes" }
            let strings = plist.allStrings(limit: 40).filter { $0.count > 1 && !$0.hasPrefix("$") && !$0.hasPrefix("NS") }
            return strings.isEmpty ? "property list, \(b.count) bytes" : strings.prefix(8).joined(separator: " · ")
        case .bytes:
            guard case .bytes(let b) = value else { return nil }
            return b.isEmpty ? nil : Format.bytes(b.count)
        }
    }

    private static func number(_ value: PBValue) -> Double? {
        switch value {
        case .varint(let v): return Double(Int64(bitPattern: v))
        case .fixed64(let v): return Double(bitPattern: v)
        case .fixed32(let v): return Double(Float(bitPattern: v))
        case .bytes: return nil
        }
    }

    // MARK: Annotated tree

    /// Display tree of a payload where documented fields carry their registry names
    /// (`Bundle ID  #6`) and embedded property lists are expanded.
    static func tree(_ payload: Data, schema: BiomeStreamSchema?) -> [DataNode] {
        if PlistDecoder.isBinaryPlist(payload), let plist = PlistDecoder.decodeAny(payload) {
            let root = DataNode.from(plist, key: "archive")
            return root.children ?? [root]
        }
        guard let message = ProtoMessage(payload), !message.fields.isEmpty else {
            if let plist = PlistDecoder.decodeAny(payload) { return [DataNode.from(plist, key: "payload")] }
            return [DataNode(id: "raw", key: "payload", kind: BlobSniffer.sniff(payload).label, value: Format.bytes(payload.count), raw: payload)]
        }
        return nodes(message, schema: schema, numbers: [], path: "pb", depth: 0)
    }

    private static func nodes(_ message: ProtoMessage, schema: BiomeStreamSchema?, numbers: [Int], path: String, depth: Int) -> [DataNode] {
        var out: [DataNode] = []
        let limit = 1_500
        for (i, field) in message.fields.prefix(limit).enumerated() {
            let id = path + "/\(i)"
            let fieldPath = numbers + [field.number]
            let spec = schema?.fields.first { $0.path == fieldPath }
            let key = spec.map { "\($0.name)  #\(field.number)" } ?? "#\(field.number)"
            switch field.value {
            case .varint(let v):
                let text = spec.flatMap { format(.varint(v), kind: $0.kind) }
                let raw = String(Int64(bitPattern: v))
                out.append(DataNode(id: id, key: key, kind: "varint", value: raw, hint: text != raw ? text : nil))
            case .fixed64(let v):
                let d = Double(bitPattern: v)
                var hint = spec.flatMap { format(.fixed64(v), kind: $0.kind) }
                if spec == nil, d.isFinite {
                    if d > 1.0e8, d < 1.3e9 { hint = DossierDate.sortable(DossierDate.cocoa(d)) + " · Cocoa" }
                    else if d >= 1.3e9, d < 2.6e9 { hint = DossierDate.sortable(DossierDate.unix(d)) + " · Unix" }
                }
                if d.isFinite, d == 0 || (abs(d) > 1e-9 && abs(d) < 1e15) {
                    out.append(DataNode(id: id, key: key, kind: "double", value: Format.number(d, maxDigits: 6), hint: hint))
                } else {
                    out.append(DataNode(id: id, key: key, kind: "fixed64", value: String(Int64(bitPattern: v)), hint: hint))
                }
            case .fixed32(let v):
                let f = Float(bitPattern: v)
                if f.isFinite, f == 0 || (abs(f) > 1e-6 && abs(f) < 1e9) {
                    out.append(DataNode(id: id, key: key, kind: "float", value: Format.number(Double(f), maxDigits: 5)))
                } else {
                    out.append(DataNode(id: id, key: key, kind: "fixed32", value: String(v)))
                }
            case .bytes(let d):
                out.append(bytesNode(field, data: d, spec: spec, schema: schema, numbers: fieldPath, id: id, key: key, depth: depth))
            }
        }
        if message.fields.count > limit {
            out.append(DataNode(id: path + "/more", key: "…", kind: "", value: "\(message.fields.count - limit) more fields not shown"))
        }
        return out
    }

    private static func bytesNode(_ field: ProtoField, data d: Data, spec: BiomeField?, schema: BiomeStreamSchema?, numbers: [Int], id: String, key: String, depth: Int) -> DataNode {
        if let spec {
            switch spec.kind {
            case .app:
                if let s = String(data: d, encoding: .utf8) {
                    let name = appName(s)
                    return DataNode(id: id, key: key, kind: "string", value: s, hint: name != s ? name : nil)
                }
            case .string, .json:
                if let s = String(data: d, encoding: .utf8) { return DataNode(id: id, key: key, kind: "string", value: s) }
            case .uuidBytes:
                if d.count == 16 { return DataNode(id: id, key: key, kind: "uuid", value: NSUUID(uuidBytes: Array(d)).uuidString, raw: d) }
            case .plist:
                if let plist = PlistDecoder.decodeAny(d) {
                    let sub = DataNode.from(plist, key: key, path: id + "$")
                    return DataNode(id: id, key: key, kind: "plist", value: Format.bytes(d.count), children: sub.children ?? [sub], raw: d)
                }
            case .bytes:
                return DataNode(id: id, key: key, kind: "data", value: Format.bytes(d.count), raw: d)
            default: break
            }
        }
        // A documented sub-path below this field means it is a message.
        let hasDocumentedChildren = schema?.fields.contains { $0.path.count > numbers.count && Array($0.path.prefix(numbers.count)) == numbers } ?? false
        if hasDocumentedChildren, depth < 24, let sub = ProtoMessage(d) {
            let children = nodes(sub, schema: schema, numbers: numbers, path: id, depth: depth + 1)
            return DataNode(id: id, key: key, kind: "message", value: "\(sub.fields.count) field\(sub.fields.count == 1 ? "" : "s")", children: children, raw: d)
        }
        switch field.guess {
        case .string(let s):
            return DataNode(id: id, key: key, kind: "string", value: s)
        case .message(let sub):
            let children = depth < 24 ? nodes(sub, schema: schema, numbers: numbers, path: id, depth: depth + 1) : []
            return DataNode(id: id, key: key, kind: "message", value: "\(sub.fields.count) field\(sub.fields.count == 1 ? "" : "s")", children: children, raw: d)
        case .data, .number:
            if d.count > 8, let plist = PlistDecoder.decodeAny(d) {
                let sub = DataNode.from(plist, key: key, path: id + "$")
                return DataNode(id: id, key: key, kind: "plist", value: Format.bytes(d.count), children: sub.children ?? [sub], raw: d)
            }
            if d.count == 16 {
                return DataNode(id: id, key: key, kind: "data", value: NSUUID(uuidBytes: Array(d)).uuidString, hint: "16 bytes as UUID", raw: d)
            }
            let hex = d.prefix(24).map { String(format: "%02x", $0) }.joined()
            return DataNode(id: id, key: key, kind: "data", value: Format.bytes(d.count), hint: hex + (d.count > 24 ? "…" : ""), raw: d)
        }
    }
}
