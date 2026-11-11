import Foundation
import DossierCore

/// One inferred language (rows of `inferred_triples.db › languages` sharing a subject).
struct LanguageInference: Identifiable, Sendable {
    let id: Int64
    var code = ""
    var locale = ""
    var region = ""
    var confidence: Double?
    var reading: Double?
    var writing: Double?
    var listening: Double?
    var sourceTypes: [String] = []
    /// Raw evidence JSON (`PS51`): language → signal → weight.
    var evidence = ""
    var updated: Date?
    var other: [(label: String, value: String)] = []

    var displayName: String {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return name.isEmpty ? "Unknown language" : name.capitalized
    }

    var summary: String {
        let region = locale.isEmpty ? self.region : locale
        return region.isEmpty ? displayName : "\(displayName) (\(region))"
    }
}

/// Specification of a generically displayed table.
struct TableSpec: Sendable, Hashable {
    var url: URL
    var table: String
    /// Columns holding node ids (`md:<id>` or bare integers); a resolved "name" column is added after each.
    var nodeColumns: [String] = []
    var sensitiveColumns: [String] = []
    var orderBy: String?
    var descending = false
    var limit = 5_000
    /// Columns to leave out (large blobs that are summarised elsewhere).
    var skipColumns: [String] = []
}

/// Data access for the "Derived views & inferences" section and helpers shared with the
/// people section (feature values).
enum DerivedStore {
    // MARK: Languages

    static func languages() async throws -> [LanguageInference] {
        let db = try await GraphPaths.open(GraphPaths.inferredTriples)
        guard await db.hasColumns("languages", ["subject", "predicate", "object"]) else {
            throw DossierError.missing("inferred_triples.db has no languages table on this macOS version.")
        }
        let ontology = await GraphStore.shared.ontology()
        let hasTime = await db.hasColumns("languages", ["timestamp"])
        let rows = try await db.rows("SELECT subject, predicate, object\(hasTime ? ", timestamp" : "") FROM languages ORDER BY subject LIMIT 5000")
        var map: [Int64: LanguageInference] = [:]
        var order: [Int64] = []
        for r in rows {
            guard let subject = r[0].int, let predicate = r[1].string else { continue }
            let object = r[2].string ?? ""
            if map[subject] == nil { map[subject] = LanguageInference(id: subject); order.append(subject) }
            if hasTime, let t = r[3].cocoaDate { map[subject]!.updated = max(map[subject]!.updated ?? t, t) }
            switch predicate {
            case P.isA: break
            case P.name: map[subject]!.code = object
            case "nm_localeIdentifier": map[subject]!.locale = object
            case "PS569": map[subject]!.region = object
            case "nm_confidence": map[subject]!.confidence = Double(object)
            case "nm_reading_confidence": map[subject]!.reading = Double(object)
            case "nm_writing_confidence": map[subject]!.writing = Double(object)
            case "nm_listening_confidence": map[subject]!.listening = Double(object)
            case "nm_sourceType":
                if let data = object.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    map[subject]!.sourceTypes = list
                } else if !object.isEmpty { map[subject]!.sourceTypes = [object] }
            case "PS51": map[subject]!.evidence = object
            default: map[subject]!.other.append((ontology.predicateLabel(predicate), object))
            }
        }
        return order.compactMap { map[$0] }
    }

    // MARK: Feature values

    /// Decodes a `kv.value` blob: an NSKeyedArchiver `MLFeatureValue` (type 1 = integer,
    /// 2 = double, 3 = string; `undefined` marks a missing value) or a plain plist.
    static func describeBlob(_ data: Data) -> String {
        if let value = PlistDecoder.decodeAny(data) { return describe(value) }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value < 9 }) {
            return Format.oneLine(text, max: 300)
        }
        return "\(Format.bytes(data.count)) of binary data"
    }

    static func describe(_ value: PlistValue) -> String {
        switch value {
        case .dict(let pairs):
            let isFeature = value["$class"]?.string == "MLFeatureValue" || (value["type"] != nil && value["undefined"] != nil)
            if isFeature {
                if value["undefined"]?.bool == true { return "undefined" }
                if let inner = value["value"] { return describe(inner) }
                return "—"
            }
            let parts = pairs.filter { $0.key != "$class" }.prefix(8).map { "\($0.key): \(describe($0.value))" }
            return "{" + parts.joined(separator: ", ") + (pairs.count > 8 ? ", …" : "") + "}"
        case .array(let items):
            if items.count == 1 { return describe(items[0]) }
            return "[" + items.prefix(12).map(describe).joined(separator: ", ") + (items.count > 12 ? ", …" : "") + "]"
        case .string(let s): return GraphFormat.cleanLabel(s)
        case .real(let d): return Format.number(d, maxDigits: 4)
        default: return PlistDecoder.describe(value)
        }
    }

    struct FeatureValue: Sendable, Identifiable {
        var id: String { view + "|" + feature }
        let view: String
        let feature: String
        let value: String
    }

    /// Features stored for one node (`subidentifierName = "md:<id>"`).
    static func features(for node: Int64, limit: Int = 600) async -> [FeatureValue] {
        guard let db = await GraphPaths.openIfAvailable(GraphPaths.features),
              await db.hasColumns("kv", ["viewName", "featureName", "subidentifierName", "value"]) else { return [] }
        let rows = (try? await db.rows(
            "SELECT viewName, featureName, value FROM kv WHERE subidentifierName IN (?, ?) ORDER BY viewName, featureName LIMIT ?",
            [.text(GraphRef.string(node)), .text(String(node)), .integer(Int64(limit))])) ?? []
        return rows.map { r in
            FeatureValue(view: r[0].string ?? "", feature: r[1].string ?? "", value: r[2].data.map(describeBlob) ?? (r[2].string ?? ""))
        }
    }

    // MARK: Generic tables

    static func nodeID(_ value: SQLValue) -> Int64? {
        if let s = value.string, let ref = GraphRef.parse(s) { return ref }
        if case .integer = value { return value.int }
        if let s = value.string { return Int64(s) }
        return nil
    }

    static func isTimeColumn(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("timestamp") || n.hasSuffix("date") || n.hasSuffix("time") || n == "createdat" || n == "updatedat" || n == "occurredat"
    }

    static func cell(_ value: SQLValue, column: String) -> String {
        switch value {
        case .null: return ""
        case .blob(let data): return describeBlob(data)
        case .real(let d):
            if isTimeColumn(column), d > 3e8, d < 2e9 { return DossierDate.sortable(Date(timeIntervalSinceReferenceDate: d)) }
            return Format.number(d, maxDigits: 4)
        case .integer(let i):
            if isTimeColumn(column), i > 300_000_000, i < 2_000_000_000 { return DossierDate.sortable(Date(timeIntervalSinceReferenceDate: Double(i))) }
            return String(i)
        case .text(let s):
            return Format.oneLine(GraphFormat.cleanLabel(s), max: 400)
        }
    }

    static func rowCount(_ url: URL, _ table: String) async -> Int? {
        guard let db = await GraphPaths.openIfAvailable(url), await db.tableExists(table) else { return nil }
        return await db.rowCount(of: table)
    }

    static func load(_ spec: TableSpec) async throws -> GenericTableData {
        let db = try await GraphPaths.open(spec.url)
        guard await db.tableExists(spec.table) else {
            throw DossierError.missing("Table \(spec.table) does not exist in \(spec.url.lastPathComponent) on this macOS version.")
        }
        let columns = await db.columns(of: spec.table).map(\.name).filter { !spec.skipColumns.contains($0) }
        guard !columns.isEmpty else { return .empty }
        let index = spec.nodeColumns.isEmpty ? nil : try? await GraphStore.shared.index()
        var sql = "SELECT " + columns.map(SQLiteDB.quote).joined(separator: ", ") + " FROM " + SQLiteDB.quote(spec.table)
        if let order = spec.orderBy, columns.contains(order) { sql += " ORDER BY " + SQLiteDB.quote(order) + (spec.descending ? " DESC" : " ASC") }
        sql += " LIMIT ?"
        let result = try await db.query(sql, [.integer(Int64(spec.limit + 1))], maxRows: spec.limit + 1, cellByteLimit: 64_000)
        var header: [String] = []
        for c in columns {
            header.append(c)
            if spec.nodeColumns.contains(c) { header.append(c + " → name") }
        }
        var rows: [GenericRow] = []
        rows.reserveCapacity(min(result.rows.count, spec.limit))
        for (i, r) in result.rows.prefix(spec.limit).enumerated() {
            var cells: [String] = []
            cells.reserveCapacity(header.count)
            for (ci, c) in columns.enumerated() {
                cells.append(cell(r[ci], column: c))
                if spec.nodeColumns.contains(c) {
                    cells.append(nodeID(r[ci]).flatMap { index?.name($0) } ?? "")
                }
            }
            rows.append(GenericRow(id: i, cells: cells))
        }
        var sensitive = Set(spec.sensitiveColumns)
        for c in spec.nodeColumns { sensitive.insert(c + " → name") }
        return GenericTableData(columns: header, rows: rows, sensitive: sensitive, truncated: result.rows.count > spec.limit)
    }

    // MARK: Pipeline status

    struct PipelineStatus: Sendable {
        var facts: [(label: String, value: String)] = []
        /// Source phases from graph.db `phase_status` joined with the derived source names.
        var phases: [(source: String, status: String)] = []
        var views = GenericTableData.empty
        var viewCount = 0
        var viewsWithTables = 0
        var viewErrors = 0
        var schedules: [(name: String, state: String)] = []
        var sourcesAvailable = 0
        var sourcesTotal = 0
    }

    static func pipelineStatus() async throws -> PipelineStatus {
        var status = PipelineStatus()
        var foundAny = false

        if let db = await GraphPaths.openIfAvailable(GraphPaths.graph) {
            foundAny = true
            if await db.hasColumns("graph_state", ["key", "value"]), let rows = try? await db.rows("SELECT key, value FROM graph_state LIMIT 100") {
                for r in rows {
                    let key = r[0].string ?? ""
                    var value = cell(r[1], column: key)
                    if key.lowercased().contains("hash"), value.count > 16 { value = String(value.prefix(16)) + "…" }
                    status.facts.append(("graph.db · " + Ontology.prettifyKey(key), value))
                }
            }
            if await db.hasColumns("phase_status", ["source", "status"]), let rows = try? await db.rows("SELECT source, status FROM phase_status ORDER BY source LIMIT 200") {
                let catalog = (try? await GraphStore.shared.index())?.sources ?? SourceCatalog()
                for r in rows {
                    let n = Int(r[0].int ?? 0)
                    // phase_status.source is 1-based; bit (n − 1) of `sources` is the same system.
                    let name = n > 0 && catalog.kinds[n - 1] != nil ? "\(catalog.title(bit: n - 1)) (\(catalog.kinds[n - 1] ?? ""))" : "Source \(n) (no rows on this Mac)"
                    status.phases.append((name, "status \(r[1].int ?? 0)"))
                }
            }
        }
        if let db = await GraphPaths.openIfAvailable(GraphPaths.keyvalue), await db.hasColumns("keyvalue", ["domain", "key", "value"]) {
            foundAny = true
            let rows = (try? await db.rows("SELECT domain, key, value FROM keyvalue WHERE domain LIKE 'Pipeline.Status.%' AND key NOT LIKE '%: <%' AND key NOT LIKE '%.%' ORDER BY domain, key LIMIT 200")) ?? []
            for r in rows {
                let domain = (r[0].string ?? "").replacingOccurrences(of: "Pipeline.Status.", with: "").replacingOccurrences(of: ".previous", with: "")
                let key = r[1].string ?? ""
                if key.lowercased().contains("sessionid") { continue }
                status.facts.append(("\(domain) run · " + Ontology.prettifyKey(key), r[2].data.map(describeBlob) ?? cell(r[2], column: key)))
            }
        }
        if let db = await GraphPaths.openIfAvailable(GraphPaths.views) {
            foundAny = true
            if await db.hasColumns("scheduleState", ["schedule", "updateState"]), let rows = try? await db.rows("SELECT schedule, updateState FROM scheduleState ORDER BY schedule LIMIT 100") {
                status.schedules = rows.map { ($0[0].string ?? "", $0[1].string ?? "") }
            }
            if await db.hasColumns("sourceState", ["available"]) {
                status.sourcesTotal = await db.rowCount(of: "sourceState") ?? 0
                status.sourcesAvailable = await db.count("SELECT count(*) FROM sourceState WHERE available = 1") ?? 0
            }
            if await db.hasColumns("viewConfigRecord", ["id", "name", "generationType", "artifactPath", "artifactTable"]) {
                let hasState = await db.hasColumns("viewState", ["viewOrderedId", "enabledStatus", "attemptCount", "errorMessage", "tablesCreated"])
                let sql = hasState
                    ? "SELECT c.id, c.name, c.generationType, c.artifactType, c.artifactPath, c.artifactTable, s.tablesCreated, s.attemptCount, s.errorMessage FROM viewConfigRecord c LEFT JOIN viewState s ON s.viewOrderedId = c.id ORDER BY c.id LIMIT 2000"
                    : "SELECT id, name, generationType, artifactType, artifactPath, artifactTable, NULL, NULL, NULL FROM viewConfigRecord ORDER BY id LIMIT 2000"
                if let rows = try? await db.rows(sql) {
                    var out: [GenericRow] = []
                    for (i, r) in rows.enumerated() {
                        let created = r[6].int ?? 0
                        let error = r[8].string ?? ""
                        if created != 0 { status.viewsWithTables += 1 }
                        if !error.isEmpty { status.viewErrors += 1 }
                        out.append(GenericRow(id: i, cells: [
                            String(r[0].int ?? 0), r[1].string ?? "", r[2].string ?? "", r[3].string ?? "",
                            r[4].string ?? "", r[5].string ?? "", created != 0 ? "yes" : "no", String(r[7].int ?? 0), Format.oneLine(error, max: 200),
                        ]))
                    }
                    status.viewCount = rows.count
                    status.views = GenericTableData(columns: ["#", "View", "Generation", "Artifact type", "Artifact file", "Table", "Materialised", "Attempts", "Error"], rows: out)
                }
            }
        }
        if !foundAny {
            switch Paths.probe(GraphPaths.root) {
            case .inaccessible(let reason): throw DossierError.inaccessible(reason)
            default: throw DossierError.missing("No IntelligencePlatform pipeline databases exist on this Mac.")
            }
        }
        return status
    }
}

extension Ontology {
    /// "lastPipelineRunFinishDate" → "last pipeline run finish date".
    static func prettifyKey(_ key: String) -> String {
        var out = ""
        for ch in key {
            if ch.isUppercase, let last = out.last, last.isLowercase || last.isNumber { out.append(" "); out.append(contentsOf: ch.lowercased()) }
            else { out.append(ch) }
        }
        // "isICloudFamily" → "ICloud family": keep the product's own spelling.
        return out.replacingOccurrences(of: "ICloud", with: "iCloud")
    }
}
