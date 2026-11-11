import Foundation
import DossierCore

/// Statistics of one stream on one device, computed from the SEGB indexes only (no payload
/// is read).
struct DeviceStats: Sendable, Hashable {
    let device: BiomeDevice
    var segments = 0
    var bytes: Int64 = 0
    var live = 0
    var deleted = 0
    var first: Date?
    var last: Date?
    /// Live records per local day (key: days since 2001-01-01 in the current time zone).
    var days: [Int: Int] = [:]

    var range: ClosedRange<Date>? {
        guard let first, let last else { return nil }
        return first...last
    }
}

/// One stream of the catalogue with its documentation and per-device statistics.
struct CatalogEntry: Identifiable, Sendable {
    var id: String { stream.id }
    let stream: BiomeStream
    let origin: BiomeStreamOrigin
    let info: BiomeStreamInfo
    let devices: [DeviceStats]

    /// Name shown in lists; linkd transcripts are named after their app directory.
    var displayName: String { origin == .linkd ? "ActionTranscript · " + stream.name : stream.name }
    /// linkd's combined `System` transcript: a byte-identical second copy of every record
    /// of the per-app transcripts.
    var isMirror: Bool { origin == .linkd && stream.name == BiomeStreamRegistry.linkdMirrorName }
    var live: Int { devices.reduce(0) { $0 + $1.live } }
    var deleted: Int { devices.reduce(0) { $0 + $1.deleted } }
    var bytes: Int64 { devices.reduce(0) { $0 + $1.bytes } }
    var range: ClosedRange<Date>? {
        let firsts = devices.compactMap(\.first), lasts = devices.compactMap(\.last)
        guard let lo = firsts.min(), let hi = lasts.max() else { return nil }
        return lo...hi
    }
    var days: [Int: Int] {
        var out: [Int: Int] = [:]
        for d in devices { for (k, v) in d.days { out[k, default: 0] += v } }
        return out
    }
}

/// Local-day arithmetic shared by the catalogue and the charts.
enum DayIndex {
    static var offset: TimeInterval { TimeInterval(TimeZone.current.secondsFromGMT()) }
    static func of(_ date: Date, offset: TimeInterval = DayIndex.offset) -> Int {
        Int(((date.timeIntervalSinceReferenceDate + offset) / 86_400).rounded(.down))
    }
    static func date(_ day: Int, offset: TimeInterval = DayIndex.offset) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(day) * 86_400 - offset)
    }
    static var today: Int { of(Date()) }
}

/// Device labels come from the shared `BiomeDeviceNamer` in DossierCore.
typealias DeviceNamer = BiomeDeviceNamer

extension BiomeDeviceNamer {
    func label(site: String) -> String { label(identifier: site) }
}

/// Everything the catalogue-based sections need, loaded once.
struct CatalogSnapshot: Sendable {
    let entries: [CatalogEntry]
    let peers: [String: BiomeDevicePeer]
    let namer: DeviceNamer
    let seconds: Double
    /// Distinct record payloads over all linkd transcripts (the combined `System` log and
    /// the per-app logs hold the same executions twice).
    let linkdDistinct: Int

    var nonEmpty: [CatalogEntry] { entries.filter { $0.live > 0 } }
    /// Records stored in linkd transcripts, duplicates included.
    var linkdStored: Int { entries.reduce(0) { $0 + ($1.origin == .linkd ? $1.live : 0) } }
    /// Live records, counting each App Intents execution of the linkd transcripts once.
    var totalLive: Int { entries.reduce(0) { $0 + $1.live } - linkdStored + linkdDistinct }
    /// Non-empty streams the unified timeline and content search use by default: owner
    /// activity, with each App Intents execution from one source only. The Biome stream
    /// `App.Intents.Transcript` records the same executions as linkd's transcripts, so
    /// those are left out unless the Biome stream is empty (and linkd's combined log
    /// always is, see `CatalogEntry.isMirror`).
    var activityEntries: [CatalogEntry] {
        let biomeTranscript = entries.contains { $0.origin == .biome && $0.stream.name == "App.Intents.Transcript" && $0.live > 0 }
        return entries.filter { $0.live > 0 && $0.info.isActivity && !(biomeTranscript && $0.origin == .linkd) }
    }
    var totalDeleted: Int { entries.reduce(0) { $0 + $1.deleted } }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    func entry(named name: String) -> CatalogEntry? {
        entries.first { $0.id == name } ?? entries.first { $0.origin == .biome && $0.stream.name == name } ?? entries.first { $0.stream.name == name || $0.displayName == name }
    }
}

/// Discovers all stream directories and indexes their segments. Cached until Refresh.
actor BiomeCatalog {
    static let shared = BiomeCatalog()

    private var token = Int.min
    private var cached: CatalogSnapshot?
    private var loading: Task<CatalogSnapshot, Never>?

    /// Invalidates the cache when the Refresh token changed.
    func sync(token: Int) {
        if token != self.token {
            self.token = token
            cached = nil
            loading = nil
        }
    }

    func snapshot() async -> CatalogSnapshot {
        if let cached { return cached }
        if let loading { return await loading.value }
        let task = Task.detached(priority: .userInitiated) { await BiomeCatalog.build() }
        loading = task
        let value = await task.value
        if loading == task {
            cached = value
            loading = nil
        }
        return value
    }

    private static func build() async -> CatalogSnapshot {
        let started = Date()
        let streams = Biome.discoverAllStreams()
        let peers = await Biome.devicePeers()
        let offset = DayIndex.offset

        var results = [CatalogEntry?](repeating: nil, count: streams.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let out = UncheckedBox(buffer)
            DispatchQueue.concurrentPerform(iterations: streams.count) { i in
                out.value[i] = index(streams[i], dayOffset: offset)
            }
        }
        // The same stream directory can be reachable from two roots; keep the first.
        var seen = Set<String>()
        let entries = results.compactMap { $0 }.filter { seen.insert($0.id).inserted }
            .sorted { a, b in
                if a.origin != b.origin { return order(a.origin) < order(b.origin) }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        var ids: [String] = []
        for e in entries { for d in e.devices { if let id = d.device.identifier { ids.append(id) } } }
        let namer = DeviceNamer(peers: peers, identifiers: ids, others: await syncSites())
        return CatalogSnapshot(entries: entries, peers: peers, namer: namer, seconds: Date().timeIntervalSince(started),
                               linkdDistinct: distinctPayloads(entries.filter { $0.origin == .linkd }))
    }

    /// Number of distinct live record payloads in the given streams (linkd transcripts are
    /// small: one archived action record per App Intent execution).
    static func distinctPayloads(_ entries: [CatalogEntry]) -> Int {
        struct Key: Hashable { let length: Int; let crc: UInt32; let hash: Int }
        var seen = Set<Key>()
        for entry in entries {
            for segment in entry.stream.dataSegments() {
                guard let file = try? SEGBFile(url: segment.url) else { continue }
                for e in file.entries where e.state.isLive {
                    let payload = file.payload(e)
                    seen.insert(Key(length: payload.count, crc: e.crc, hash: payload.hashValue))
                }
            }
        }
        return seen.count
    }

    /// Device identifiers that occur in sync.db bookkeeping (so labels are numbered the
    /// same way in every section).
    private static func syncSites() async -> [String] {
        guard let db = await SQLiteDB.sharedIfAvailable(Paths.biomeSyncDB), await db.hasColumns("CRDTLocation", ["site"]) else { return [] }
        return ((try? await db.rows("SELECT DISTINCT site FROM CRDTLocation")) ?? []).compactMap { $0[0].string }
    }

    private static func order(_ origin: BiomeStreamOrigin) -> Int {
        switch origin {
        case .biome: return 0
        case .linkd: return 1
        case .duetExpert: return 2
        case .other: return 3
        }
    }

    /// Indexes one stream. Returns nil for directories that contain files but no SEGB
    /// segment at all (other daemons' `local/` folders).
    private static func index(_ stream: BiomeStream, dayOffset: TimeInterval) -> CatalogEntry? {
        var byDevice: [BiomeDevice: DeviceStats] = [:]
        var order: [BiomeDevice] = []
        var files = 0, valid = 0
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        for segment in stream.dataSegments() {
            files += 1
            guard let file = try? SEGBFile(url: segment.url) else { continue }
            valid += 1
            if byDevice[segment.device] == nil { order.append(segment.device) }
            var stats = byDevice[segment.device] ?? DeviceStats(device: segment.device)
            stats.segments += 1
            stats.bytes += segment.size
            for e in file.entries {
                guard e.state.isLive else { stats.deleted += 1; continue }
                stats.live += 1
                guard e.timestamp > epoch else { continue }
                if stats.first.map({ e.timestamp < $0 }) ?? true { stats.first = e.timestamp }
                if stats.last.map({ e.timestamp > $0 }) ?? true { stats.last = e.timestamp }
                stats.days[DayIndex.of(e.timestamp, offset: dayOffset), default: 0] += 1
            }
            byDevice[segment.device] = stats
        }
        if files > 0 && valid == 0 { return nil }
        let origin = BiomeStreamOrigin.of(stream.url)
        if origin == .other && valid == 0 { return nil }
        let devices = order.sorted { a, b in
            if a.isLocal != b.isLocal { return a.isLocal }
            return (a.identifier ?? "") < (b.identifier ?? "")
        }.compactMap { byDevice[$0] }
        return CatalogEntry(stream: stream, origin: origin, info: BiomeStreamRegistry.info(for: stream.name, origin: origin), devices: devices)
    }
}

/// Lets a buffer pointer cross into `concurrentPerform` (each iteration writes its own slot).
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Records

/// Locates one record: segment file + index entry.
struct RecordRef: Sendable, Hashable {
    let segmentURL: URL
    let entryIndex: Int
    let streamID: String
}

/// A fully loaded record for the inspector.
struct LoadedRecord: Sendable {
    let payload: Data
    let timestamp: Date
    let state: String
    let crc: UInt32
    let crcOK: Bool
    let segmentCreated: Date?
    let version: Int
    let fields: [KeyValueItem]
    let nodes: [DataNode]

    static func load(_ ref: RecordRef, schema: BiomeStreamSchema?) throws -> LoadedRecord {
        let file: SEGBFile
        do { file = try SEGBFile(url: ref.segmentURL) } catch { throw DossierError.message("The segment could not be read: \(error.localizedDescription)") }
        guard ref.entryIndex < file.entries.count else { throw DossierError.message("The record no longer exists (the segment was rewritten).") }
        let entry = file.entries[ref.entryIndex]
        let payload = file.payload(entry)
        var items: [KeyValueItem] = []
        if let schema {
            for field in schema.fields {
                let values = RecordDecoder.values(field, in: payload, limit: 40)
                if case .app = field.kind, !values.isEmpty {
                    // Name first, the identifier it was resolved from right below.
                    let names = values.map(RecordDecoder.appName)
                    items.append(KeyValueItem(field.name, names.joined(separator: ", "), sensitivity: field.sensitivity, id: field.pathLabel + field.name))
                    if names != values {
                        items.append(KeyValueItem(field.name + " identifier", values.joined(separator: ", "), sensitivity: field.sensitivity, monospaced: true, id: field.pathLabel + field.name + "#id"))
                    }
                    continue
                }
                let text = values.joined(separator: field.kind.isLongText ? "\n" : ", ")
                if !text.isEmpty {
                    items.append(KeyValueItem(field.name, Format.oneLine(text, max: 1_200), sensitivity: field.sensitivity, id: field.pathLabel + field.name))
                }
            }
        }
        return LoadedRecord(
            payload: payload, timestamp: entry.timestamp, state: entry.state.label, crc: entry.crc,
            crcOK: file.crcMatches(entry), segmentCreated: file.created, version: file.version.rawValue,
            fields: items, nodes: RecordDecoder.tree(payload, schema: schema)
        )
    }
}

private extension BiomeFieldKind {
    var isLongText: Bool { if case .plist = self { return true } else { return false } }
}

/// One row of the typed record table.
struct StreamRow: Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let device: BiomeDevice
    let length: Int
    /// One string per schema column (or a single generic preview).
    let cells: [String]
    let ref: RecordRef
}

/// Pages through the records of one stream, newest first across all devices. Keeps the
/// memory-mapped segments and a 24-byte reference per matching record; payloads are read
/// only for the visible page.
actor StreamRecordSource {
    private struct Ref { let segment: Int32; let entry: Int32; let time: Double }

    let entry: CatalogEntry
    private var segments: [BiomeSegment] = []
    private var files: [SEGBFile?] = []
    private var opened = false
    private var cacheKey: String?
    private var cache: [Ref] = []

    init(entry: CatalogEntry) { self.entry = entry }

    private func open() {
        guard !opened else { return }
        opened = true
        segments = entry.stream.dataSegments()
        files = segments.map { try? SEGBFile(url: $0.url) }
    }

    private func refs(device: BiomeDevice?, search: String) -> [Ref] {
        open()
        let key = (device.map { $0.identifier ?? "local" } ?? "*") + "\u{1}" + search
        if key == cacheKey { return cache }
        let needle = ByteNeedle(search)
        var out: [Ref] = []
        for (si, segment) in segments.enumerated() {
            if Task.isCancelled { return [] }
            guard device == nil || segment.device == device, let file = files[si] else { continue }
            for e in file.entries where e.state.isLive {
                if !needle.isEmpty, !needle.matches(file.payload(e)) { continue }
                out.append(Ref(segment: Int32(si), entry: Int32(e.index), time: e.timestamp.timeIntervalSinceReferenceDate))
            }
        }
        out.sort { $0.time > $1.time }
        cacheKey = key
        cache = out
        return out
    }

    func count(device: BiomeDevice?, search: String) -> Int { refs(device: device, search: search).count }

    func page(device: BiomeDevice?, search: String, ascending: Bool, offset: Int, limit: Int) -> [StreamRow] {
        let all = refs(device: device, search: search)
        guard offset < all.count else { return [] }
        let upper = min(all.count, offset + limit)
        let columns = entry.info.schema?.columns
        var rows: [StreamRow] = []
        rows.reserveCapacity(upper - offset)
        for i in offset..<upper {
            let ref = ascending ? all[all.count - 1 - i] : all[i]
            let segment = segments[Int(ref.segment)]
            guard let file = files[Int(ref.segment)], Int(ref.entry) < file.entries.count else { continue }
            let e = file.entries[Int(ref.entry)]
            let payload = file.payload(e)
            let cells: [String]
            if let columns {
                // `.app` cells keep the bundle identifier; the column resolves name and icon.
                cells = columns.map { Format.oneLine(RecordDecoder.display($0, in: payload, raw: true), max: 300) }
            } else {
                cells = [RecordDecoder.genericPreview(payload, max: 300)]
            }
            rows.append(StreamRow(
                id: "\(segment.device.identifier ?? "local")/\(segment.url.lastPathComponent)#\(e.index)",
                timestamp: e.timestamp, device: segment.device, length: e.length, cells: cells,
                ref: RecordRef(segmentURL: segment.url, entryIndex: e.index, streamID: entry.id)
            ))
        }
        return rows
    }
}
