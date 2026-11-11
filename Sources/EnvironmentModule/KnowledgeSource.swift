import Foundation
import DossierCore

/// A Maps / Find My interaction from knowledgeC `/app/intents`.
struct MapsIntent: Sendable {
    let pk: Int64
    let date: Date
    let bundle: String
    let verb: String
    let intentClass: String
    let device: String
    /// Generic-intent parameters (`Name`, `Street`, `City`, `element`, …).
    let params: [KV]

    func value(_ key: String) -> String? { params.first { $0.key == key }?.value }

    var placeName: String? { value("Name") ?? value("title") }

    var address: String {
        var lines: [String] = []
        if let street = value("Street") ?? [value("Thoroughfare"), value("SubThoroughfare")].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
            lines.append(street)
        }
        let city = [value("ZIP"), value("City")].compactMap { $0 }.joined(separator: " ")
        if !city.isEmpty { lines.append(city) }
        if let country = value("Country") { lines.append(country) }
        return lines.joined(separator: ", ")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A Bluetooth connection interval recorded by CoreDuet.
struct KnowledgeBluetoothSession: Sendable {
    let pk: Int64
    let start: Date
    let end: Date
    let name: String
    let address: String
    let deviceType: Int?
    let productID: Int?
    let isAppleAudio: Bool
    let host: String
}

/// A device known to CoreDuet's sync layer (`ZSYNCPEER`).
struct KnowledgePeer: Identifiable, Sendable {
    let id: Int64
    let model: String
    let version: String
    let lastSeen: Date?
    let hasCloudID: Bool
    let hasRapportID: Bool
    var events: Int
    var streams: [String]
}

enum KnowledgeSource {
    static func db() async -> SQLiteDB? {
        guard let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC), await db.tableExists("ZOBJECT") else { return nil }
        return db
    }

    /// Maps device identifiers (`ZSOURCE.ZDEVICEID`) to hardware models from `ZSYNCPEER`.
    static func deviceModels(_ db: SQLiteDB) async -> [String: String] {
        guard await db.hasColumns("ZSYNCPEER", ["ZDEVICEID", "ZMODEL"]) else { return [:] }
        var out: [String: String] = [:]
        for row in (try? await db.rows("SELECT ZDEVICEID, ZMODEL FROM ZSYNCPEER WHERE ZDEVICEID IS NOT NULL AND ZMODEL IS NOT NULL", maxRows: 2_000)) ?? [] {
            if let id = row[0].string, let model = row[1].string, !model.isEmpty { out[id] = model }
        }
        return out
    }

    /// Labels for every device identifier in `ZSOURCE`: the hardware model where
    /// `ZSYNCPEER` knows it, otherwise a numbered placeholder (never part of the identifier).
    static func deviceLabels(_ db: SQLiteDB) async -> [String: String] {
        var out = await deviceModels(db)
        guard await db.hasColumns("ZSOURCE", ["ZDEVICEID"]) else { return out }
        let ids = ((try? await db.rows("SELECT DISTINCT ZDEVICEID FROM ZSOURCE WHERE ZDEVICEID IS NOT NULL", maxRows: 5_000)) ?? []).compactMap { $0[0].string }
        let unknown = ids.filter { !$0.isEmpty && out[$0] == nil }.sorted()
        for (i, id) in unknown.enumerated() {
            out[id] = unknown.count == 1 ? "Unlisted synced device" : "Unlisted synced device \(i + 1)"
        }
        return out
    }

    static func deviceLabel(_ id: String?, _ labels: [String: String]) -> String {
        guard let id, !id.isEmpty else { return "This Mac" }
        return labels[id] ?? "Unlisted synced device"
    }

    // MARK: Maps intents

    static func mapsIntents(limit: Int = 5_000) async -> [MapsIntent] {
        guard let db = await db(),
              await db.hasColumns("ZSTRUCTUREDMETADATA", ["Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION", "Z_DKINTENTMETADATAKEY__INTENTVERB", "Z_DKINTENTMETADATAKEY__INTENTCLASS"]),
              await db.hasColumns("ZSOURCE", ["ZBUNDLEID", "ZDEVICEID"]) else { return [] }
        let models = await deviceLabels(db)
        let sql = """
            SELECT o.Z_PK, o.ZSTARTDATE, s.ZBUNDLEID, s.ZDEVICEID, m.Z_DKINTENTMETADATAKEY__INTENTVERB,
                   m.Z_DKINTENTMETADATAKEY__INTENTCLASS, m.Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION
            FROM ZOBJECT o
            LEFT JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE
            LEFT JOIN ZSTRUCTUREDMETADATA m ON m.Z_PK = o.ZSTRUCTUREDMETADATA
            WHERE o.ZSTREAMNAME = '/app/intents'
              AND (o.ZVALUESTRING = 'Maps' OR s.ZBUNDLEID IN ('com.apple.Maps', 'com.apple.findmy'))
            ORDER BY o.ZSTARTDATE DESC LIMIT ?
            """
        var out: [MapsIntent] = []
        for row in (try? await db.rows(sql, [.integer(Int64(limit))])) ?? [] {
            guard let pk = row[0].int, let date = row[1].cocoaDate else { continue }
            let params = row[6].data.map(genericIntentParameters) ?? []
            out.append(MapsIntent(
                pk: pk, date: date, bundle: row[2].string ?? "", verb: row[4].string ?? "", intentClass: row[5].string ?? "",
                device: deviceLabel(row[3].string, models), params: params))
        }
        return out
    }

    static func mapsActions() async -> [ActionRow] {
        await mapsIntents().map { intent in
            let element = intent.value("element")
            var title: String
            if let name = intent.placeName {
                title = name
            } else if !intent.verb.isEmpty {
                title = EnvFormat.humanize(intent.verb)
            } else {
                title = EnvFormat.humanize(intent.intentClass)
            }
            if let element, intent.placeName == nil { title += " (" + element.replacingOccurrences(of: "_", with: " ").lowercased() + ")" }
            var params = [KV("App", intent.bundle), KV("Verb", intent.verb), KV("Intent class", intent.intentClass)]
            params.append(contentsOf: intent.params)
            let detail = [element.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }, intent.address.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
            return ActionRow(
                id: "kc|\(intent.pk)", date: intent.date, kind: .maps, app: intent.bundle, title: title, detail: detail,
                device: intent.device, store: "knowledgeC /app/intents", params: params, ref: .knowledgeIntent(pk: intent.pk))
        }
    }

    /// Finds the `_INPBGenericIntent` protobuf inside a serialized `INInteraction` (an
    /// NSKeyedArchiver graph, itself wrapped in archived data) and returns its parameters.
    ///
    /// Protobuf layout: 2 = domain, 4 (repeated) = { 1 = name, 2 = { 1 = type,
    /// 2 = { 2 = string } | 3 = { 2 = double } } }.
    static func genericIntentParameters(_ blob: Data) -> [KV] {
        var result: [KV] = []
        var budget = 64

        func scan(_ data: Data) {
            guard budget > 0, result.isEmpty else { return }
            budget -= 1
            if PlistDecoder.isBinaryPlist(data) {
                guard let archive = KeyedArchive(data) else { return }
                for object in archive.objects {
                    if let d = object.data { scan(d) } else if let d = object["NS.data"]?.data ?? object["bytes"]?.data { scan(d) }
                    if !result.isEmpty { return }
                }
                return
            }
            guard let msg = ProtoMessage(data) else { return }
            var found: [KV] = []
            for field in msg.all(4) {
                guard let entry = field.message, let name = entry[1]?.string, let value = entry[2]?.message else { continue }
                if let s = value[2]?.message?[2]?.string {
                    if !s.isEmpty { found.append(KV(name, s)) }
                } else if let d = value[3]?.message?[2]?.double {
                    found.append(KV(name, Format.number(d, maxDigits: 6)))
                }
            }
            if !found.isEmpty { result = found }
        }
        scan(blob)
        return result
    }

    // MARK: Bluetooth

    /// `/bluetooth/isConnected` is a state stream: rows alternate between value 1
    /// (connected from start to end) and value 0 (NOT connected during that interval).
    /// Only the value-1 rows are connection sessions; the others are just counted.
    static func bluetoothSessions(limit: Int = 50_000) async -> (connected: [KnowledgeBluetoothSession], notConnected: Int) {
        guard let db = await db(),
              await db.hasColumns("ZSTRUCTUREDMETADATA", ["Z_DKBLUETOOTHMETADATAKEY__ADDRESS", "Z_DKBLUETOOTHMETADATAKEY__NAME"]) else { return ([], 0) }
        let hasState = await db.hasColumns("ZOBJECT", ["ZVALUEINTEGER"])
        let connectedOnly = hasState ? "AND coalesce(o.ZVALUEINTEGER, 1) != 0" : ""
        var notConnected = 0
        if hasState, let n = try? await db.scalar("SELECT count(*) FROM ZOBJECT WHERE ZSTREAMNAME = '/bluetooth/isConnected' AND ZVALUEINTEGER = 0") {
            notConnected = Int(n.int ?? 0)
        }
        let cols = await db.columnSet(of: "ZSTRUCTUREDMETADATA")
        func col(_ name: String) -> String { cols.contains(name) ? "m.\(name)" : "NULL" }
        let models = await deviceLabels(db)
        let sql = """
            SELECT o.Z_PK, o.ZSTARTDATE, o.ZENDDATE, m.Z_DKBLUETOOTHMETADATAKEY__NAME, m.Z_DKBLUETOOTHMETADATAKEY__ADDRESS,
                   \(col("Z_DKBLUETOOTHMETADATAKEY__DEVICETYPE")), \(col("Z_DKBLUETOOTHMETADATAKEY__PRODUCTID")),
                   \(col("Z_DKBLUETOOTHMETADATAKEY__ISAPPLEAUDIODEVICE")), s.ZDEVICEID
            FROM ZOBJECT o
            LEFT JOIN ZSTRUCTUREDMETADATA m ON m.Z_PK = o.ZSTRUCTUREDMETADATA
            LEFT JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE
            WHERE o.ZSTREAMNAME = '/bluetooth/isConnected' \(connectedOnly)
            ORDER BY o.ZSTARTDATE DESC LIMIT ?
            """
        var out: [KnowledgeBluetoothSession] = []
        for row in (try? await db.rows(sql, [.integer(Int64(limit))])) ?? [] {
            guard let pk = row[0].int, let start = row[1].cocoaDate else { continue }
            out.append(KnowledgeBluetoothSession(
                pk: pk, start: start, end: row[2].cocoaDate ?? start, name: row[3].string ?? "Unnamed device",
                address: row[4].string ?? "", deviceType: row[5].int.map(Int.init), productID: row[6].int.map(Int.init),
                isAppleAudio: row[7].bool ?? false, host: deviceLabel(row[8].string, models)))
        }
        return (out, notConnected)
    }

    // MARK: Notifications

    /// `/notification/usage` events per bundle id.
    static func notificationCounts() async -> (perApp: [(bundle: String, count: Int)], total: Int, range: ClosedRange<Date>?) {
        guard let db = await db() else { return ([], 0, nil) }
        var perApp: [(String, Int)] = []
        if await db.hasColumns("ZSTRUCTUREDMETADATA", ["Z_DKNOTIFICATIONUSAGEMETADATAKEY__BUNDLEID"]) {
            let sql = """
                SELECT coalesce(m.Z_DKNOTIFICATIONUSAGEMETADATAKEY__BUNDLEID, o.ZVALUESTRING, '(unknown)'), count(*)
                FROM ZOBJECT o LEFT JOIN ZSTRUCTUREDMETADATA m ON m.Z_PK = o.ZSTRUCTUREDMETADATA
                WHERE o.ZSTREAMNAME = '/notification/usage' GROUP BY 1 ORDER BY 2 DESC LIMIT 500
                """
            for row in (try? await db.rows(sql)) ?? [] {
                perApp.append((row[0].string ?? "(unknown)", Int(row[1].int ?? 0)))
            }
        }
        var total = 0
        var range: ClosedRange<Date>?
        if let row = try? await db.first("SELECT count(*), min(ZSTARTDATE), max(ZSTARTDATE) FROM ZOBJECT WHERE ZSTREAMNAME = '/notification/usage'") {
            total = Int(row[0].int ?? 0)
            if let lo = row[1].cocoaDate, let hi = row[2].cocoaDate, lo <= hi { range = lo...hi }
        }
        return (perApp, total, range)
    }

    // MARK: Sync peers

    static func peers() async -> [KnowledgePeer] {
        guard let db = await db(), await db.hasColumns("ZSYNCPEER", ["ZDEVICEID", "ZMODEL"]) else { return [] }
        let cols = await db.columnSet(of: "ZSYNCPEER")
        func col(_ name: String) -> String { cols.contains(name) ? name : "NULL" }
        var peers: [String: KnowledgePeer] = [:]
        var order: [String] = []
        let sql = "SELECT Z_PK, ZDEVICEID, ZMODEL, \(col("ZVERSION")), \(col("ZLASTSEENDATE")), \(col("ZCLOUDID")) IS NOT NULL, \(col("ZRAPPORTID")) IS NOT NULL FROM ZSYNCPEER ORDER BY \(col("ZLASTSEENDATE")) DESC LIMIT 500"
        for row in (try? await db.rows(sql)) ?? [] {
            guard let pk = row[0].int else { continue }
            let key = row[1].string ?? "pk\(pk)"
            peers[key] = KnowledgePeer(
                id: pk, model: row[2].string ?? "", version: row[3].string ?? "", lastSeen: row[4].cocoaDate,
                hasCloudID: row[5].bool ?? false, hasRapportID: row[6].bool ?? false, events: 0, streams: [])
            order.append(key)
        }
        if await db.hasColumns("ZSOURCE", ["ZDEVICEID"]) {
            let usage = """
                SELECT s.ZDEVICEID, o.ZSTREAMNAME, count(*) FROM ZOBJECT o JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE
                WHERE s.ZDEVICEID IS NOT NULL AND o.ZSTREAMNAME NOT LIKE '/knowledge-sync%' GROUP BY 1, 2
                """
            for row in (try? await db.rows(usage, maxRows: 5_000)) ?? [] {
                guard let id = row[0].string, var peer = peers[id] else { continue }
                peer.events += Int(row[2].int ?? 0)
                if let stream = row[1].string { peer.streams.append(stream) }
                peers[id] = peer
            }
        }
        return order.compactMap { peers[$0] }
    }
}
