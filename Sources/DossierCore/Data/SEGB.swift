import Foundation

/// Reader for Biome "SEGB" segment files.
///
/// Two on-disk framings exist:
///
/// **Version 2** (macOS 14+; the only one found on current systems) — magic at offset 0:
/// ```
/// header (32 bytes):  "SEGB" | u32 entryCount | f64 created (Cocoa) | u32 ? | u32 ? | 8 bytes 0
/// records from offset 32, each aligned to 4 bytes:  u32 crc32(payload) | u32 ? | payload
/// trailer, growing backwards from EOF, 16 bytes per entry (entry i at EOF-16*(i+1)):
///                     u32 endOffset (relative to 32) | u32 state | f64 timestamp (Cocoa)
/// ```
/// Files are preallocated (zero-filled between the last record and the trailer).
///
/// **Version 1** (macOS 13 and earlier, iOS ≤ 16) — magic at offset 52:
/// ```
/// header (56 bytes):  u32 endOfData | ... | "SEGB" at 52
/// records from offset 56, each aligned to 8 bytes:
///                     i32 length | i32 state | f64 timestamp1 | f64 timestamp2 | u32 crc32 | i32 ? | payload
/// ```
///
/// Record states: 1 = written, 3 = deleted (payload zeroed), 4 = written-other; anything
/// else is treated as unknown. The reader memory-maps the file, builds a compact index
/// (16–24 bytes per record) and copies a payload only when it is asked for.
public final class SEGBFile: @unchecked Sendable {
    public enum Version: Int, Sendable { case v1 = 1, v2 = 2 }

    public enum State: Sendable, Hashable {
        case written, deleted, other(Int32)
        init(raw: Int32) {
            switch raw {
            case 1: self = .written
            case 3: self = .deleted
            default: self = .other(raw)
            }
        }
        public var label: String {
            switch self {
            case .written: return "written"
            case .deleted: return "deleted"
            case .other(let v): return "state \(v)"
            }
        }
        /// True if the record is expected to carry a payload.
        public var isLive: Bool { if case .deleted = self { return false } else { return true } }
    }

    /// Index entry for one record (no payload).
    public struct Entry: Sendable, Hashable {
        /// Position within the file (0-based, oldest first).
        public let index: Int
        /// Absolute byte range of the payload inside the file.
        public let payloadRange: Range<Int>
        public let state: State
        /// Record timestamp (v2: trailer timestamp; v1: first header timestamp).
        public let timestamp: Date
        /// Stored CRC-32 of the payload.
        public let crc: UInt32
        public var length: Int { payloadRange.count }
    }

    public enum ReadError: Error, LocalizedError {
        case notSEGB
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .notSEGB: return "Not a SEGB file"
            case .unreadable(let m): return m
            }
        }
    }

    public let url: URL
    public let version: Version
    /// Segment creation time (v2 header). Nil for v1.
    public let created: Date?
    /// All index entries, oldest first (including deleted ones).
    public let entries: [Entry]
    private let data: Data

    /// Maps the file and builds the record index. Cheap: touches only the header and the
    /// trailer (v2) or the record headers (v1).
    public init(url: URL) throws {
        self.url = url
        guard Paths.allows(url) else { throw ReadError.unreadable("Outside the demo root") }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.alwaysMapped])
        } catch {
            throw ReadError.unreadable(error.localizedDescription)
        }
        self.data = data
        let size = data.count
        let magic: [UInt8] = [0x53, 0x45, 0x47, 0x42]
        if size >= 32, data.prefix(4).elementsEqual(magic) {
            version = .v2
            let (created, entries) = SEGBFile.indexV2(data)
            self.created = created
            self.entries = entries
        } else if size >= 56, data[data.startIndex + 52..<data.startIndex + 56].elementsEqual(magic) {
            version = .v1
            created = nil
            entries = SEGBFile.indexV1(data)
        } else {
            throw ReadError.notSEGB
        }
    }

    /// Quick check without building an index.
    public static func isSEGB(_ url: URL) -> Bool {
        guard Paths.allows(url), let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 56)) ?? Data()
        let magic = Data([0x53, 0x45, 0x47, 0x42])
        if head.count >= 4, head.prefix(4) == magic { return true }
        if head.count >= 56, head.subdata(in: 52..<56) == magic { return true }
        return false
    }

    // MARK: Indexing

    private static func indexV2(_ data: Data) -> (Date?, [Entry]) {
        data.withUnsafeBytes { raw -> (Date?, [Entry]) in
            let size = raw.count
            let declared = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let createdRaw = raw.loadUnaligned(fromByteOffset: 8, as: Double.self)
            let created: Date? = createdRaw.isFinite && createdRaw > 0 ? DossierDate.cocoa(createdRaw) : nil
            let headerSize = 32
            let maxEntries = max(0, (size - headerSize) / 16)
            let count = min(declared, maxEntries)
            var entries: [Entry] = []
            entries.reserveCapacity(count)
            var previousEnd = 0
            for i in 0..<count {
                let trailerOffset = size - 16 * (i + 1)
                let end = Int(raw.loadUnaligned(fromByteOffset: trailerOffset, as: UInt32.self))
                let state = raw.loadUnaligned(fromByteOffset: trailerOffset + 4, as: Int32.self)
                let ts = raw.loadUnaligned(fromByteOffset: trailerOffset + 8, as: Double.self)
                let trailerStart = size - 16 * count
                let start = (previousEnd + 3) & ~3
                // Robustness: entries must be monotonic and stay inside the data area.
                guard end >= start, headerSize + end <= trailerStart else {
                    if end > previousEnd, headerSize + end <= trailerStart { previousEnd = end }
                    continue
                }
                previousEnd = end
                let recordStart = headerSize + start
                let recordEnd = headerSize + end
                guard recordEnd - recordStart >= 8 else { continue }   // empty / unused slot
                let crc = raw.loadUnaligned(fromByteOffset: recordStart, as: UInt32.self)
                entries.append(Entry(
                    index: entries.count,
                    payloadRange: (recordStart + 8)..<recordEnd,
                    state: State(raw: state),
                    timestamp: ts.isFinite ? DossierDate.cocoa(ts) : .distantPast,
                    crc: crc
                ))
            }
            return (created, entries)
        }
    }

    private static func indexV1(_ data: Data) -> [Entry] {
        data.withUnsafeBytes { raw -> [Entry] in
            let size = raw.count
            let headerSize = 56
            let recordHeader = 32
            var endOfData = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            if endOfData <= headerSize || endOfData > size { endOfData = size }
            var entries: [Entry] = []
            var offset = headerSize
            while offset + recordHeader <= endOfData {
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))
                let state = raw.loadUnaligned(fromByteOffset: offset + 4, as: Int32.self)
                let ts1 = raw.loadUnaligned(fromByteOffset: offset + 8, as: Double.self)
                let crc = raw.loadUnaligned(fromByteOffset: offset + 24, as: UInt32.self)
                // A zeroed header marks the end of written data.
                if length <= 0 || offset + recordHeader + length > size { break }
                let payloadStart = offset + recordHeader
                entries.append(Entry(
                    index: entries.count,
                    payloadRange: payloadStart..<(payloadStart + length),
                    state: State(raw: state),
                    timestamp: ts1.isFinite ? DossierDate.cocoa(ts1) : .distantPast,
                    crc: crc
                ))
                offset = (payloadStart + length + 7) & ~7
            }
            return entries
        }
    }

    // MARK: Access

    /// Number of live (not deleted) records.
    public var liveCount: Int { entries.reduce(0) { $0 + ($1.state.isLive ? 1 : 0) } }
    public var deletedCount: Int { entries.count - liveCount }

    /// Timestamp range of live records.
    public var timeRange: ClosedRange<Date>? {
        var lo: Date?, hi: Date?
        for e in entries where e.state.isLive && e.timestamp > Date(timeIntervalSinceReferenceDate: 0) {
            if lo.map({ e.timestamp < $0 }) ?? true { lo = e.timestamp }
            if hi.map({ e.timestamp > $0 }) ?? true { hi = e.timestamp }
        }
        guard let lo, let hi else { return nil }
        return lo...hi
    }

    /// Copies the payload bytes of one record out of the mapping.
    public func payload(_ entry: Entry) -> Data {
        guard entry.payloadRange.upperBound <= data.count, !entry.payloadRange.isEmpty else { return Data() }
        let base = data.startIndex
        return data.subdata(in: (base + entry.payloadRange.lowerBound)..<(base + entry.payloadRange.upperBound))
    }

    /// Verifies the stored CRC-32 against the payload.
    public func crcMatches(_ entry: Entry) -> Bool {
        CRC32.checksum(payload(entry)) == entry.crc
    }

    /// True if the payload consists only of zero bytes (deleted records are zero-filled).
    public func isZeroFilled(_ entry: Entry) -> Bool {
        data.withUnsafeBytes { raw in
            for i in entry.payloadRange where raw[i] != 0 { return false }
            return true
        }
    }

    public enum Order: Sendable { case oldestFirst, newestFirst }

    /// Lazily iterates live records (skipping deleted / zeroed ones), yielding the index
    /// entry and a copy of the payload.
    public func records(order: Order = .oldestFirst, includeDeleted: Bool = false) -> AnySequence<(entry: Entry, payload: Data)> {
        let source: AnySequence<Entry> = order == .oldestFirst ? AnySequence(entries) : AnySequence(entries.reversed())
        return AnySequence(source.lazy
            .filter { includeDeleted || $0.state.isLive }
            .map { (entry: $0, payload: self.payload($0)) })
    }
}

/// Table-driven CRC-32 (IEEE 802.3), as used by SEGB record checksums.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Biome stream discovery

/// Which device produced a segment.
public enum BiomeDevice: Sendable, Hashable {
    case local
    /// Synced from another device; the identifier matches `DevicePeer.device_identifier`
    /// in `~/Library/Biome/sync/sync.db`.
    case remote(String)

    public var isLocal: Bool { self == .local }
    public var identifier: String? { if case .remote(let id) = self { return id } else { return nil } }
}

/// One segment file of a stream.
public struct BiomeSegment: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let device: BiomeDevice
    public let size: Int64
    public let modified: Date?
    /// True for files in a `tombstone` subdirectory (deletion markers).
    public let isTombstone: Bool

    public init(url: URL, device: BiomeDevice, size: Int64, modified: Date?, isTombstone: Bool = false) {
        self.url = url; self.device = device; self.size = size; self.modified = modified; self.isTombstone = isTombstone
    }
}

/// A Biome stream directory (`<root>/<StreamName>/{local,remote/<device>}/<segment>`).
public struct BiomeStream: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let segments: [BiomeSegment]

    /// Normally obtained from ``Biome/stream(named:)`` / ``Biome/loadStream(_:)``; the
    /// initializer exists for segment files that live outside a standard stream directory.
    public init(name: String, url: URL, segments: [BiomeSegment]) {
        self.name = name; self.url = url; self.segments = segments
    }

    public var totalSize: Int64 { segments.reduce(0) { $0 + $1.size } }
    public var devices: [BiomeDevice] {
        var seen: [BiomeDevice] = []
        for s in segments where !seen.contains(s.device) { seen.append(s.device) }
        return seen
    }

    /// Data segments (no tombstones, non-empty), optionally restricted to one device,
    /// sorted oldest first (segment file names are creation timestamps).
    public func dataSegments(device: BiomeDevice? = nil) -> [BiomeSegment] {
        segments
            .filter { !$0.isTombstone && $0.size > 0 && (device == nil || $0.device == device) }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }
}

/// A synced device known to Biome (`sync.db` → `DevicePeer`).
public struct BiomeDevicePeer: Sendable, Hashable, Identifiable {
    public var id: String { identifier }
    public let identifier: String
    public let name: String?
    public let model: String?
    public let platform: Int?
    public let isMe: Bool
    public let lastSync: Date?

    public init(identifier: String, name: String? = nil, model: String? = nil, platform: Int? = nil, isMe: Bool = false, lastSync: Date? = nil) {
        self.identifier = identifier; self.name = name; self.model = model
        self.platform = platform; self.isMe = isMe; self.lastSync = lastSync
    }

    /// Platform code → name. Codes 2 and 3 were verified on real data.
    public static func platformName(_ code: Int?) -> String {
        switch code {
        case 2: return "iPhone / iPad"
        case 3: return "Mac"
        case 4: return "Apple Watch"
        case .some(let p): return "Platform \(p)"
        case nil: return "Unknown device"
        }
    }

    /// Human-readable platform name. Codes 2 (iOS device) and 3 (Mac) were observed in
    /// real data; 4 (Apple Watch) is an unverified assumption. `model` holds the OS build
    /// of the peer, not a hardware model.
    public var platformName: String { BiomeDevicePeer.platformName(platform) }

    /// The user-assigned device name if known, otherwise the platform name — never the raw
    /// identifier.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return platformName
    }
}

/// Turns Biome device identifiers into labels that never expose the identifier itself:
/// "This Mac", the peer's name or platform from `sync.db`, disambiguated by OS build or a
/// running number when several devices would otherwise share a label.
public struct BiomeDeviceNamer: Sendable {
    public let peers: [String: BiomeDevicePeer]
    private var labels: [String: String] = [:]
    public private(set) var localIdentifier: String?

    /// - Parameters:
    ///   - identifiers: devices that have data on this Mac (numbered first).
    ///   - others: further identifiers that only occur in bookkeeping (e.g. sync sites).
    ///   - platformHints: platform names for devices missing from `DevicePeer`
    ///     (identifier → e.g. "Apple Watch"), used as "Unlisted <platform>".
    public init(peers: [String: BiomeDevicePeer], identifiers: [String] = [], others: [String] = [], platformHints: [String: String] = [:]) {
        self.peers = peers
        localIdentifier = peers.values.first(where: \.isMe)?.identifier
        var bases: [(id: String, base: String, model: String?)] = []
        let primary = Set(identifiers).union(peers.keys).sorted()
        let secondary = Set(others).subtracting(primary).sorted()
        for id in primary + secondary {
            if id == localIdentifier { labels[id] = "This Mac"; continue }
            let peer = peers[id]
            let fallback = platformHints[id].map { "Unlisted \($0)" } ?? "Unknown device"
            var base = peer?.displayName ?? fallback
            // An unnamed Mac that is not this one: say so instead of a bare "Mac".
            if let peer, (peer.name ?? "").isEmpty, peer.platform == 3 { base = "Other Mac" }
            bases.append((id, base, peer?.model))
        }
        let grouped = Dictionary(grouping: bases, by: \.base)
        for (base, members) in grouped {
            if members.count == 1 { labels[members[0].id] = base; continue }
            let withModel = members.map { m in m.model.map { "\(base) (\($0))" } ?? base }
            if Set(withModel).count == members.count {
                for (m, label) in zip(members, withModel) { labels[m.id] = label }
            } else {
                for (i, m) in members.enumerated() { labels[m.id] = "\(base) \(i + 1)" }
            }
        }
    }

    /// Namer over every peer in `sync.db` plus the given extra identifiers.
    public static func load(identifiers: [String] = [], others: [String] = []) async -> BiomeDeviceNamer {
        BiomeDeviceNamer(peers: await Biome.devicePeers(), identifiers: identifiers, others: others)
    }

    public func label(_ device: BiomeDevice) -> String {
        switch device {
        case .local: return "This Mac"
        case .remote(let id): return label(identifier: id)
        }
    }

    public func label(identifier id: String) -> String {
        labels[id] ?? labels[id.uppercased()] ?? labels[id.lowercased()] ?? "Unknown device"
    }
}

public enum Biome {
    /// Stream roots that exist on this Mac: restricted/public Biome streams, the
    /// DuetExpertCenter streams and the linkd App Intents transcript container.
    public static func streamRoots() -> [URL] {
        var roots: [URL] = [
            Paths.biomeStreams.appendingPathComponent("restricted", isDirectory: true),
            Paths.biomeStreams.appendingPathComponent("public", isDirectory: true),
            Paths.duetExpertCenter.appendingPathComponent("streams", isDirectory: true),
        ]
        for daemon in ["com.apple.linkd", "com.apple.intelligentroutingd", "com.apple.milod"] {
            if let data = Paths.daemonContainerData(daemon) { roots.append(data) }
        }
        return roots.filter { Paths.probe($0).isAvailable }
    }

    /// Finds stream directories under `root`: any directory with a `local` or `remote`
    /// child. Searches at most `maxDepth` levels. Call off the main thread.
    public static func discoverStreams(under root: URL, maxDepth: Int = 6) -> [BiomeStream] {
        var out: [BiomeStream] = []
        let fm = FileManager.default
        func visit(_ dir: URL, depth: Int) {
            guard depth <= maxDepth, !Task.isCancelled else { return }
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
            let names = Set(children.map(\.lastPathComponent))
            if names.contains("local") || names.contains("remote") {
                if let stream = loadStream(dir), !stream.segments.isEmpty || names.contains("local") {
                    out.append(stream)
                    return
                }
            }
            for child in children {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// All streams under all ``streamRoots()``.
    public static func discoverAllStreams() -> [BiomeStream] {
        streamRoots().flatMap { discoverStreams(under: $0) }
    }

    /// The stream directory for a restricted stream name such as `App.InFocus`.
    public static func stream(named name: String) -> BiomeStream? {
        for root in streamRoots() {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            if Paths.probe(dir).isAvailable, let s = loadStream(dir) { return s }
        }
        return nil
    }

    /// Lists the segments of one stream directory.
    public static func loadStream(_ dir: URL) -> BiomeStream? {
        let fm = FileManager.default
        var segments: [BiomeSegment] = []

        func collect(_ folder: URL, device: BiomeDevice) {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: []) else { return }
            for item in items {
                let name = item.lastPathComponent
                guard let info = FileProbe.info(item) else { continue }
                if info.isDirectory {
                    guard name == "tombstone" else { continue }
                    let tombs = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [])) ?? []
                    for t in tombs {
                        guard let ti = FileProbe.info(t), !ti.isDirectory else { continue }
                        segments.append(BiomeSegment(url: t, device: device, size: ti.size, modified: ti.modified, isTombstone: true))
                    }
                } else if !name.hasPrefix(".") {
                    segments.append(BiomeSegment(url: item, device: device, size: info.size, modified: info.modified, isTombstone: false))
                }
            }
        }

        collect(dir.appendingPathComponent("local", isDirectory: true), device: .local)
        let remote = dir.appendingPathComponent("remote", isDirectory: true)
        if let devices = try? fm.contentsOfDirectory(at: remote, includingPropertiesForKeys: nil, options: []) {
            for device in devices where device.hasDirectoryPath || (FileProbe.info(device)?.isDirectory ?? false) {
                collect(device, device: .remote(device.lastPathComponent))
            }
        }
        return BiomeStream(name: dir.lastPathComponent, url: dir, segments: segments)
    }

    /// Synced device peers from `~/Library/Biome/sync/sync.db` keyed by device identifier.
    /// Empty if the database is missing or unreadable.
    public static func devicePeers() async -> [String: BiomeDevicePeer] {
        guard let db = await SQLiteDB.sharedIfAvailable(Paths.biomeSyncDB), await db.tableExists("DevicePeer") else { return [:] }
        let cols = await db.columnNames(of: "DevicePeer")
        guard cols.contains("device_identifier") else { return [:] }
        let rows = (try? await db.rows("SELECT * FROM DevicePeer")) ?? []
        var out: [String: BiomeDevicePeer] = [:]
        for row in rows {
            guard let id = row["device_identifier"].string else { continue }
            let peer = BiomeDevicePeer(
                identifier: id,
                name: row["name"].string,
                model: row["model"].string,
                platform: row["platform"].int.map(Int.init),
                isMe: row["me"].bool ?? false,
                // Unix seconds on current macOS, Cocoa seconds on older ones.
                lastSync: DossierDate.cocoaOrUnix(row["last_sync_date"].double)
            )
            out[id] = peer
        }
        return out
    }
}

/// Reads a whole stream (all segments of the selected devices) lazily, segment by segment.
public struct BiomeStreamReader: Sendable {
    public struct Record: Sendable, Identifiable {
        public var id: String { "\(segment.url.lastPathComponent)#\(entry.index)@\(deviceKey)" }
        public let segment: BiomeSegment
        public let entry: SEGBFile.Entry
        public let payload: Data
        public var timestamp: Date { entry.timestamp }
        public var device: BiomeDevice { segment.device }
        private var deviceKey: String { segment.device.identifier ?? "local" }
    }

    public let stream: BiomeStream
    public init(_ stream: BiomeStream) { self.stream = stream }

    /// Iterates live records across segments. Segments are opened one at a time (mmap) and
    /// released before the next one. Return `false` from `body` to stop.
    ///
    /// - Note: "newest first" is by segment and by position within a segment; records of
    ///   different devices are not interleaved by timestamp.
    public func forEach(
        device: BiomeDevice? = nil, order: SEGBFile.Order = .newestFirst, includeDeleted: Bool = false,
        _ body: (Record) -> Bool
    ) {
        var segments = stream.dataSegments(device: device)
        if order == .newestFirst { segments.reverse() }
        for segment in segments {
            if Task.isCancelled { return }
            guard let file = try? SEGBFile(url: segment.url) else { continue }
            for (entry, payload) in file.records(order: order, includeDeleted: includeDeleted) {
                if !body(Record(segment: segment, entry: entry, payload: payload)) { return }
            }
        }
    }

    /// Decodes every live record's payload as protobuf and passes it to `body`.
    public func forEachMessage(
        device: BiomeDevice? = nil, order: SEGBFile.Order = .newestFirst,
        _ body: (Record, ProtoMessage) -> Bool
    ) {
        forEach(device: device, order: order) { record in
            guard let message = ProtoMessage(record.payload) else { return true }
            return body(record, message)
        }
    }

    /// Aggregate statistics without decoding payloads.
    public struct Stats: Sendable, Hashable {
        public var segments = 0
        public var records = 0
        public var deleted = 0
        public var bytes: Int64 = 0
        public var timeRange: ClosedRange<Date>?
        public var versions: Set<Int> = []
    }

    public func stats(device: BiomeDevice? = nil) -> Stats {
        var stats = Stats()
        for segment in stream.dataSegments(device: device) {
            if Task.isCancelled { break }
            stats.bytes += segment.size
            guard let file = try? SEGBFile(url: segment.url) else { continue }
            stats.segments += 1
            stats.records += file.liveCount
            stats.deleted += file.deletedCount
            stats.versions.insert(file.version.rawValue)
            if let r = file.timeRange {
                if let existing = stats.timeRange {
                    stats.timeRange = min(existing.lowerBound, r.lowerBound)...max(existing.upperBound, r.upperBound)
                } else {
                    stats.timeRange = r
                }
            }
        }
        return stats
    }
}
