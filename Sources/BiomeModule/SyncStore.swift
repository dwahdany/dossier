import Foundation
import DossierCore

/// Contents of `~/Library/Biome/sync/sync.db`, the bookkeeping database of Biome's
/// device-to-device sync.
///
/// Verified layout: `DevicePeer` (known devices; `me` marks this Mac, `platform` 2 = iOS
/// device, 3 = Mac, `model` is an OS build), `CRDTLocation` (one row per synced stream ×
/// originating device ("site") × day — the unit that is replicated; `day` is Cocoa seconds
/// at midnight UTC), `CKAtom` (one row per replicated event: a logical clock per site and
/// a bookmark `segment_name` / `segment_offset` into the SEGB file holding the payload),
/// `AtomMergedLog` (events merged in, with relay device and creation time),
/// `SyncSessionLog` / `SyncMessageLog` (sessions and messages exchanged) and `CKRecord`
/// (CloudKit mirror records). Sync stream identifiers are short names or UUIDs; they are
/// resolved to stream directories by matching `segment_name` against real segment files.
struct SyncOverview: Sendable {
    struct Peer: Identifiable, Sendable {
        let id: String
        let label: String
        let platform: String
        let build: String
        let isMe: Bool
        /// Listed in DevicePeer (as opposed to a site that only survives in old day markers).
        let isPeer: Bool
        let lastSync: Date?
        let protocolVersion: Int?
        let locations: Int
        let atoms: Int
    }

    struct Location: Identifiable, Sendable {
        let id: String
        let syncStream: String
        let resolvedStream: String?
        let site: String
        let device: String
        let days: Int
        let firstDay: Date?
        let lastDay: Date?
        let states: String
        let atoms: Int
        let deletions: Int
    }

    struct Session: Identifiable, Sendable {
        let id: Int
        let start: Date?
        let duration: Double?
        let transport: Int?
        let reason: Int?
        let reciprocal: Bool
        let sincePrevious: Double?
        let messages: Int
        let bytes: Int
    }

    var peers: [Peer] = []
    var locations: [Location] = []
    var sessions: [Session] = []
    /// CRDT day markers per calendar day and device.
    var markerDays: [ChartPoint] = []
    /// Events merged from other devices per day (by event creation time).
    var mergedDays: [ChartPoint] = []
    var mergedUnit: Calendar.Component = .day
    var mergedTotal = 0
    var atomTotal = 0
    var locationTotal = 0
    var cloudRecords = 0
    var zones: [String] = []
    var lastSync: Date?
    var lastCloudSync: Date?
    var lastAttempt: Date?
    var streamCount = 0
}

enum SyncStore {
    static var url: URL { Paths.biomeSyncDB }

    /// sync.db mixes epochs: `DevicePeer.last_sync_date` holds Unix seconds while every
    /// other timestamp is Cocoa seconds. Values beyond 1.2e9 are taken as Unix time.
    static func flexibleDate(_ value: Double) -> Date? { DossierDate.cocoaOrUnix(value) }

    static func load(catalog: CatalogSnapshot) async throws -> SyncOverview {
        switch Paths.probe(url) {
        case .missing: throw DossierError.missing("Biome's sync database does not exist — this Mac does not sync Biome streams with other devices.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        let db: SQLiteDB
        do { db = try await SQLiteDB.shared(url) } catch { throw DossierError.inaccessible(error.localizedDescription) }
        let hasPeerTable = await db.tableExists("DevicePeer")
        let hasLocationTable = await db.tableExists("CRDTLocation")
        guard hasPeerTable || hasLocationTable else {
            throw DossierError.missing("sync.db has an unknown layout on this macOS version.")
        }
        var out = SyncOverview()

        let hasLocations = await db.hasColumns("CRDTLocation", ["stream", "site", "day", "state"])
        var peers = catalog.peers
        if peers.isEmpty { peers = await Biome.devicePeers() }
        let namer = catalog.namer

        // Atoms per stream × site (covered by the unique index on stream, site, …).
        var atoms: [String: (count: Int, deletions: Int)] = [:]
        var atomsPerSite: [String: Int] = [:]
        let hasAtoms = await db.hasColumns("CKAtom", ["stream", "site", "type"])
        if hasAtoms {
            for row in (try? await db.rows("SELECT stream, CAST(site AS TEXT), type, count(*) FROM CKAtom GROUP BY 1, 2, 3")) ?? [] {
                guard let stream = row[0].string, let site = row[1].string else { continue }
                let n = Int(row[3].int ?? 0)
                var entry = atoms[stream + "|" + site] ?? (0, 0)
                entry.count += n
                if (row[2].int ?? 0) != 0 { entry.deletions += n }
                atoms[stream + "|" + site] = entry
                atomsPerSite[site, default: 0] += n
                out.atomTotal += n
            }
        }

        // Resolve sync stream identifiers through segment bookmarks.
        var resolved: [String: String] = [:]
        if hasAtoms, await db.hasColumns("CKAtom", ["segment_name"]) {
            var segmentOwners: [String: [String]] = [:]     // "<deviceKey>/<segment file>" → stream names
            for entry in catalog.entries where entry.origin == .biome {
                for segment in entry.stream.segments where !segment.isTombstone {
                    let key = (segment.device.identifier ?? "local") + "/" + segment.url.lastPathComponent
                    segmentOwners[key, default: []].append(entry.stream.name)
                }
            }
            var votes: [String: [String: Int]] = [:]
            let rows = (try? await db.rows("SELECT DISTINCT stream, CAST(site AS TEXT), segment_name FROM CKAtom WHERE segment_name IS NOT NULL", [], maxRows: 50_000)) ?? []
            for row in rows {
                guard let stream = row[0].string, let site = row[1].string, let segment = row[2].string ?? row[2].int.map(String.init) else { continue }
                let deviceKey = site == namer.localIdentifier ? "local" : site
                for owner in segmentOwners[deviceKey + "/" + segment] ?? [] {
                    votes[stream, default: [:]][owner, default: 0] += 1
                }
            }
            for (stream, candidates) in votes {
                if let best = candidates.max(by: { $0.value < $1.value }) { resolved[stream] = best.key }
            }
        }

        if hasLocations {
            let rows = (try? await db.rows("""
                SELECT stream, site, count(*), min(day), max(day), group_concat(DISTINCT state) FROM CRDTLocation
                GROUP BY stream, site ORDER BY count(*) DESC
                """)) ?? []
            var perSite: [String: Int] = [:]
            for row in rows {
                guard let stream = row[0].string, let site = row[1].string else { continue }
                let n = Int(row[2].int ?? 0)
                perSite[site, default: 0] += n
                out.locationTotal += n
                let a = atoms[stream + "|" + site]
                out.locations.append(SyncOverview.Location(
                    id: stream + "|" + site, syncStream: stream, resolvedStream: resolved[stream], site: site,
                    device: namer.label(site: site), days: n, firstDay: row[3].cocoaDate, lastDay: row[4].cocoaDate,
                    states: (row[5].string ?? "").split(separator: ",").sorted().joined(separator: ", "),
                    atoms: a?.count ?? 0, deletions: a?.deletions ?? 0
                ))
            }
            out.streamCount = Set(out.locations.map(\.syncStream)).count
            // Day markers per device.
            let days = (try? await db.rows("SELECT day, site, count(*) FROM CRDTLocation GROUP BY day, site ORDER BY day")) ?? []
            let cutoff = Date().addingTimeInterval(-120 * 86_400)
            out.markerDays = days.compactMap { row in
                guard let date = row[0].cocoaDate, date >= cutoff, let site = row[1].string else { return nil }
                return ChartPoint(date, Double(row[2].int ?? 0), series: namer.label(site: site))
            }
            for (id, peer) in peers {
                out.peers.append(SyncOverview.Peer(
                    id: id, label: namer.label(site: id), platform: peer.platformName, build: peer.model ?? "",
                    isMe: peer.isMe, isPeer: true, lastSync: nil, protocolVersion: nil, locations: perSite[id] ?? 0, atoms: atomsPerSite[id] ?? 0
                ))
            }
            for site in perSite.keys where peers[site] == nil {
                out.peers.append(SyncOverview.Peer(
                    id: site, label: namer.label(site: site), platform: "Former device", build: "", isMe: false, isPeer: false,
                    lastSync: nil, protocolVersion: nil, locations: perSite[site] ?? 0, atoms: atomsPerSite[site] ?? 0
                ))
            }
        }

        // Peer details (last sync, protocol version).
        if await db.hasColumns("DevicePeer", ["device_identifier"]) {
            let cols = await db.columnNames(of: "DevicePeer")
            let rows = (try? await db.rows("SELECT * FROM DevicePeer")) ?? []
            var details: [String: (Date?, Int?)] = [:]
            for row in rows {
                guard let id = row["device_identifier"].string else { continue }
                details[id] = (cols.contains("last_sync_date") ? row["last_sync_date"].double.flatMap(SyncStore.flexibleDate) : nil,
                               cols.contains("protocol_version") ? row["protocol_version"].int.map(Int.init) : nil)
            }
            if out.peers.isEmpty {
                for (id, peer) in peers {
                    out.peers.append(SyncOverview.Peer(id: id, label: namer.label(site: id), platform: peer.platformName, build: peer.model ?? "", isMe: peer.isMe, isPeer: true, lastSync: nil, protocolVersion: nil, locations: 0, atoms: 0))
                }
            }
            out.peers = out.peers.map { p in
                let d = details[p.id]
                return SyncOverview.Peer(id: p.id, label: p.label, platform: p.platform, build: p.build, isMe: p.isMe, isPeer: p.isPeer,
                                         lastSync: d?.0, protocolVersion: d?.1, locations: p.locations, atoms: p.atoms)
            }
        }
        out.peers.sort { a, b in
            if a.isMe != b.isMe { return a.isMe }
            if a.isPeer != b.isPeer { return a.isPeer }
            return a.locations > b.locations
        }

        // Merge log.
        if await db.hasColumns("AtomMergedLog", ["stream", "event_created_at", "owning_site_identifier"]) {
            out.mergedTotal = await db.rowCount(of: "AtomMergedLog") ?? 0
            // Per day; per hour when the log only spans a few days.
            let span = try? await db.first("SELECT min(event_created_at), max(event_created_at) FROM AtomMergedLog WHERE event_created_at > 0")
            let seconds = (span?[1].double ?? 0) - (span?[0].double ?? 0)
            let bucket = seconds < 4 * 86_400 ? 3_600 : 86_400
            out.mergedUnit = bucket == 3_600 ? .hour : .day
            let rows = (try? await db.rows("""
                SELECT CAST((event_created_at + 978307200) / \(bucket) AS INTEGER), owning_site_identifier, count(*)
                FROM AtomMergedLog WHERE event_created_at > 0 GROUP BY 1, 2 ORDER BY 1
                """)) ?? []
            out.mergedDays = rows.compactMap { row in
                guard let slot = row[0].int, let site = row[1].string else { return nil }
                return ChartPoint(Date(timeIntervalSince1970: Double(slot) * Double(bucket)), Double(row[2].int ?? 0), series: namer.label(site: site))
            }
        }

        // Sessions with their messages.
        if await db.hasColumns("SyncSessionLog", ["session_id", "start_timestamp", "end_timestamp"]) {
            var messages: [Data: (Int, Int)] = [:]
            if await db.hasColumns("SyncMessageLog", ["session_id", "atom_batch_bytes"]) {
                for row in (try? await db.rows("SELECT CAST(session_id AS BLOB), count(*), sum(atom_batch_bytes) FROM SyncMessageLog GROUP BY 1")) ?? [] {
                    if let id = row[0].data { messages[id] = (Int(row[1].int ?? 0), Int(row[2].int ?? 0)) }
                }
            }
            let cols = await db.columnNames(of: "SyncSessionLog")
            func col(_ name: String) -> String { cols.contains(name) ? name : "NULL" }
            let rows = (try? await db.rows("""
                SELECT CAST(session_id AS BLOB), start_timestamp, end_timestamp, \(col("transport")), \(col("reason")), \(col("is_reciprocal")), \(col("time_since_previous_sync"))
                FROM SyncSessionLog ORDER BY start_timestamp DESC LIMIT 500
                """)) ?? []
            for (i, row) in rows.enumerated() {
                let m = row[0].data.flatMap { messages[$0] }
                let start = row[1].cocoaDate
                let duration: Double? = {
                    guard let s = row[1].double, let e = row[2].double, e >= s else { return nil }
                    return e - s
                }()
                out.sessions.append(SyncOverview.Session(
                    id: i, start: start, duration: duration, transport: row[3].int.map(Int.init), reason: row[4].int.map(Int.init),
                    reciprocal: row[5].bool ?? false, sincePrevious: row[6].double, messages: m?.0 ?? 0, bytes: m?.1 ?? 0
                ))
            }
        }

        if await db.tableExists("CKRecord") { out.cloudRecords = await db.rowCount(of: "CKRecord") ?? 0 }
        if await db.hasColumns("CKZone", ["zone_name"]) {
            out.zones = ((try? await db.rows("SELECT zone_name FROM CKZone")) ?? []).compactMap { $0[0].string }
        }
        if await db.hasColumns("Metadata", ["key", "value"]) {
            for row in (try? await db.rows("SELECT key, value FROM Metadata WHERE key IN ('LastSyncDate', 'LastCloudKitSyncDate', 'LastSyncAttemptDate')")) ?? [] {
                switch row[0].string {
                case "LastSyncDate": out.lastSync = row[1].cocoaDate
                case "LastCloudKitSyncDate": out.lastCloudSync = row[1].cocoaDate
                case "LastSyncAttemptDate": out.lastAttempt = row[1].cocoaDate
                default: break
                }
            }
        }
        return out
    }
}
