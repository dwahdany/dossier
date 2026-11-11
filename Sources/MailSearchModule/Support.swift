import Foundation
import Compression
import DossierCore

// MARK: - Store locations

/// Every location this module reads. All derived at runtime from the home directory.
enum MSPaths {
    /// `~/Library/Biome/sets` — Cascade sets (one SQLite `Set.db` per set / source).
    static var cascadeRoot: URL { Paths.biomeSets }

    /// `…/Daemon Containers/<hybridsearchd>/Data/Library/HybridSearch`
    static var hybridSearch: URL? {
        Paths.daemonContainerData("com.apple.hybridsearchd")?.appendingPathComponent("Library/HybridSearch", isDirectory: true)
    }

    /// The Kuzu database file of the semantic index (the directory under `index/` is
    /// versioned, so the largest `index.db` wins).
    static var hybridIndexFile: URL? {
        guard let root = hybridSearch?.appendingPathComponent("index", isDirectory: true) else { return nil }
        let fm = FileManager.default
        var best: (URL, Int64)?
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let candidate = dir.appendingPathComponent("index.db")
            if let size = FileProbe.info(candidate)?.size, size > (best?.1 ?? -1) { best = (candidate, size) }
        }
        return best?.0 ?? root.appendingPathComponent("C/index.db")
    }

    static var hybridBookmarks: URL? { hybridSearch?.appendingPathComponent("bookmarks", isDirectory: true) }

    /// `…/Daemon Containers/<kvs>/Data/com.apple.kvs`
    static var kvs: URL? {
        Paths.daemonContainerData("com.apple.kvs")?.appendingPathComponent("com.apple.kvs", isDirectory: true)
    }

    static var coreSpotlight: URL { Paths.coreSpotlight }
    static var pipelineStorage: URL { coreSpotlight.appendingPathComponent("DocumentProcessing/PipelineStorage", isDirectory: true) }
    static var stateStore: URL { pipelineStorage.appendingPathComponent("StateStore.db") }
    static var cachedResultStore: URL { pipelineStorage.appendingPathComponent("CachedResultStore.db") }
    static var completenessJSON: URL { coreSpotlight.appendingPathComponent("DocumentProcessing/SettingsUIPipelineCompleteness/latest.json") }
    static var knowledgeGraph: URL { Paths.spotlightKnowledge.appendingPathComponent("index.V2/KG/kg") }
    static var spotlightAppSupport: URL { Paths.library.appendingPathComponent("Application Support/com.apple.spotlight", isDirectory: true) }
}

// MARK: - Cascade content blobs (LZFSE lives in DossierCore)

/// The `content` column of a Cascade `Set.db`.
///
/// Observed encodings (macOS 26/27): sets that enable compression prefix every blob with
/// a flag byte — `0x01` followed by an LZFSE stream (`bvx2`, `bvxn`, `bvx-` blocks) or
/// `0x00` followed by the raw bytes; sets without compression store the protobuf message
/// directly (first byte is then a protobuf tag such as `0x0A`).
enum CascadeBlob {
    static func isCompressed(_ raw: Data) -> Bool {
        raw.count > 5 && raw[raw.startIndex] == 0x01
            && raw[raw.startIndex + 1] == 0x62 && raw[raw.startIndex + 2] == 0x76 && raw[raw.startIndex + 3] == 0x78
    }

    static func decode(_ raw: Data) -> Data {
        guard let first = raw.first else { return raw }
        if isCompressed(raw) {
            return LZFSE.decode(raw.subdata(in: (raw.startIndex + 1)..<raw.endIndex)) ?? Data()
        }
        if first == 0x00 { return raw.subdata(in: (raw.startIndex + 1)..<raw.endIndex) }
        return raw
    }
}

// MARK: - Byte-level text search

/// Case-insensitive substring test on raw UTF-8 bytes, used to search decompressed text
/// without building a `String` per item. ASCII letters fold exactly; for a needle with
/// non-ASCII letters its lower- and upper-cased spellings are both tried (a word that
/// mixes the case of its non-ASCII letters is not found).
struct TextNeedle: Sendable {
    private let variants: [[UInt8]]

    init(_ text: String) {
        let lower = Array(text.lowercased().utf8)
        var all = [lower]
        if lower.contains(where: { $0 >= 0x80 }) {
            // Per character, and only where the capital is a single character ("ß" stays).
            let capitals = String(text.lowercased().map { ch -> Character in
                let up = String(ch).uppercased()
                return up.count == 1 ? Character(up) : ch
            })
            let upper = Array(capitals.utf8).map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
            if upper != lower { all.append(upper) }
        }
        variants = all.filter { !$0.isEmpty }
    }

    func matches(_ data: Data) -> Bool {
        if variants.isEmpty { return true }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            for variant in variants where Self.contains(base, raw.count, variant) { return true }
            return false
        }
    }

    private static func contains(_ base: UnsafePointer<UInt8>, _ count: Int, _ needle: [UInt8]) -> Bool {
        let m = needle.count
        guard count >= m else { return false }
        return needle.withUnsafeBufferPointer { n -> Bool in
            let first = n[0]
            // Both spellings of an ASCII first letter; memchr does the bulk of the work.
            let other: UInt8 = (first >= 97 && first <= 122) ? first - 32 : first
            let last = count - m
            // Next occurrence of each spelling at or after `from` (Int.max = none); kept
            // across iterations so a rare spelling is not searched for again and again.
            func find(_ byte: UInt8, _ from: Int) -> Int {
                guard let hit = memchr(base + from, Int32(byte), last - from + 1) else { return Int.max }
                return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
            }
            var from = 0
            var nextA = -1, nextB = other != first ? -1 : Int.max
            while from <= last {
                if nextA < from { nextA = find(first, from) }
                if nextB < from { nextB = find(other, from) }
                let at = min(nextA, nextB)
                if at == Int.max { return false }
                var j = 1
                while j < m {
                    var c = base[at + j]
                    if c >= 65 && c <= 90 { c += 32 }
                    if c != n[j] { break }
                    j += 1
                }
                if j == m { return true }
                from = at + 1
            }
            return false
        }
    }
}

// MARK: - Minimal protobuf walker

/// Allocation-free protobuf field iterator used on hot paths (the mail index decodes
/// hundreds of thousands of messages; `ProtoMessage` would materialize every field).
struct PBWalker {
    let base: UnsafePointer<UInt8>
    var pos: Int
    let end: Int

    struct Field {
        let number: Int
        let wire: Int
        /// Varint value, or the raw little-endian bits of a fixed32 / fixed64.
        let scalar: UInt64
        /// Byte range of a length-delimited value.
        let start: Int
        let length: Int
    }

    init(_ base: UnsafePointer<UInt8>, _ range: Range<Int>) {
        self.base = base; self.pos = range.lowerBound; self.end = range.upperBound
    }

    private mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < end, shift < 64 {
            let byte = base[pos]; pos += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func next() -> Field? {
        guard pos < end, let key = varint() else { return nil }
        let number = Int(key >> 3), wire = Int(key & 7)
        guard number > 0 else { return nil }
        switch wire {
        case 0:
            guard let value = varint() else { return nil }
            return Field(number: number, wire: wire, scalar: value, start: pos, length: 0)
        case 1:
            guard pos + 8 <= end else { return nil }
            var value: UInt64 = 0
            memcpy(&value, base + pos, 8)
            pos += 8
            return Field(number: number, wire: wire, scalar: UInt64(littleEndian: value), start: pos - 8, length: 8)
        case 5:
            guard pos + 4 <= end else { return nil }
            var value: UInt32 = 0
            memcpy(&value, base + pos, 4)
            pos += 4
            return Field(number: number, wire: wire, scalar: UInt64(UInt32(littleEndian: value)), start: pos - 4, length: 4)
        case 2:
            guard let length = varint(), length <= UInt64(end - pos) else { return nil }
            let start = pos
            pos += Int(length)
            return Field(number: number, wire: wire, scalar: 0, start: start, length: Int(length))
        default:
            return nil
        }
    }

    /// First length-delimited occurrence of `number`.
    static func find(_ base: UnsafePointer<UInt8>, _ range: Range<Int>, _ number: Int) -> Range<Int>? {
        var walker = PBWalker(base, range)
        while let field = walker.next() {
            if field.number == number, field.wire == 2 { return field.start..<(field.start + field.length) }
        }
        return nil
    }

    static func string(_ base: UnsafePointer<UInt8>, _ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(start: base + range.lowerBound, count: range.count), as: UTF8.self)
    }
}

// MARK: - Small helpers

enum MSDebug {
    /// `DOSSIER_MAILSEARCH_AUTOSTART=1` starts the on-demand jobs (mail index, hybrid
    /// search file scan) as soon as their section appears — for offscreen snapshots of
    /// the finished state. Normally both wait for the user.
    static var autoStartJobs: Bool { ProcessInfo.processInfo.environment["DOSSIER_MAILSEARCH_AUTOSTART"] != nil }
}

enum MSFormat {
    /// One-line preview of a property-list value for table cells.
    static func preview(_ value: PlistValue, max: Int = 180) -> String {
        var out = ""
        func walk(_ v: PlistValue, _ depth: Int) {
            guard out.count < max else { return }
            switch v {
            case .dict(let pairs):
                if depth > 2 { out += "{\(pairs.count) keys}"; return }
                if depth > 0 { out += "{" }
                // Text first: names and addresses say more than version counters.
                let ordered = pairs.filter { if case .string = $0.value { return true } else { return false } }
                    + pairs.filter { if case .string = $0.value { return false } else { return true } }
                for (index, pair) in ordered.enumerated() {
                    if out.count >= max { break }
                    if index > 0 { out += ", " }
                    out += pair.key + ": "
                    walk(pair.value, depth + 1)
                }
                if depth > 0 { out += "}" }
            case .array(let items):
                if depth > 2 || items.count > 6 {
                    out += "[\(items.count) items"
                    if let first = items.first, depth <= 2 { out += ": "; walk(first, depth + 2); out += ", …" }
                    out += "]"
                    return
                }
                out += "["
                for (index, item) in items.enumerated() {
                    if out.count >= max { break }
                    if index > 0 { out += ", " }
                    walk(item, depth + 1)
                }
                out += "]"
            case .string(let s):
                out += s.count > 60 ? String(s.prefix(60)) + "…" : s
            default:
                out += PlistDecoder.describe(v)
            }
        }
        walk(value, 0)
        return Format.oneLine(out, max: max)
    }

    /// "12,345 of 67,890" style fraction.
    static func fraction(_ a: Int, of b: Int) -> String { "\(Format.count(a)) of \(Format.count(b))" }

    /// Folder size without following symlinks; bounded.
    static func directoryBytes(_ url: URL?) -> Int64 {
        guard let url, Paths.probe(url).isAvailable else { return 0 }
        return FileProbe.directorySize(url, maxFiles: 200_000).bytes
    }
}

extension Data {
    /// UTF-8 text of a blob, lossy.
    var lossyUTF8: String { String(decoding: self, as: UTF8.self) }
}

/// Runs `body` over indices `0..<count` on all cores (CPU-bound decode work).
func msConcurrentMap<T>(_ count: Int, _ body: @escaping @Sendable (Int) -> T) -> [T] {
    guard count > 0 else { return [] }
    let storage = UnsafeMutablePointer<T>.allocate(capacity: count)
    let box = UnsafeSendableBox(storage)
    DispatchQueue.concurrentPerform(iterations: count) { index in
        (box.pointer + index).initialize(to: body(index))
    }
    let result = Array(UnsafeBufferPointer(start: storage, count: count))
    storage.deinitialize(count: count)
    storage.deallocate()
    return result
}

struct UnsafeSendableBox<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>
    init(_ pointer: UnsafeMutablePointer<T>) { self.pointer = pointer }
}
