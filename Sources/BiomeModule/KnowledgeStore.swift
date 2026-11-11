import Foundation
import DossierCore

/// One knowledgeC stream with counts.
struct KnowledgeStream: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let count: Int
    let first: Date?
    let last: Date?
    let withMetadata: Int
    /// Number of events per source device model ("" = this Mac / unknown).
    let devices: [String]
    var isBookkeeping: Bool { KnowledgeStreamRegistry.isBookkeeping(name) }
}

struct KnowledgeEvent: Identifiable, Sendable {
    let id: Int64
    let stream: String
    let start: Date?
    let end: Date?
    let value: String
    let bundle: String
    let device: String
    let metadata: String
    let gmtOffset: Int?

    var duration: TimeInterval? {
        guard let start, let end, end > start else { return nil }
        return end.timeIntervalSince(start)
    }
}

struct KnowledgeDetail: Sendable {
    let items: [KeyValueItem]
    let metadata: [KeyValueItem]
    let blobs: [(name: String, data: Data)]
}

/// Read-only access to `knowledgeC.db` (CoreData store of the CoreDuet knowledge daemon).
///
/// `ZOBJECT` holds one row per event (`ZSTREAMNAME`, `ZSTARTDATE` / `ZENDDATE` in Cocoa
/// seconds, `ZVALUESTRING` / `ZVALUEINTEGER`), `ZSTRUCTUREDMETADATA` a wide row of optional
/// typed attributes (column names are `Z_DK<GROUP>METADATAKEY__<KEY>`), `ZSOURCE` the
/// donating bundle and device, `ZSYNCPEER` the known devices.
enum KnowledgeStore {
    static var url: URL { Paths.knowledgeC }

    static func open() async throws -> SQLiteDB {
        switch Paths.probe(url) {
        case .missing: throw DossierError.missing("knowledgeC.db does not exist on this Mac.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        let db: SQLiteDB
        do { db = try await SQLiteDB.shared(url) } catch { throw DossierError.inaccessible(error.localizedDescription) }
        guard await db.hasColumns("ZOBJECT", ["ZSTREAMNAME", "ZSTARTDATE", "ZENDDATE"]) else {
            throw DossierError.missing("The ZOBJECT table of knowledgeC.db has an unknown layout on this macOS version.")
        }
        return db
    }

    /// Model name per device identifier from ZSYNCPEER (e.g. a hardware model string).
    private static func deviceModels(_ db: SQLiteDB) async -> [String: String] {
        guard await db.hasColumns("ZSYNCPEER", ["ZDEVICEID", "ZMODEL"]) else { return [:] }
        var out: [String: String] = [:]
        for row in (try? await db.rows("SELECT ZDEVICEID, ZMODEL FROM ZSYNCPEER WHERE ZDEVICEID IS NOT NULL")) ?? [] {
            if let id = row[0].string { out[id] = row[1].string ?? "" }
        }
        return out
    }

    private static func deviceLabel(_ id: String?, models: [String: String]) -> String {
        guard let id else { return "This Mac" }
        if let model = models[id], !model.isEmpty { return model }
        return "Synced device"
    }

    static func streams() async throws -> [KnowledgeStream] {
        let db = try await open()
        let hasMeta = await db.hasColumns("ZOBJECT", ["ZSTRUCTUREDMETADATA"])
        let rows = try await db.rows("""
            SELECT ZSTREAMNAME, count(*), min(CASE WHEN ZSTARTDATE > 0 THEN ZSTARTDATE END), max(CASE WHEN ZSTARTDATE > 0 THEN ZSTARTDATE END),
                   \(hasMeta ? "count(ZSTRUCTUREDMETADATA)" : "0")
            FROM ZOBJECT GROUP BY ZSTREAMNAME ORDER BY count(*) DESC
            """)
        var devices: [String: [String]] = [:]
        if await db.hasColumns("ZSOURCE", ["ZDEVICEID"]), await db.hasColumns("ZOBJECT", ["ZSOURCE"]) {
            let models = await deviceModels(db)
            let perDevice = (try? await db.rows("""
                SELECT o.ZSTREAMNAME, s.ZDEVICEID, count(*) FROM ZOBJECT o JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE
                WHERE s.ZDEVICEID IS NOT NULL GROUP BY 1, 2 ORDER BY 3 DESC
                """)) ?? []
            for row in perDevice {
                guard let stream = row[0].string else { continue }
                devices[stream, default: []].append(deviceLabel(row[1].string, models: models))
            }
        }
        return rows.compactMap { row in
            guard let name = row[0].string else { return nil }
            return KnowledgeStream(name: name, count: Int(row[1].int ?? 0), first: row[2].cocoaDate, last: row[3].cocoaDate,
                                   withMetadata: Int(row[4].int ?? 0), devices: devices[name] ?? [])
        }
    }

    private static let sortColumns: [String: String] = [
        "start": "o.ZSTARTDATE", "end": "o.ZENDDATE", "duration": "(o.ZENDDATE - o.ZSTARTDATE)", "value": "o.ZVALUESTRING", "id": "o.Z_PK",
    ]

    private static func filter(stream: String?, search: String, hasSource: Bool) -> (String, [SQLValue]) {
        var clauses: [String] = []
        var args: [SQLValue] = []
        if let stream {
            clauses.append("o.ZSTREAMNAME = ?"); args.append(.text(stream))
        } else {
            clauses.append("o.ZSTREAMNAME NOT LIKE '/knowledge-sync-%'")
        }
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            let like = "%" + needle.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            if hasSource {
                clauses.append("(o.ZVALUESTRING LIKE ? ESCAPE '\\' OR s.ZBUNDLEID LIKE ? ESCAPE '\\')")
                args.append(.text(like)); args.append(.text(like))
            } else {
                clauses.append("o.ZVALUESTRING LIKE ? ESCAPE '\\'"); args.append(.text(like))
            }
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), args)
    }

    static func count(stream: String?, search: String) async throws -> Int {
        let db = try await open()
        let sourceTable = await db.hasColumns("ZSOURCE", ["ZBUNDLEID", "ZDEVICEID"])
        let sourceColumn = await db.hasColumns("ZOBJECT", ["ZSOURCE"])
        let hasSource = sourceTable && sourceColumn
        let (whereSQL, args) = filter(stream: stream, search: search, hasSource: hasSource)
        let join = hasSource ? "LEFT JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE" : ""
        return await db.count("SELECT count(*) FROM ZOBJECT o \(join) \(whereSQL)", args) ?? 0
    }

    static func events(stream: String?, search: String, sort: PageSort?, offset: Int, limit: Int, before: Date? = nil) async throws -> [KnowledgeEvent] {
        let db = try await open()
        let cols = Set(await db.columnNames(of: "ZOBJECT").map { $0.uppercased() })
        let sourceTable = await db.hasColumns("ZSOURCE", ["ZBUNDLEID", "ZDEVICEID"])
        let hasSource = sourceTable && cols.contains("ZSOURCE")
        let metaTable = await db.tableExists("ZSTRUCTUREDMETADATA")
        let hasMeta = cols.contains("ZSTRUCTUREDMETADATA") && metaTable
        var (whereSQL, args) = filter(stream: stream, search: search, hasSource: hasSource)
        if let before {
            whereSQL += (whereSQL.isEmpty ? "WHERE " : " AND ") + "o.ZSTARTDATE <= ?"
            args.append(.real(before.timeIntervalSinceReferenceDate))
        }
        let order = sort.flatMap { s in sortColumns[s.columnID].map { "\($0) \(s.sqlDirection)" } } ?? "o.ZSTARTDATE DESC"
        func col(_ name: String) -> String { cols.contains(name) ? "o.\(name)" : "NULL" }
        let sql = """
            SELECT o.Z_PK, o.ZSTREAMNAME, o.ZSTARTDATE, o.ZENDDATE, \(col("ZVALUESTRING")), \(col("ZVALUEINTEGER")), \(col("ZVALUEDOUBLE")),
                   \(col("ZSECONDSFROMGMT")), \(hasMeta ? "o.ZSTRUCTUREDMETADATA" : "NULL"),
                   \(hasSource ? "s.ZBUNDLEID, s.ZDEVICEID" : "NULL, NULL")
            FROM ZOBJECT o \(hasSource ? "LEFT JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE" : "")
            \(whereSQL) ORDER BY \(order), o.Z_PK DESC LIMIT ? OFFSET ?
            """
        let result = try await db.query(sql, args + [.integer(Int64(limit)), .integer(Int64(offset))])
        let models = hasSource ? await deviceModels(db) : [:]
        let metaIDs = result.rows.compactMap { $0[8].int }
        let metadata = hasMeta ? await metadataSummaries(db, ids: metaIDs) : [:]
        return result.rows.map { row in
            let value: String
            if let s = row[4].string, !s.isEmpty { value = s }
            else if let i = row[5].int { value = String(i) }
            else if let d = row[6].double, d != 0 { value = Format.number(d) }
            else { value = "" }
            return KnowledgeEvent(
                id: row[0].int ?? 0, stream: row[1].string ?? "", start: plausible(row[2].cocoaDate), end: plausible(row[3].cocoaDate),
                value: value, bundle: row[9].string ?? "", device: hasSource ? deviceLabel(row[10].string, models: models) : "This Mac",
                metadata: row[8].int.flatMap { metadata[$0] } ?? "", gmtOffset: row[7].int.map(Int.init)
            )
        }
    }

    /// True when the newest events of a stream (the first page of its table) carry no
    /// structured metadata or (nearly) all the same: one metadata row covers at least 90 %
    /// of the page. Metadata rows are shared between events with equal content, so
    /// comparing the reference is enough.
    static func metadataIsUniform(stream: String, page: Int = 200) async -> Bool {
        guard let db = try? await open(), await db.hasColumns("ZOBJECT", ["ZSTRUCTUREDMETADATA"]) else { return true }
        guard let row = try? await db.first("""
            SELECT max(c), sum(c) FROM (SELECT count(*) AS c FROM
            (SELECT ZSTRUCTUREDMETADATA AS m FROM ZOBJECT WHERE ZSTREAMNAME = ? ORDER BY ZSTARTDATE DESC, Z_PK DESC LIMIT ?) GROUP BY m)
            """, [.text(stream), .integer(Int64(page))]), let top = row[0].int, let total = row[1].int, total > 0 else { return true }
        return Double(top) >= 0.9 * Double(total)
    }

    private static func plausible(_ date: Date?) -> Date? {
        guard let date, DossierDate.isPlausible(date) else { return nil }
        return date
    }

    /// `Z_DKINTENTMETADATAKEY__INTENTCLASS` → `intent.intentclass`.
    static func prettyMetadataKey(_ column: String) -> String {
        var name = column
        while name.hasPrefix("Z") || name.hasPrefix("_") { name.removeFirst() }
        let parts = name.components(separatedBy: "__")
        guard parts.count == 2 else { return name.lowercased() }
        var group = parts[0]
        for prefix in ["DK", "CD", "QP"] where group.hasPrefix(prefix) { group.removeFirst(prefix.count); break }
        for suffix in ["METADATAKEY", "METADATA"] where group.hasSuffix(suffix) { group.removeLast(suffix.count); break }
        return (group.isEmpty ? "" : group.lowercased() + ".") + parts[1].lowercased()
    }

    private static func describe(_ value: SQLValue, column: String, fullSize: Int? = nil) -> String? {
        if value.isNull { return nil }
        if let data = value.data {
            if let text = blobText(data) { return text }
            return "\(Format.bytes(fullSize ?? data.count)) blob"
        }
        let upper = column.uppercased()
        if upper.hasSuffix("DATE") || upper.hasSuffix("PERIODSTART") || upper.hasSuffix("PERIODEND"), let date = value.cocoaDate, DossierDate.isPlausible(date) {
            return DossierDate.sortable(date)
        }
        if let s = value.string { return s }
        if let i = value.int { return String(i) }
        if let d = value.double { return Format.number(d, maxDigits: 5) }
        return nil
    }

    /// CoreData stores some strings with BLOB affinity; short printable UTF-8 is text.
    private static func blobText(_ data: Data) -> String? {
        guard data.count <= 512, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        for u in s.unicodeScalars where u.value < 0x20 || u.value == 0x7F { return nil }
        return s
    }

    /// "key=value · …" over the non-null columns of the given metadata rows.
    private static func metadataSummaries(_ db: SQLiteDB, ids: [Int64]) async -> [Int64: String] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        let list = unique.map(String.init).joined(separator: ",")
        guard let result = try? await db.query("SELECT * FROM ZSTRUCTUREDMETADATA WHERE Z_PK IN (\(list))", [], cellByteLimit: 64) else { return [:] }
        var out: [Int64: String] = [:]
        for row in result.rows {
            var pk: Int64?
            var parts: [String] = []
            for (i, column) in result.columns.enumerated() {
                let upper = column.uppercased()
                if upper == "Z_PK" { pk = row[i].int; continue }
                if upper == "Z_ENT" || upper == "Z_OPT" || upper == "ZMETADATAHASH" { continue }
                guard let text = describe(row[i], column: column) else { continue }
                parts.append("\(prettyMetadataKey(column))=\(Format.oneLine(text, max: 80))")
            }
            if let pk { out[pk] = parts.joined(separator: " · ") }
        }
        return out
    }

    /// Everything about one event for the inspector, with blobs in full.
    static func detail(id: Int64) async throws -> KnowledgeDetail {
        let db = try await open()
        let objectResult = try await db.query("SELECT * FROM ZOBJECT WHERE Z_PK = ?", [.integer(id)])
        guard let object = objectResult.rows.first else { throw DossierError.message("The event no longer exists.") }
        let objectColumns = objectResult.columns
        var items: [KeyValueItem] = []
        var blobs: [(String, Data)] = []
        var metaID: Int64?, sourceID: Int64?
        let skip: Set<String> = ["Z_ENT", "Z_OPT", "ZUUIDHASH", "ZCOMPATIBILITYVERSION", "ZHASCUSTOMMETADATA", "ZHASSTRUCTUREDMETADATA", "ZSHOULDSYNC",
                                 "ZVALUECLASS", "ZVALUETYPECODE", "ZSTARTDAYOFWEEK", "ZENDDAYOFWEEK", "ZSTARTSECONDOFDAY", "ZENDSECONDOFDAY"]
        for (i, column) in objectColumns.enumerated() {
            let upper = column.uppercased()
            if upper == "ZSTRUCTUREDMETADATA" { metaID = object[i].int; continue }
            if upper == "ZSOURCE" { sourceID = object[i].int; continue }
            if skip.contains(upper) || object[i].isNull { continue }
            if let data = object[i].data, blobText(data) == nil { blobs.append((column, data)); continue }
            if (upper == "ZVALUEINTEGER" || upper == "ZVALUEDOUBLE"), abs(object[i].double ?? 0) > 1e15 { continue }
            guard let text = describe(object[i], column: column) else { continue }
            var name = column
            if name.hasPrefix("Z") { name.removeFirst() }
            let personal = upper == "ZVALUESTRING" || upper == "ZSTRING"
            items.append(KeyValueItem(upper == "Z_PK" ? "row" : name.lowercased(), text, sensitivity: personal ? .personal : .low, id: "o." + column))
        }
        if let sourceID, await db.tableExists("ZSOURCE"),
           let result = try? await db.query("SELECT * FROM ZSOURCE WHERE Z_PK = ?", [.integer(sourceID)]), let row = result.rows.first {
            for (i, column) in result.columns.enumerated() {
                let upper = column.uppercased()
                if ["Z_PK", "Z_ENT", "Z_OPT"].contains(upper) || row[i].isNull { continue }
                guard let text = describe(row[i], column: column) else { continue }
                var name = column
                if name.hasPrefix("Z") { name.removeFirst() }
                items.append(KeyValueItem("source." + name.lowercased(), text, sensitivity: .personal, monospaced: upper.hasSuffix("ID"), id: "s." + column))
            }
        }
        var metadata: [KeyValueItem] = []
        if let metaID, await db.tableExists("ZSTRUCTUREDMETADATA"),
           let result = try? await db.query("SELECT * FROM ZSTRUCTUREDMETADATA WHERE Z_PK = ?", [.integer(metaID)]), let row = result.rows.first {
            for (i, column) in result.columns.enumerated() {
                let upper = column.uppercased()
                if ["Z_PK", "Z_ENT", "Z_OPT"].contains(upper) || row[i].isNull { continue }
                let key = prettyMetadataKey(column)
                if let data = row[i].data, blobText(data) == nil { blobs.append((key, data)); continue }
                guard let text = describe(row[i], column: column) else { continue }
                metadata.append(KeyValueItem(key, text, sensitivity: .personal, id: "m." + column))
            }
        }
        return KnowledgeDetail(items: items, metadata: metadata, blobs: blobs.map { (name: $0.0, data: $0.1) })
    }
}
