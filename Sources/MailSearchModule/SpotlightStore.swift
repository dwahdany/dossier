import Foundation
import DossierCore

// MARK: - Document processing (CoreSpotlight/DocumentProcessing/PipelineStorage)
//
// StateStore.db (GRDB): `pipeline(id, name, currentProcessorVersion)`,
//   `item(identityID, lookupID, source, textContentHash, priorityDate[unix s])` — every
//   document the pipelines know, `pipeline_item(pipeline, identityID, processedVersion,
//   hasResult, errorDomain, errorCode, deleteStatus, …)` — one row per (pipeline, item),
//   `destination(pipeline, name, kind)` — where results go (the HybridSearch index),
//   `bookmark(source, …)` — one per donating source set.
// CachedResultStore.db: `pipeline(name, count)`, `cached_result(pipeline, itemHash,
//   hasResult, lastAccessTime)`, `cached_result_data(data)` — binary plists
//   { results: [ { key: { entityType, sourceItemIdentifier, attributeName }, vector:
//   { float16: [...] }, version } ] } i.e. the embedding cache.

struct PipelineStat: Identifiable, Sendable, Hashable {
    let id: Int64
    let name: String
    let version: Int64?
    var items = 0
    var processed = 0
    var withResult = 0
    var errors = 0
    var pendingDelete = 0
    var cached = 0
    var cachedWithResult = 0
    var destination: String?

    var isActive: Bool { items > 0 }

    /// Plain-English purpose, from the pipeline's name.
    var purpose: String {
        let n = name.lowercased()
        if n.contains("glpembedding") || n == "embedding" || n == "fullembedding" { return "Computes text embeddings (vectors) of your documents for semantic search." }
        if n.contains("glpindexing") { return "Writes documents into the hybrid (keyword + vector) search index." }
        if n.contains("mailattachments") { return "Imports mail attachments and extracts their text." }
        if n.contains("keyphrase") { return "Extracts key phrases from document text." }
        if n.contains("smartreplies") { return "Prepares smart-reply suggestions from messages." }
        if n.contains("eventsandorders") { return "Looks for events, reservations and orders in messages." }
        if n.contains("identificationdocuments") { return "Looks for identity documents mentioned in or attached to messages." }
        if n.contains("carkey") { return "Looks for car-key related data in messages." }
        if n.contains("migration") { return "One-off migration of previously indexed items." }
        return "Document processing pipeline."
    }
}

struct PipelineSource: Identifiable, Sendable, Hashable {
    let id: Int64
    let items: Int
    let range: ClosedRange<Date>?
    var label: String
}

struct PipelineError: Identifiable, Sendable, Hashable {
    var id: String { "\(pipeline)|\(domain)|\(code)" }
    let pipeline: String
    let domain: String
    let code: Int64
    let count: Int
}

struct BundleCompleteness: Identifiable, Sendable, Hashable {
    var id: String { bundle }
    let bundle: String
    let classification: String
    let rank: String
    let percent: Double
    let knownItems: Int
    let needingDonation: Int
    let eligible: Int
    let processed: Int
}

struct DocumentProcessingReport: Sendable {
    var pipelines: [PipelineStat] = []
    var sources: [PipelineSource] = []
    var errors: [PipelineError] = []
    var years: [(year: Int, count: Int)] = []
    var yearsSourceLabel = ""
    var totalItems = 0
    var documentStoreCache = 0
    var embeddingDimensions: Int?
    var embeddingEntityType: String?
    var embeddingVectorsPerItem: Int?
    var completeness: [BundleCompleteness] = []
    var completenessComputed: Date?
    var enabledPipelines: [String] = []
    var stateAvailability: Availability = .missing
    var cacheAvailability: Availability = .missing

    var embeddings: Int { pipelines.filter { $0.name.lowercased().contains("embedding") }.map(\.withResult).max() ?? 0 }
    var cachedEmbeddings: Int { pipelines.map(\.cachedWithResult).reduce(0, +) }
}

enum SpotlightStore {
    /// Full statistics. The per-pipeline aggregate walks `pipeline_item` once (~0.5 s
    /// per million rows) — call from a loader, not from `summary()`.
    static func documentProcessing(cascade: [CascadeSetSummary] = []) async -> DocumentProcessingReport {
        var report = DocumentProcessingReport()
        report.stateAvailability = Paths.probe(MSPaths.stateStore)
        report.cacheAvailability = Paths.probe(MSPaths.cachedResultStore)
        var byID: [Int64: PipelineStat] = [:]
        var order: [Int64] = []

        if let db = await SQLiteDB.sharedIfAvailable(MSPaths.stateStore) {
            if await db.hasColumns("pipeline", ["id", "name"]) {
                let hasVersion = await db.hasColumns("pipeline", ["currentProcessorVersion"])
                for row in (try? await db.rows("SELECT id, name, \(hasVersion ? "currentProcessorVersion" : "NULL") FROM pipeline ORDER BY id")) ?? [] {
                    guard let id = row[0].int else { continue }
                    byID[id] = PipelineStat(id: id, name: row[1].string ?? "Pipeline \(id)", version: row[2].int)
                    order.append(id)
                }
            }
            if await db.hasColumns("pipeline_item", ["pipeline", "processedVersion", "hasResult", "errorCode", "deleteStatus"]) {
                let sql = """
                SELECT pipeline, count(*), sum(processedVersion IS NOT NULL), sum(coalesce(hasResult, 0) != 0),
                       sum(errorCode IS NOT NULL), sum(deleteStatus IS NOT NULL)
                FROM pipeline_item GROUP BY pipeline
                """
                for row in (try? await db.rows(sql)) ?? [] {
                    guard let id = row[0].int else { continue }
                    var stat = byID[id] ?? PipelineStat(id: id, name: "Pipeline \(id)", version: nil)
                    if byID[id] == nil { order.append(id) }
                    stat.items = Int(row[1].int ?? 0); stat.processed = Int(row[2].int ?? 0); stat.withResult = Int(row[3].int ?? 0)
                    stat.errors = Int(row[4].int ?? 0); stat.pendingDelete = Int(row[5].int ?? 0)
                    byID[id] = stat
                }
                if await db.hasColumns("pipeline_item", ["errorDomain"]) {
                    let errorSQL = "SELECT pipeline, errorDomain, errorCode, count(*) FROM pipeline_item WHERE errorCode IS NOT NULL GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 50"
                    for row in (try? await db.rows(errorSQL)) ?? [] {
                        let name = byID[row[0].int ?? -1]?.name ?? "?"
                        report.errors.append(PipelineError(pipeline: name, domain: row[1].string ?? "", code: row[2].int ?? 0, count: Int(row[3].int ?? 0)))
                    }
                }
            }
            if await db.hasColumns("destination", ["pipeline", "name", "kind"]) {
                for row in (try? await db.rows("SELECT pipeline, name, kind FROM destination")) ?? [] {
                    guard let id = row[0].int else { continue }
                    // Destination names end in a numeric source id; the kind is the readable part.
                    byID[id]?.destination = row[2].string ?? row[1].string
                }
            }
            if await db.hasColumns("item", ["source", "priorityDate"]) {
                for row in (try? await db.rows("SELECT source, count(*), min(priorityDate), max(priorityDate) FROM item GROUP BY source ORDER BY 2 DESC")) ?? [] {
                    guard let id = row[0].int else { continue }
                    var range: ClosedRange<Date>?
                    if let lo = row[2].double, let hi = row[3].double, lo > 0, hi >= lo { range = DossierDate.unix(lo)...DossierDate.unix(hi) }
                    let count = Int(row[1].int ?? 0)
                    report.sources.append(PipelineSource(id: id, items: count, range: range, label: sourceLabel(count: count, cascade: cascade)))
                    report.totalItems += count
                }
                if let main = report.sources.first {
                    report.yearsSourceLabel = main.label
                    let sql = "SELECT CAST(strftime('%Y', priorityDate, 'unixepoch', 'localtime') AS INTEGER) AS y, count(*) FROM item WHERE source = ? AND priorityDate > 0 GROUP BY y ORDER BY y"
                    for row in (try? await db.rows(sql, [.integer(main.id)])) ?? [] {
                        if let y = row[0].int, y > 1990, y < 2200 { report.years.append((Int(y), Int(row[1].int ?? 0))) }
                    }
                }
            }
            if await db.tableExists("document_store_cache") { report.documentStoreCache = await db.rowCount(of: "document_store_cache") ?? 0 }
        }

        if let cache = await SQLiteDB.sharedIfAvailable(MSPaths.cachedResultStore),
           await cache.hasColumns("pipeline", ["id", "name"]), await cache.hasColumns("cached_result", ["pipeline", "hasResult"]) {
            var names: [Int64: String] = [:]
            for row in (try? await cache.rows("SELECT id, name FROM pipeline")) ?? [] { if let id = row[0].int { names[id] = row[1].string ?? "" } }
            for row in (try? await cache.rows("SELECT pipeline, count(*), sum(hasResult != 0) FROM cached_result GROUP BY pipeline")) ?? [] {
                guard let cid = row[0].int, let name = names[cid], let id = byID.first(where: { $0.value.name == name })?.key else { continue }
                byID[id]?.cached = Int(row[1].int ?? 0)
                byID[id]?.cachedWithResult = Int(row[2].int ?? 0)
            }
            if await cache.hasColumns("cached_result_data", ["data"]),
               let blob = try? await cache.scalar("SELECT data FROM cached_result_data LIMIT 1"), let data = blob.data,
               let plist = PlistDecoder.decodePlist(data), let results = plist["results"]?.array {
                report.embeddingVectorsPerItem = results.count
                if let first = results.first {
                    report.embeddingEntityType = first["key"]?["entityType"]?.string
                    if let vector = first["vector"]?.dict?.first?.value {
                        report.embeddingDimensions = vector.array?.count ?? vector.dict?.first?.value.array?.count
                    }
                }
            }
        }
        report.pipelines = order.compactMap { byID[$0] }
        loadCompleteness(into: &report)
        return report
    }

    /// The pipeline store identifies donating sets by a numeric hash only. A source is
    /// labelled by matching its item count against the live counts of the Cascade sets.
    private static func sourceLabel(count: Int, cascade: [CascadeSetSummary]) -> String {
        if let exact = cascade.first(where: { $0.live == count && count > 0 }) { return exact.info.title }
        let close = cascade.filter { s in
            guard let live = s.live, live > 50 else { return false }
            return abs(live - count) * 50 <= live
        }.min { abs(($0.live ?? 0) - count) < abs(($1.live ?? 0) - count) }
        if let close, let live = close.live {
            // Live stores drift by a few items between two reads; larger gaps are a guess.
            return abs(live - count) * 200 <= live ? close.info.title : "Probably \(close.info.title)"
        }
        return "Unidentified source"
    }

    /// `SettingsUIPipelineCompleteness/latest.json` — what System Settings shows as
    /// "indexing progress", per donating app.
    private static func loadCompleteness(into report: inout DocumentProcessingReport) {
        guard let data = try? Data(contentsOf: MSPaths.completenessJSON, options: [.mappedIfSafe]), data.count < 8 << 20,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let last = root["lastCalculated"] as? [String: Any] else { return }
        if let stamp = last["computedAt"] as? String { report.completenessComputed = ISO8601DateFormatter().date(from: stamp) }
        report.enabledPipelines = (last["enabledPipelines"] as? [String]) ?? []
        guard let perBundle = last["perBundle"] as? [String: Any] else { return }
        for (bundle, value) in perBundle {
            guard let dict = value as? [String: Any] else { continue }
            let donation = dict["cachedDonation"] as? [String: Any]
            var eligible = 0, processed = 0
            for (_, counts) in (dict["rawCountsByPipeline"] as? [String: Any]) ?? [:] {
                guard let c = counts as? [String: Any] else { continue }
                eligible = max(eligible, (c["eligible"] as? Int) ?? 0)
                processed = max(processed, (c["processed"] as? Int) ?? 0)
            }
            report.completeness.append(BundleCompleteness(
                bundle: bundle,
                classification: (dict["classification"] as? String) ?? "",
                rank: (dict["rank"] as? String) ?? "",
                percent: (dict["percent"] as? Double) ?? 0,
                knownItems: (donation?["allKnownItems"] as? Int) ?? 0,
                needingDonation: (donation?["itemsNeedingDonation"] as? Int) ?? 0,
                eligible: eligible, processed: processed
            ))
        }
        report.completeness.sort { ($0.knownItems, $0.bundle) > ($1.knownItems, $1.bundle) }
    }
}

// MARK: - Spotlight knowledge graph (SpotlightKnowledge/index.V2/KG/kg)
//
// A small property graph in SQLite: `Node(identifier, labels, edgesIn, edgesOut)`,
// `Edge(identifier, labels, sourceNodeId, targetNodeId)`, `Label(identifier, name)`,
// `Attribute(identifier, name)`, `NodeValue` / `EdgeValue(elementId, attributeId,
// intValue, realValue, stringValue)`. `labels` is a bitset: a 24-byte header followed by
// bytes in which bit n is set when the element carries `Label.identifier == n`.
// Node attribute "value" holds the node's string; edges carry "relationship", "score"
// and "domainIdentifier". The node labelled `personUser` is the owner.

struct KGNode: Identifiable, Sendable, Hashable {
    let id: Int64
    let value: String
    let labels: [String]
    let firstName: String
    let lastName: String
    let outDegree: Int
    let inDegree: Int

    var isUser: Bool { labels.contains("personUser") }
    /// The most specific label (the generic domain / reference labels are on every node).
    var kind: String { KnowledgeGraphStore.kind(of: labels) }
}

struct KGEdge: Identifiable, Sendable, Hashable {
    let id: Int64
    let outgoing: Bool
    let relationship: String
    let score: Double?
    let domain: String
    let otherID: Int64
    let otherValue: String
    let otherKind: String
}

struct KGOverview: Sendable {
    var nodes: [KGNode] = []
    var nodeCount = 0
    var edgeCount = 0
    var labelCounts: [(label: String, count: Int)] = []
    var relationshipCounts: [(relationship: String, count: Int)] = []
    var user: KGNode?
    var truncated = false
}

enum KnowledgeGraphStore {
    static let nodeLimit = 50_000

    /// The most specific label: the generic `domain_*` label sits on every node and
    /// `referenceIdentifier` on every per-app reference.
    static func kind(of labels: [String]) -> String {
        if let specific = labels.first(where: { !$0.hasPrefix("domain_") && $0 != "referenceIdentifier" }) { return specific }
        return labels.contains("referenceIdentifier") ? "referenceIdentifier" : (labels.first ?? "")
    }

    static func labels(from blob: Data?, names: [Int: String]) -> [String] {
        guard let blob, blob.count > 24 else { return [] }
        var out: [String] = []
        let bytes = [UInt8](blob.dropFirst(24))
        for (index, byte) in bytes.enumerated() where byte != 0 {
            for bit in 0..<8 where byte & (1 << bit) != 0 {
                if let name = names[index * 8 + bit] { out.append(name) }
            }
        }
        return out
    }

    private static func open() async throws -> SQLiteDB {
        let url = MSPaths.knowledgeGraph
        switch Paths.probe(url) {
        case .missing: throw DossierError.missing("Spotlight has not built a knowledge graph on this Mac.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        default: break
        }
        guard let db = await SQLiteDB.sharedIfAvailable(url) else { throw DossierError.message("The Spotlight knowledge graph could not be opened.") }
        guard await db.hasColumns("Node", ["identifier", "labels"]), await db.hasColumns("Edge", ["identifier", "sourceNodeId", "targetNodeId"]),
              await db.hasColumns("NodeValue", ["elementId", "attributeId", "stringValue"]) else {
            throw DossierError.missing("The Spotlight knowledge graph uses a schema Dossier does not understand.")
        }
        return db
    }

    private static func names(_ db: SQLiteDB, table: String) async -> [Int: String] {
        var out: [Int: String] = [:]
        for row in (try? await db.rows("SELECT identifier, name FROM \(SQLiteDB.quote(table))")) ?? [] {
            if let id = row[0].int, let name = row[1].string { out[Int(id)] = name }
        }
        return out
    }

    private static func attributeID(_ attributes: [Int: String], _ name: String) -> Int64 {
        Int64(attributes.first { $0.value == name }?.key ?? -1)
    }

    static func overview() async throws -> KGOverview {
        let db = try await open()
        let labelNames = await names(db, table: "Label")
        let attributes = await names(db, table: "Attribute")
        let valueID = attributeID(attributes, "value"), firstID = attributeID(attributes, "firstName"), lastID = attributeID(attributes, "lastName")
        var overview = KGOverview()
        overview.nodeCount = await db.rowCount(of: "Node") ?? 0
        overview.edgeCount = await db.rowCount(of: "Edge") ?? 0
        overview.truncated = overview.nodeCount > nodeLimit

        var outDegree: [Int64: Int] = [:], inDegree: [Int64: Int] = [:]
        if overview.edgeCount <= 2_000_000 {
            for row in (try? await db.rows("SELECT sourceNodeId, count(*) FROM Edge GROUP BY 1", maxRows: 2_000_000)) ?? [] { if let id = row[0].int { outDegree[id] = Int(row[1].int ?? 0) } }
            for row in (try? await db.rows("SELECT targetNodeId, count(*) FROM Edge GROUP BY 1", maxRows: 2_000_000)) ?? [] { if let id = row[0].int { inDegree[id] = Int(row[1].int ?? 0) } }
        }
        let sql = """
        SELECT n.identifier, n.labels, v.stringValue, f.stringValue, l.stringValue FROM Node n
        LEFT JOIN NodeValue v ON v.elementId = n.identifier AND v.attributeId = ?
        LEFT JOIN NodeValue f ON f.elementId = n.identifier AND f.attributeId = ?
        LEFT JOIN NodeValue l ON l.elementId = n.identifier AND l.attributeId = ?
        ORDER BY n.identifier LIMIT ?
        """
        var counts: [String: Int] = [:]
        for row in try await db.rows(sql, [.integer(valueID), .integer(firstID), .integer(lastID), .integer(Int64(nodeLimit))]) {
            guard let id = row[0].int else { continue }
            let labels = labels(from: row[1].data, names: labelNames)
            for label in labels { counts[label, default: 0] += 1 }
            overview.nodes.append(KGNode(
                id: id, value: row[2].string ?? "", labels: labels, firstName: row[3].string ?? "", lastName: row[4].string ?? "",
                outDegree: outDegree[id] ?? 0, inDegree: inDegree[id] ?? 0
            ))
        }
        overview.labelCounts = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { (label: $0.key, count: $0.value) }
        overview.user = overview.nodes.first(where: \.isUser)
        // The owner first, then real identifiers by connectivity, per-app references last.
        overview.nodes.sort { a, b in
            if a.isUser != b.isUser { return a.isUser }
            let ra = a.kind == "referenceIdentifier", rb = b.kind == "referenceIdentifier"
            if ra != rb { return rb }
            let da = a.outDegree + a.inDegree, db = b.outDegree + b.inDegree
            return da != db ? da > db : a.id < b.id
        }
        let relID = attributeID(attributes, "relationship")
        if relID >= 0, await db.hasColumns("EdgeValue", ["elementId", "attributeId", "stringValue"]) {
            for row in (try? await db.rows("SELECT stringValue, count(*) FROM EdgeValue WHERE attributeId = ? GROUP BY 1 ORDER BY 2 DESC LIMIT 60", [.integer(relID)])) ?? [] {
                overview.relationshipCounts.append((relationship: row[0].string ?? "", count: Int(row[1].int ?? 0)))
            }
        }
        return overview
    }

    /// Edges touching one node, strongest first.
    static func edges(of node: Int64, limit: Int = 2_000) async throws -> [KGEdge] {
        let db = try await open()
        let labelNames = await names(db, table: "Label")
        let attributes = await names(db, table: "Attribute")
        let valueID = attributeID(attributes, "value"), relID = attributeID(attributes, "relationship")
        let scoreID = attributeID(attributes, "score"), domainID = attributeID(attributes, "domainIdentifier")
        let hasEdgeValues = await db.hasColumns("EdgeValue", ["elementId", "attributeId", "stringValue", "realValue"])
        func query(outgoing: Bool) async throws -> [KGEdge] {
            let other = outgoing ? "e.targetNodeId" : "e.sourceNodeId"
            let mine = outgoing ? "e.sourceNodeId" : "e.targetNodeId"
            let edgeJoins = hasEdgeValues ? """
            LEFT JOIN EdgeValue r ON r.elementId = e.identifier AND r.attributeId = \(relID)
            LEFT JOIN EdgeValue s ON s.elementId = e.identifier AND s.attributeId = \(scoreID)
            LEFT JOIN EdgeValue d ON d.elementId = e.identifier AND d.attributeId = \(domainID)
            """ : ""
            let sql = """
            SELECT e.identifier, \(other), \(hasEdgeValues ? "r.stringValue, s.realValue, d.stringValue" : "NULL, NULL, NULL"), v.stringValue, n.labels
            FROM Edge e \(edgeJoins)
            LEFT JOIN NodeValue v ON v.elementId = \(other) AND v.attributeId = \(valueID)
            LEFT JOIN Node n ON n.identifier = \(other)
            WHERE \(mine) = ? LIMIT ?
            """
            return try await db.rows(sql, [.integer(node), .integer(Int64(limit))]).map { row in
                let labels = labels(from: row[6].data, names: labelNames)
                let kind = kind(of: labels)
                return KGEdge(
                    id: row[0].int ?? 0, outgoing: outgoing, relationship: row[2].string ?? "", score: row[3].double,
                    domain: row[4].string ?? "", otherID: row[1].int ?? 0, otherValue: row[5].string ?? "", otherKind: kind
                )
            }
        }
        let outgoing = try await query(outgoing: true)
        let incoming = try await query(outgoing: false)
        let all = outgoing + incoming
        return all.sorted { ($0.score ?? 0, $1.id) > ($1.score ?? 0, $0.id) }
    }
}

// MARK: - Loose files (CoreSpotlight root and Application Support/com.apple.spotlight)

struct SpotlightFile: Identifiable, Sendable, Hashable {
    var id: String { url.path }
    let url: URL
    let group: String
    let name: String
    let explanation: String
    let bytes: Int64
    let modified: Date?
}

enum SpotlightFiles {
    /// Small property-list / JSON files worth reading as-is, plus index directory sizes.
    static func list() -> [SpotlightFile] {
        var out: [SpotlightFile] = []
        let fm = FileManager.default
        func add(_ url: URL, group: String, _ explanation: String) {
            guard let info = FileProbe.info(url), !info.isDirectory else { return }
            out.append(SpotlightFile(url: url, group: group, name: url.lastPathComponent, explanation: explanation, bytes: info.size, modified: info.modified))
        }
        let cs = MSPaths.coreSpotlight
        for protection in ["Priority", "NSFileProtectionComplete", "NSFileProtectionCompleteUnlessOpen", "NSFileProtectionCompleteUntilFirstUserAuthentication"] {
            add(cs.appendingPathComponent("\(protection)/meCardInfo.plist"), group: "Identity", "What the Spotlight index recorded about your own contact card (\(protection)).")
        }
        add(cs.appendingPathComponent("PersonaList.plist"), group: "Identity", "User personas known to the Spotlight index.")
        add(Paths.spotlightKnowledge.appendingPathComponent("index.V2/kg_config.mdplist"), group: "Identity", "Configuration of the Spotlight knowledge graph.")
        add(cs.appendingPathComponent("heartbeat.plist"), group: "Index Health", "Counters of the app-content index: documents, journal sizes, merges, drops.")
        add(cs.appendingPathComponent("IndexDropReports/spotlight_heartbeat_last.plist"), group: "Index Health", "The previous heartbeat report.")
        add(cs.appendingPathComponent("FileProviderDomains.plist"), group: "Index Health", "File-provider domains registered with the index.")
        for name in ["suggestions", "photos", "textunderstandingd", "coreduet"] {
            add(cs.appendingPathComponent("com.apple.corespotlight.receiver.\(name).plist"), group: "Receivers", "Progress bookmark of the \(name) index receiver — which donations it has consumed.")
        }
        add(MSPaths.completenessJSON, group: "Document Processing", "Per-app indexing completeness as shown in System Settings.")
        add(MSPaths.pipelineStorage.appendingPathComponent("DeadReckoning.json"), group: "Document Processing", "Recent eligible / processed deltas per app and pipeline.")
        for url in ((try? fm.contentsOfDirectory(at: cs.appendingPathComponent("PipelineCompletenessReporting"), includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "plist" {
            add(url, group: "Completeness Reports", "Archived completeness report of one pipeline (per app: eligible items and completeness buckets).")
        }
        let app = MSPaths.spotlightAppSupport
        add(app.appendingPathComponent("appList.dat"), group: "Spotlight App", "Spotlight's cached list of launchable apps.")
        add(app.appendingPathComponent("parsecResources.plist"), group: "Spotlight App", "State of resources downloaded for Spotlight suggestions.")
        if let reports = try? fm.subpathsOfDirectory(atPath: app.appendingPathComponent("CandidateReports").path) {
            for path in reports.sorted().suffix(20) where path.hasSuffix(".json") {
                add(app.appendingPathComponent("CandidateReports").appendingPathComponent(path), group: "Spotlight App", "Engagement report: which result you picked for a query and which candidates were shown but ignored (no query text).")
            }
        }
        return out
    }

    /// Decoded tree of one of the files above (bounded size).
    static func tree(_ file: SpotlightFile) throws -> [DataNode] {
        guard file.bytes <= 16 << 20 else { throw DossierError.message("This file is too large to preview (\(Format.bytes(file.bytes))).") }
        let data: Data
        do { data = try Data(contentsOf: file.url, options: [.mappedIfSafe]) } catch {
            throw DossierError.inaccessible(error.localizedDescription)
        }
        if let plist = PlistDecoder.decodeAny(data) { return [DataNode.from(plist, key: file.name)] }
        if let json = PlistDecoder.decodeJSON(data) { return [DataNode.from(json, key: file.name)] }
        throw DossierError.message("This file is not a property list or JSON document.")
    }

    /// Sizes of the Spotlight app-content index directories, per data-protection class.
    static func indexDirectories() -> [(name: String, bytes: Int64, files: Int)] {
        let cs = MSPaths.coreSpotlight
        return ["Priority", "NSFileProtectionComplete", "NSFileProtectionCompleteUnlessOpen", "NSFileProtectionCompleteUntilFirstUserAuthentication"].compactMap { name in
            let dir = cs.appendingPathComponent("\(name)/index.spotlightV3")
            guard Paths.probe(dir).isAvailable else { return nil }
            let size = FileProbe.directorySize(dir, maxFiles: 100_000)
            return (name, size.bytes, size.files)
        }
    }
}
