import Foundation
import DossierCore

/// A device taking part in Biome sync (`sync.db` → `DevicePeer`) and / or owning a
/// `remote/<device>` directory in some stream.
struct SyncPeer: Identifiable, Sendable {
    let id: String
    var label: String
    var platform: String
    var build: String
    var isMe: Bool
    var listed: Bool
    var lastSync: Date?
    var protocolVersion: Int?
    var streams: Int
    var segments: Int
    var bytes: Int64
    var newestData: Date?
    var crdtStreams: Int
    var mergedAtoms: Int
}

/// What one device contributes to one stream.
struct StreamShare: Identifiable, Sendable {
    let id: String
    let stream: String
    let device: String
    let deviceID: String
    let segments: Int
    let bytes: Int64
    let newest: Date?
}

struct SyncSession: Identifiable, Sendable {
    let id: String
    let start: Date
    let end: Date?
    let transport: Int?
    let reason: Int?
    let reciprocal: Bool
    let sincePrevious: TimeInterval?
}

struct MergedStream: Identifiable, Sendable {
    let id: String
    let stream: String
    let device: String
    let atoms: Int
    let first: Date?
    let last: Date?
}

struct RouteTarget: Identifiable, Sendable {
    let id: Int64
    let name: String
    let model: String
    let type: String
    let firstSeen: Date?
    let lastSeen: Date?
    let lastUsed: Date?
    let overInfrastructure: Bool
}

struct DevicesData: Sendable {
    var peers: [SyncPeer] = []
    var shares: [StreamShare] = []
    var sessions: [SyncSession] = []
    var merged: [MergedStream] = []
    var targets: [RouteTarget] = []
    var routingStats: [KV] = []
    var knowledgePeers: [KnowledgePeer] = []
    var identities: [MiloBluetoothIdentity] = []
    var syncAvailability: Availability = .missing
    var routingAvailability: Availability = .missing
    var lastSync: Date?
    var crdtLocations = 0
}

enum DevicesLoader {
    static func load(token: Int) async throws -> DevicesData {
        await EnvCache.shared.sync(token: token)
        return try await EnvCache.shared.value("devices") { await build() }
    }

    /// `sync.db` stores some timestamps as Unix and some as Cocoa seconds.
    static func flexibleDate(_ value: SQLValue) -> Date? { DossierDate.cocoaOrUnix(value.double) }

    static func platformName(_ code: Int?) -> String { BiomeDevicePeer.platformName(code) }

    private static let routingStatLabels = [
        "ZNUMBEROFCONTEXTCHANGES": "Context changes",
        "ZNUMBEROFMILOPREDICTIONS": "Microlocation predictions",
        "ZNUMBEROFMILOPREDICTIONSINUPDATESMODE": "Predictions while learning",
        "ZNUMBEROFPICKERCHOICEEVENTS": "Route picker choices",
        "ZNUMBEROFCORRECTPICKERCHOICEEVENTS": "Correctly predicted choices",
        "ZTIMEINUPDATESMODEINSECONDS": "Seconds spent learning",
    ]

    private static func build() async -> DevicesData {
        var data = DevicesData()
        data.syncAvailability = Paths.probe(Paths.biomeSyncDB)
        var peers: [String: SyncPeer] = [:]
        // One label per device for the whole module (and the same wording as Activity /
        // Biome): never any part of the identifier.
        let namer = await DeviceNamer.load()

        func peer(_ id: String) -> SyncPeer {
            peers[id] ?? SyncPeer(
                id: id, label: namer.name(identifier: id), platform: namer.unlistedPlatform[id] ?? "Unknown", build: "", isMe: false, listed: false,
                lastSync: nil, protocolVersion: nil, streams: 0, segments: 0, bytes: 0, newestData: nil, crdtStreams: 0, mergedAtoms: 0)
        }

        let sync = await SQLiteDB.sharedIfAvailable(Paths.biomeSyncDB)
        if let db = sync, await db.hasColumns("DevicePeer", ["device_identifier"]) {
            let cols = await db.columnNames(of: "DevicePeer")
            func col(_ name: String) -> String { cols.contains(name) ? name : "NULL" }
            let sql = "SELECT device_identifier, \(col("me")), \(col("name")), \(col("model")), \(col("platform")), \(col("last_sync_date")), \(col("protocol_version")) FROM DevicePeer LIMIT 500"
            for row in (try? await db.rows(sql)) ?? [] {
                guard let id = row[0].string else { continue }
                let isMe = row[1].bool ?? false
                let platform = namer.refine(platformName(row[4].int.map(Int.init)))
                var p = peer(id)
                p.platform = platform
                p.build = row[3].string ?? ""
                p.isMe = isMe
                p.listed = true
                p.label = isMe ? "This Mac" : namer.name(identifier: id)
                p.lastSync = flexibleDate(row[5])
                p.protocolVersion = row[6].int.map(Int.init)
                peers[id] = p
            }
        }

        // Which streams hold data that arrived from which device.
        for stream in Biome.discoverStreams(under: Paths.biomeRestrictedStreams, maxDepth: 2) {
            var perDevice: [String: (segments: Int, bytes: Int64, newest: Date?)] = [:]
            for segment in stream.dataSegments() {
                guard let id = segment.device.identifier else { continue }
                var entry = perDevice[id] ?? (0, 0, nil)
                entry.segments += 1
                entry.bytes += segment.size
                if let m = segment.modified { entry.newest = max(entry.newest ?? m, m) }
                perDevice[id] = entry
            }
            for (id, entry) in perDevice {
                var p = peer(id)
                p.streams += 1
                p.segments += entry.segments
                p.bytes += entry.bytes
                if let n = entry.newest { p.newestData = max(p.newestData ?? n, n) }
                peers[id] = p
                data.shares.append(StreamShare(
                    id: stream.name + "|" + id, stream: stream.name, device: p.label, deviceID: id,
                    segments: entry.segments, bytes: entry.bytes, newest: entry.newest))
            }
        }
        data.shares.sort { $0.bytes > $1.bytes }

        if let db = sync {
            if await db.hasColumns("CRDTLocation", ["stream", "site"]) {
                data.crdtLocations = await db.rowCount(of: "CRDTLocation") ?? 0
                for row in (try? await db.rows("SELECT site, count(DISTINCT stream) FROM CRDTLocation GROUP BY site LIMIT 1000")) ?? [] {
                    guard let id = row[0].string else { continue }
                    var p = peer(id)
                    if !p.listed, p.streams == 0 { p.platform = "Former sync site" }
                    p.crdtStreams = Int(row[1].int ?? 0)
                    peers[id] = p
                }
            }
            if await db.hasColumns("AtomMergedLog", ["stream", "owning_site_identifier", "synced_at"]) {
                let sql = "SELECT stream, owning_site_identifier, count(*), min(synced_at), max(synced_at) FROM AtomMergedLog GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 2000"
                for row in (try? await db.rows(sql)) ?? [] {
                    let id = row[1].string ?? ""
                    let count = Int(row[2].int ?? 0)
                    var p = peer(id)
                    p.mergedAtoms += count
                    if !id.isEmpty { peers[id] = p }
                    data.merged.append(MergedStream(
                        id: (row[0].string ?? "") + "|" + id, stream: row[0].string ?? "", device: id.isEmpty ? "Unknown device" : p.label,
                        atoms: count, first: flexibleDate(row[3]), last: flexibleDate(row[4])))
                }
            }
            if await db.hasColumns("SyncSessionLog", ["session_id", "start_timestamp"]) {
                let cols = await db.columnNames(of: "SyncSessionLog")
                func col(_ name: String) -> String { cols.contains(name) ? name : "NULL" }
                let sql = "SELECT rowid, start_timestamp, \(col("end_timestamp")), \(col("transport")), \(col("reason")), \(col("is_reciprocal")), \(col("time_since_previous_sync")) FROM SyncSessionLog ORDER BY start_timestamp DESC LIMIT 5000"
                for row in (try? await db.rows(sql)) ?? [] {
                    guard let start = flexibleDate(row[1]) else { continue }
                    data.sessions.append(SyncSession(
                        id: "s\(row[0].int ?? 0)", start: start, end: flexibleDate(row[2]), transport: row[3].int.map(Int.init),
                        reason: row[4].int.map(Int.init), reciprocal: row[5].bool ?? false, sincePrevious: row[6].double))
                }
            }
            if await db.tableExists("Metadata"), let v = try? await db.scalar("SELECT value FROM Metadata WHERE key = 'LastSyncDate'") {
                data.lastSync = flexibleDate(v)
            }
        }
        data.peers = peers.values.sorted { a, b in
            if a.isMe != b.isMe { return a.isMe }
            if a.listed != b.listed { return a.listed }
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }

        // intelligentroutingd: AirPlay / media route candidates.
        data.routingAvailability = Paths.probe(EnvPaths.routingDB)
        if let db = await SQLiteDB.sharedIfAvailable(EnvPaths.routingDB) {
            if await db.hasColumns("ZIRAVOUTPUTDEVICEMO", ["ZDEVICENAME", "ZMODELID", "ZNODE"]) {
                let hasNodes = await db.hasColumns("ZIRNODEMO", ["ZCANDIDATE"])
                let hasDates = await db.hasColumns("ZIRCANDIDATEMO", ["ZFIRSTSEENDATE", "ZLASTSEENDATE", "ZLASTUSEDDATE"])
                let hasCandidates = hasNodes && hasDates
                let cols = await db.columnNames(of: "ZIRAVOUTPUTDEVICEMO")
                func col(_ name: String) -> String { cols.contains(name) ? "d.\(name)" : "NULL" }
                let sql = hasCandidates
                    ? "SELECT d.Z_PK, d.ZDEVICENAME, d.ZMODELID, \(col("ZDEVICETYPE")), \(col("ZDEVICESUBTYPE")), \(col("ZDISCOVEREDOVERINFRA")), c.ZFIRSTSEENDATE, c.ZLASTSEENDATE, c.ZLASTUSEDDATE FROM ZIRAVOUTPUTDEVICEMO d LEFT JOIN ZIRNODEMO n ON n.Z_PK = d.ZNODE LEFT JOIN ZIRCANDIDATEMO c ON c.Z_PK = n.ZCANDIDATE LIMIT 1000"
                    : "SELECT d.Z_PK, d.ZDEVICENAME, d.ZMODELID, \(col("ZDEVICETYPE")), \(col("ZDEVICESUBTYPE")), \(col("ZDISCOVEREDOVERINFRA")), NULL, NULL, NULL FROM ZIRAVOUTPUTDEVICEMO d LIMIT 1000"
                for row in (try? await db.rows(sql)) ?? [] {
                    guard let pk = row[0].int else { continue }
                    data.targets.append(RouteTarget(
                        id: pk, name: row[1].string ?? "Unnamed target", model: row[2].string ?? "",
                        type: "type \(row[3].int ?? 0) / subtype \(row[4].int ?? 0)", firstSeen: row[6].cocoaDate, lastSeen: row[7].cocoaDate,
                        lastUsed: row[8].cocoaDate, overInfrastructure: row[5].bool ?? false))
                }
                data.targets.sort { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            }
            if await db.tableExists("ZIRSTATISTICSMO"), let row = try? await db.first("SELECT * FROM ZIRSTATISTICSMO LIMIT 1") {
                for (i, name) in row.columns.names.enumerated() where name.hasPrefix("ZNUMBEROF") || name.hasPrefix("ZTIMEIN") {
                    data.routingStats.append(KV(routingStatLabels[name] ?? String(name.dropFirst()), String(row[i].int ?? 0)))
                }
            }
        }
        data.knowledgePeers = await KnowledgeSource.peers()
        data.identities = await MiloSource.load().identities
        return data
    }
}
