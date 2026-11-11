import Foundation
import DossierCore

// The semantic index of hybridsearchd is a Kuzu graph / vector database
// (`HybridSearch/index/<v>/index.db` + `.wal`). It is not SQLite and its catalog and
// column pages are stored in Kuzu's own encoded page format, so the file cannot be
// queried here. What *is* readable are the string overflow pages: every indexed item
// carries a JSON payload (the message / attachment as handed to the indexer), and any
// payload that fits a page run is stored verbatim. The scanner below memory-maps the file
// one 32 MB window at a time and extracts those complete JSON objects. It never loads the
// file, keeps only offsets in memory, reports progress and can be cancelled.

struct KuzuHeader: Sendable, Hashable {
    let storageVersion: UInt64
    let catalogPage: UInt32
    let catalogPages: UInt32
    let metadataPage: UInt32
    let metadataPages: UInt32
    let databaseID: String
    let pageCount: Int
}

enum KuzuPayloadKind: String, Sendable, CaseIterable {
    case mail = "Mail message"
    case attachment = "Attachment document"
    case fragment = "Fragment"

    var symbol: String {
        switch self {
        case .mail: return "envelope"
        case .attachment: return "doc.text"
        case .fragment: return "curlybraces"
        }
    }
}

/// One complete JSON object found in the file. Only its location is kept.
struct KuzuPayload: Identifiable, Sendable, Hashable {
    var id: String { (inWAL ? "w" : "m") + String(offset) }
    let offset: Int
    let length: Int
    let inWAL: Bool
    let kind: KuzuPayloadKind
    let title: String
    let subtitle: String
    let date: Date?
    let keyCount: Int
    let textLength: Int
}

struct KuzuKeyStat: Identifiable, Sendable, Hashable {
    var id: String { kind.rawValue + "." + key }
    let kind: KuzuPayloadKind
    let key: String
    let count: Int
    let type: String
}

struct KuzuCollection: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    /// A `<name>_nodes` companion bookmark exists (the collection has a node table).
    let hasNodes: Bool
    let bookmarkBytes: Int
    let modified: Date?
}

struct KuzuReport: Sendable {
    enum Phase: Sendable, Equatable { case idle, scanning, finished, cancelled, missing, inaccessible(String), failed(String) }
    var phase: Phase = .idle
    var file: URL?
    var fileBytes: Int64 = 0
    var walBytes: Int64 = 0
    var scannedBytes: Int64 = 0
    var seconds: Double = 0
    var header: KuzuHeader?
    var candidates = 0
    var payloads: [KuzuPayload] = []
    var kindCounts: [KuzuPayloadKind: Int] = [:]
    var walPayloads = 0
    var keyStats: [KuzuKeyStat] = []
    var collections: [KuzuCollection] = []
    /// Occurrences of the marker every indexed payload contains, complete or not.
    var payloadMarkers = 0
    /// The app was refreshed after this scan: the file may have changed since.
    var stale = false

    var totalBytes: Int64 { fileBytes + walBytes }
    var fraction: Double { totalBytes > 0 ? min(1, Double(scannedBytes) / Double(totalBytes)) : 0 }
}

actor KuzuScanner {
    static let shared = KuzuScanner()

    /// Payloads kept for browsing (the counts always cover everything found).
    static let keepLimit = 5_000
    private static let window = 32 << 20
    private static let maxObject = 512 << 10

    private var report = KuzuReport()
    private var task: Task<Void, Never>?
    private var token = -1
    private var keyAccumulator: [KuzuPayloadKind: [String: (count: Int, type: String)]] = [:]

    func current() -> KuzuReport { report }

    func sync(token: Int) {
        guard token != self.token else { return }
        let first = self.token == -1
        self.token = token
        // A refresh does not rescan the multi-GB file on its own: a finished (or
        // cancelled) result is kept and marked stale; the section offers Rescan.
        if !first, report.phase == .finished || report.phase == .cancelled { report.stale = true }
    }

    func start() {
        guard task == nil else { return }
        if report.phase == .finished || report.phase == .scanning { return }
        report = KuzuReport(phase: .scanning)
        keyAccumulator = [:]
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.scan()
        }
    }

    func cancel() { task?.cancel() }

    /// Forgets the previous result so the next ``start()`` scans again.
    func reset() {
        task?.cancel(); task = nil
        report = KuzuReport(); keyAccumulator = [:]
    }

    /// Cheap facts that need no scan: header and collection bookmarks.
    static func quickLook() -> (file: URL?, availability: Availability, bytes: Int64, walBytes: Int64, header: KuzuHeader?, collections: [KuzuCollection]) {
        guard let file = MSPaths.hybridIndexFile else { return (nil, .missing, 0, 0, nil, []) }
        let availability = Paths.probe(file)
        let bytes = FileProbe.info(file)?.size ?? 0
        let wal = FileProbe.info(URL(fileURLWithPath: file.path + ".wal"))?.size ?? 0
        var header: KuzuHeader?
        if availability.isAvailable, let handle = try? FileHandle(forReadingFrom: file) {
            let head = (try? handle.read(upToCount: 64)) ?? Data()
            try? handle.close()
            header = parseHeader(head, fileBytes: bytes)
        }
        return (file, availability, bytes, wal, header, collections())
    }

    /// Header layout (inferred from the file, little-endian): "KUZU" magic, u64 storage
    /// version at 4, u32 catalog start page + u32 page count at 12, u32 metadata start
    /// page + u32 page count at 20, 16-byte database identifier at 28. Pages are 4 KiB.
    static func parseHeader(_ head: Data, fileBytes: Int64) -> KuzuHeader? {
        guard head.count >= 44, head.prefix(4) == Data("KUZU".utf8) else { return nil }
        func u32(_ at: Int) -> UInt32 { head.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u64(_ at: Int) -> UInt64 { head.subdata(in: at..<(at + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian }
        let idBytes = [UInt8](head.subdata(in: 28..<44))
        let hex = idBytes.map { String(format: "%02X", $0) }.joined()
        return KuzuHeader(
            storageVersion: u64(4), catalogPage: u32(12), catalogPages: u32(16), metadataPage: u32(20), metadataPages: u32(24),
            databaseID: hex, pageCount: Int(fileBytes / 4096)
        )
    }

    static func collections() -> [KuzuCollection] {
        guard let dir = MSPaths.hybridBookmarks,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        let names = Set(files.map(\.lastPathComponent))
        return files.compactMap { url -> KuzuCollection? in
            let name = url.lastPathComponent
            guard !name.hasSuffix("_nodes"), !name.hasPrefix(".") else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return KuzuCollection(name: name, hasNodes: names.contains(name + "_nodes"), bookmarkBytes: values?.fileSize ?? 0, modified: values?.contentModificationDate)
        }.sorted { $0.name < $1.name }
    }

    // MARK: Scan

    private func scan() async {
        let started = Date()
        defer { task = nil }
        let quick = Self.quickLook()
        report.file = quick.file
        report.fileBytes = quick.bytes
        report.walBytes = quick.walBytes
        report.header = quick.header
        report.collections = quick.collections
        guard let file = quick.file else { report.phase = .missing; return }
        switch quick.availability {
        case .missing: report.phase = .missing; return
        case .inaccessible(let reason): report.phase = .inaccessible(reason); return
        default: break
        }
        do {
            try await scan(file, inWAL: false, started: started)
            let walURL = URL(fileURLWithPath: file.path + ".wal")
            if FileManager.default.fileExists(atPath: walURL.path) {
                try await scan(walURL, inWAL: true, started: started)
            }
            report.scannedBytes = report.totalBytes
            finalizeKeys()
            report.seconds = Date().timeIntervalSince(started)
            report.phase = .finished
        } catch is CancellationError {
            finalizeKeys()
            report.seconds = Date().timeIntervalSince(started)
            report.phase = .cancelled
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
                report.phase = .inaccessible(ns.localizedDescription)
            } else {
                report.phase = .failed(ns.localizedDescription)
            }
        }
    }

    private struct Found: Sendable {
        var payloads: [KuzuPayload] = []
        var keys: [(KuzuPayloadKind, String, String)] = []
        var candidates = 0
        var markers = 0
        var resume = 0
    }

    /// Scans one file window by window. Each window is mapped on its own (plus an overlap
    /// so objects may run past its end) and unmapped again, so resident memory stays at
    /// one window no matter how large the file is.
    private func scan(_ url: URL, inWAL: Bool, started: Date) async throws {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else {
            let code = errno
            if inWAL { return }
            throw NSError(domain: NSCocoaErrorDomain, code: code == EACCES || code == EPERM ? NSFileReadNoPermissionError : NSFileReadUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return }
        let size = Int(st.st_size)
        if inWAL { report.walBytes = Int64(size) } else { report.fileBytes = Int64(size) }
        var position = 0
        let base: Int64 = inWAL ? report.fileBytes : 0
        while position < size {
            try Task.checkCancellation()
            let end = min(size, position + Self.window)
            let found = await Self.scanWindow(fd: fd, fileSize: size, from: position, to: end, inWAL: inWAL)
            report.candidates += found.candidates
            report.payloadMarkers += found.markers
            for payload in found.payloads {
                report.kindCounts[payload.kind, default: 0] += 1
                if inWAL { report.walPayloads += 1 }
                if payload.kind != .fragment || report.payloads.count < Self.keepLimit / 2 {
                    if report.payloads.count < Self.keepLimit { report.payloads.append(payload) }
                }
            }
            for (kind, key, type) in found.keys {
                var slot = keyAccumulator[kind, default: [:]][key] ?? (count: 0, type: type)
                slot.count += 1
                if slot.type == "null" { slot.type = type }
                keyAccumulator[kind, default: [:]][key] = slot
            }
            position = max(end, found.resume)
            report.scannedBytes = base + Int64(min(position, size))
            report.seconds = Date().timeIntervalSince(started)
        }
    }

    private func finalizeKeys() {
        var stats: [KuzuKeyStat] = []
        for (kind, keys) in keyAccumulator {
            for (key, value) in keys { stats.append(KuzuKeyStat(kind: kind, key: key, count: value.count, type: value.type)) }
        }
        report.keyStats = stats.sorted { ($0.kind.rawValue, -$0.count, $0.key) < ($1.kind.rawValue, -$1.count, $1.key) }
    }

    /// Finds `{"` candidates between `from` and `to` and validates each as a complete JSON
    /// object (which may extend past `to`). Runs off the actor.
    private static func scanWindow(fd: Int32, fileSize: Int, from: Int, to: Int, inWAL: Bool) async -> Found {
        var found = Found()
        found.resume = to
        // `from` is a multiple of the window size and therefore page-aligned.
        let mapLength = min(fileSize, to + maxObject) - from
        guard mapLength > 0, let raw = mmap(nil, mapLength, PROT_READ, MAP_PRIVATE, fd, off_t(from)), raw != MAP_FAILED else { return found }
        defer { munmap(raw, mapLength) }
        let start = UnsafePointer<UInt8>(raw.assumingMemoryBound(to: UInt8.self))
        let limit = to - from                                             // candidates must start before this
        let needle: [UInt8] = [0x7B, 0x22]                                // {"
        let marker = Array("\"sourceBundleIdentifier\":".utf8)
        // Marker count (how many payloads, complete or cut by a page boundary, exist).
        var m = 0
        while m < limit, let hit = memmem(start + m, limit - m, marker, marker.count) {
            found.markers += 1
            m = start.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + marker.count
        }
        var position = 0
        while position < limit, let hit = memmem(start + position, limit - position, needle, 2) {
            let offset = start.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            position = offset + 2
            guard offset + 3 < mapLength else { break }
            let c = start[offset + 2]
            guard (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F else { continue }
            found.candidates += 1
            guard let length = jsonObjectLength(start + offset, limit: min(mapLength - offset, maxObject)), length >= 24 else { continue }
            let slice = Data(bytes: start + offset, count: length)
            guard let object = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any], object.count >= 2 else { continue }
            let payload = describe(object, offset: from + offset, length: length, inWAL: inWAL)
            found.payloads.append(payload)
            for (key, value) in object { found.keys.append((payload.kind, key, typeName(value))) }
            position = offset + length
            found.resume = max(found.resume, from + position)
        }
        return found
    }

    /// Length of the JSON object starting at `p` (which points at `{`), or nil if the
    /// bytes stop being JSON before the object closes. Strict about control bytes, so
    /// binary data is rejected within a few bytes.
    static func jsonObjectLength(_ p: UnsafePointer<UInt8>, limit: Int) -> Int? {
        var depth = 0
        var i = 0
        var inString = false
        while i < limit {
            let c = p[i]
            if inString {
                if c == 0x5C { i += 2; continue }                            // escape
                if c == 0x22 { inString = false } else if c < 0x20 { return nil }
                i += 1
                continue
            }
            switch c {
            case 0x22: inString = true
            case 0x7B, 0x5B: depth += 1; if depth > 64 { return nil }
            case 0x7D, 0x5D:
                depth -= 1
                if depth == 0 { return c == 0x7D ? i + 1 : nil }
                if depth < 0 { return nil }
            case 0x20, 0x0A, 0x0D, 0x09, 0x2C, 0x3A, 0x2D, 0x2B, 0x2E, 0x30...0x39, 0x45, 0x65:
                break
            case 0x74, 0x72, 0x75, 0x66, 0x61, 0x6C, 0x73, 0x6E:               // true / false / null letters
                break
            default:
                return nil
            }
            i += 1
        }
        return nil
    }

    private static func typeName(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? "bool" : "number"
        case is String: return "string"
        case let a as [Any]: return a.isEmpty ? "array" : "array of \(typeName(a[0]))"
        case is [String: Any]: return "object"
        default: return "value"
        }
    }

    private static func address(_ value: Any?) -> String {
        guard let dict = value as? [String: Any] else { return "" }
        let name = dict["displayName"] as? String ?? "", email = dict["emailAddress"] as? String ?? ""
        if name.isEmpty { return email }
        return email.isEmpty ? name : "\(name) <\(email)>"
    }

    private static func describe(_ object: [String: Any], offset: Int, length: Int, inWAL: Bool) -> KuzuPayload {
        var kind = KuzuPayloadKind.fragment
        var title = "", subtitle = ""
        var textLength = 0
        if object["subject"] != nil, object["sender"] != nil || object["bodySnippet"] != nil || object["body"] != nil {
            kind = .mail
            title = object["subject"] as? String ?? ""
            subtitle = address(object["sender"])
            textLength = (object["bodyLength"] as? Int) ?? (object["body"] as? String)?.count ?? 0
        } else if object["textContent"] != nil || object["textContentSnippet"] != nil || object["contentURL"] != nil {
            kind = .attachment
            title = object["name"] as? String ?? ""
            subtitle = address(object["sender"])
            textLength = (object["textContentLength"] as? Int) ?? (object["textContent"] as? String)?.count ?? 0
        } else {
            title = (object["name"] as? String) ?? (object["displayName"] as? String) ?? (object["emailAddress"] as? String) ?? ""
            subtitle = (object["type"] as? String) ?? (object["kind"] as? String) ?? object.keys.sorted().prefix(6).joined(separator: ", ")
            if title.isEmpty { title = object.keys.sorted().prefix(4).joined(separator: ", ") }
        }
        var date: Date?
        for key in ["dateSent", "dateReceived", "filterDate"] {
            if let number = object[key] as? Double, let guess = DossierDate.guess(number) { date = guess.date; break }
        }
        return KuzuPayload(
            offset: offset, length: length, inWAL: inWAL, kind: kind, title: Format.oneLine(title, max: 200),
            subtitle: Format.oneLine(subtitle, max: 160), date: date, keyCount: object.count, textLength: textLength
        )
    }

    // MARK: Payload access

    /// The raw JSON text of a payload, read back from the file on demand.
    func payloadData(_ payload: KuzuPayload) -> Data? {
        guard let file = report.file else { return nil }
        let url = payload.inWAL ? URL(fileURLWithPath: file.path + ".wal") : file
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(payload.offset))) != nil,
              let slice = try? handle.read(upToCount: payload.length), slice.count == payload.length else { return nil }
        // The file may have changed since the scan; only hand back what still parses.
        guard (try? JSONSerialization.jsonObject(with: slice)) != nil else { return nil }
        return slice
    }
}
