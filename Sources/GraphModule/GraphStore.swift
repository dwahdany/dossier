import Foundation
import DossierCore

// MARK: - Paths

enum GraphPaths {
    static var root: URL { Paths.intelligencePlatform }
    static var graph: URL { Paths.graphDB }
    static var ontology: URL { Paths.ontologyDB }
    static var artifacts: URL { Paths.intelligencePlatformArtifacts }
    static func artifact(_ relative: String) -> URL { artifacts.appendingPathComponent(relative) }
    static func rootFile(_ name: String) -> URL { root.appendingPathComponent(name) }

    static var entityTagging: URL { artifact("entityTagging/entityTagging.db") }
    static var importance: URL { artifact("entityRelevance/entityImportanceSignals.db") }
    static var relevance: URL { artifact("entityRelevance/entityRelevanceInferences.db") }
    static var features: URL { artifact("feature/features.db") }
    static var internalViews: URL { artifact("internal/views.db") }
    static var inferredTriples: URL { artifact("internal/inferred_triples.db") }
    static var ecr: URL { artifact("ecr/views.db") }
    static var sourceConfidence: URL { artifact("confidenceService/sourceConfidence.db") }
    static var views: URL { rootFile("views.db") }
    static var keyvalue: URL { rootFile("keyvalue.db") }
    static var aliases: URL { rootFile("aliases.db") }
    static var globalKnowledge: URL { rootFile("globalKnowledge.db") }

    /// Opens a store, translating "missing" / "no access" into placeholder errors.
    static func open(_ url: URL) async throws -> SQLiteDB {
        switch Paths.probe(url) {
        case .missing: throw DossierError.missing("\(url.lastPathComponent) does not exist on this Mac.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        return try await SQLiteDB.shared(url)
    }

    static func openIfAvailable(_ url: URL) async -> SQLiteDB? {
        guard Paths.probe(url).isAvailable else { return nil }
        return try? await SQLiteDB.shared(url)
    }
}

// MARK: - Index

/// Compact, immutable in-memory index of the graph's nodes and node → node links: one
/// small record per node (never the triples themselves). Built with streaming aggregate
/// queries; node count is capped so a pathological store cannot exhaust memory.
final class GraphIndex: Sendable {
    let entities: [Int64: EntityInfo]
    /// Stable display order: owner first, then by kind and name.
    let ordered: [EntityInfo]
    let ownerID: Int64?
    let edges: [GraphEdge]
    let sources: SourceCatalog
    let ontology: Ontology
    let stableRows: Int
    let truncated: Bool

    static let maxEntities = 250_000

    init(entities: [Int64: EntityInfo], ownerID: Int64?, edges: [GraphEdge], sources: SourceCatalog, ontology: Ontology, stableRows: Int, truncated: Bool) {
        self.entities = entities
        self.ownerID = ownerID
        self.edges = edges
        self.sources = sources
        self.ontology = ontology
        self.stableRows = stableRows
        self.truncated = truncated
        self.ordered = entities.values.sorted { a, b in
            if a.isOwner != b.isOwner { return a.isOwner }
            if a.kind != b.kind { return (EntityKind.allCases.firstIndex(of: a.kind) ?? 0) < (EntityKind.allCases.firstIndex(of: b.kind) ?? 0) }
            // Nodes known only by a number or handle sort after properly named ones.
            let la = a.name.first?.isLetter == true && !a.name.contains("@"), lb = b.name.first?.isLetter == true && !b.name.contains("@")
            if la != lb { return la }
            let c = a.name.localizedCaseInsensitiveCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.id < b.id
        }
    }

    func name(_ id: Int64) -> String? { entities[id]?.name }
    var owner: EntityInfo? { ownerID.flatMap { entities[$0] } }

    func count(_ kind: EntityKind) -> Int { ordered.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) } }

    func display(_ object: String, predicate: String) -> String {
        GraphFormat.display(object, predicate: predicate, ontology: ontology, name: { self.name($0) })
    }
}

private struct IndexBuilder: Sendable {
    struct Node: Sendable {
        var classID = ""
        var classConfidence = 0.0
        var sources: Int64 = 0
        var updated = 0.0
        var names: [(text: String, score: Double)] = []
        var first: String?
        var family: String?
        var bundle: String?
        var street: String?
        var city: String?
        var country: String?
        var email: String?
        var phone: String?
        var isOwner = false
    }
    var nodes: [Int64: Node] = [:]
    var overflow = false
}

// MARK: - Entity detail

struct EntityDetail: Sendable {
    let info: EntityInfo
    let statements: [Statement]
    /// Rows in the graph whose object references this node.
    let incoming: [Triple]
    let expired: [Triple]
    let fromEventGraph: Bool
    /// Distinct source records (`PS102` + `sourceDuplicates`).
    let sourceRecords: [String]
}

// MARK: - Store

/// All data access for the Knowledge Graph module. Everything is read-only, asynchronous
/// and off the main actor (SQLiteDB runs queries on its own queue; this actor only
/// serialises cache bookkeeping).
actor GraphStore {
    static let shared = GraphStore()

    private var token = Int.min
    private var indexTask: Task<GraphIndex, Error>?
    private var eventsTask: Task<[EventInfo], Error>?
    private var ontologyTask: Task<Ontology, Never>?

    /// Drops caches when the app's refresh token changes.
    func sync(token newToken: Int) {
        guard newToken != token else { return }
        if token != Int.min {
            indexTask = nil; eventsTask = nil; ontologyTask = nil
        }
        token = newToken
    }

    func invalidate() { indexTask = nil; eventsTask = nil; ontologyTask = nil }

    // MARK: Ontology

    func ontology() async -> Ontology {
        if let task = ontologyTask { return await task.value }
        let task = Task<Ontology, Never> { await Self.loadOntology() }
        ontologyTask = task
        return await task.value
    }

    private static func loadOntology() async -> Ontology {
        var result = Ontology()
        guard let db = await GraphPaths.openIfAvailable(GraphPaths.ontology) else { return result }
        if await db.hasColumns("class", ["id", "label"]), let rows = try? await db.rows("SELECT id, label FROM class") {
            for r in rows { if let id = r[0].string { result.classLabels[id] = r[1].string ?? "" } }
        }
        if await db.hasColumns("predicate", ["id", "label"]), let rows = try? await db.rows("SELECT id, label FROM predicate") {
            for r in rows { if let id = r[0].string { result.predicateLabels[id] = r[1].string ?? "" } }
        }
        return result
    }

    // MARK: Index

    func index() async throws -> GraphIndex {
        if let task = indexTask {
            do { return try await task.value } catch { if indexTask == task { indexTask = nil }; throw error }
        }
        let ontologyValue = await ontology()
        let task = Task<GraphIndex, Error> { try await Self.buildIndex(ontology: ontologyValue) }
        indexTask = task
        do { return try await task.value } catch { if indexTask == task { indexTask = nil }; throw error }
    }

    static let graphColumns = ["subject", "predicate", "relationshipId", "relationshipPredicate", "object", "sources", "confidence", "sourceDuplicates", "timestamp"]

    private static func buildIndex(ontology: Ontology) async throws -> GraphIndex {
        let db = try await GraphPaths.open(GraphPaths.graph)
        guard await db.hasColumns("stable_graph", graphColumns) else {
            throw DossierError.missing("graph.db has no stable_graph table with the expected columns on this macOS version.")
        }

        // 1. Naming / classification rows only (a handful of predicates), streamed.
        let wanted = [P.isA, P.name, P.firstName, P.familyName, P.bundleID, P.currentUser, P.address, P.contact]
        let placeholders = wanted.map { _ in "?" }.joined(separator: ",")
        let cap = GraphIndex.maxEntities
        let builder = try await db.reduce(
            "SELECT subject, predicate, relationshipPredicate, object, sources, confidence, timestamp FROM stable_graph WHERE predicate IN (\(placeholders))",
            wanted.map { SQLValue.text($0) }, into: IndexBuilder()
        ) { acc, row in
            guard let subject = row[0].int, let predicate = row[1].string, let object = row[3].string else { return }
            if acc.nodes[subject] == nil {
                if acc.nodes.count >= cap { acc.overflow = true; return }
                acc.nodes[subject] = IndexBuilder.Node()
            }
            let rel = row[2].string ?? ""
            let sources = row[4].int ?? 0
            let confidence = row[5].double ?? 0
            acc.nodes[subject]!.updated = max(acc.nodes[subject]!.updated, row[6].double ?? 0)
            switch (predicate, rel) {
            case (P.isA, ""):
                acc.nodes[subject]!.classID = object
                acc.nodes[subject]!.classConfidence = confidence
                acc.nodes[subject]!.sources |= sources
            case (P.name, ""):
                // Prefer confident, multi-source, human-looking names over handles.
                var score = confidence + Double(sources.nonzeroBitCount) * 0.05
                if object.contains("@") { score -= 1 }
                if object.contains(" ") { score += 0.1 }
                if object.first?.isUppercase == true { score += 0.05 }
                acc.nodes[subject]!.names.append((object, score))
            case (P.firstName, ""):
                if acc.nodes[subject]!.first == nil || (!object.contains("@") && object.first?.isUppercase == true) { acc.nodes[subject]!.first = object }
            case (P.familyName, ""): acc.nodes[subject]!.family = object
            case (P.bundleID, ""): acc.nodes[subject]!.bundle = object
            case (P.currentUser, ""): acc.nodes[subject]!.isOwner = true
            case (P.address, P.street): acc.nodes[subject]!.street = object
            case (P.address, P.city): acc.nodes[subject]!.city = object
            case (P.address, P.country): acc.nodes[subject]!.country = object
            case (P.contact, P.email): if acc.nodes[subject]!.email == nil || object < acc.nodes[subject]!.email! { acc.nodes[subject]!.email = object }
            case (P.contact, P.phone): if acc.nodes[subject]!.phone == nil || object < acc.nodes[subject]!.phone! { acc.nodes[subject]!.phone = object }
            default: break
            }
        }

        // 2. Row counts per node.
        let counts = try await db.reduce("SELECT subject, count(*) FROM stable_graph GROUP BY subject", into: [Int64: Int]()) { acc, row in
            if let s = row[0].int, acc.count < cap { acc[s] = Int(row[1].int ?? 0) }
        }

        // 3. Node → node links (range scan on the object index: 'md:' ≤ object < 'md;').
        let edgeList = try await db.reduce(
            "SELECT subject, predicate, relationshipPredicate, object FROM stable_graph WHERE object >= 'md:' AND object < 'md;'",
            into: [GraphEdge]()
        ) { acc, row in
            guard acc.count < 2_000_000, let s = row[0].int, let p = row[1].string, let o = row[3].string, let target = GraphRef.parse(o) else { return }
            acc.append(GraphEdge(from: s, to: target, predicate: p, relPredicate: row[2].string ?? ""))
        }

        // 4. Source bit names: rows carrying exactly one source bit name their record kind.
        var catalog = SourceCatalog()
        for table in ["stable_graph", "event_graph"] where await db.hasColumns(table, ["sources", "sourceDuplicates"]) {
            // Records without a "<kind>:" prefix (bare identifiers) are skipped by the GLOB.
            let rows = (try? await db.rows("SELECT sources, min(sourceDuplicates) FROM \(table) WHERE sources > 0 AND (sources & (sources - 1)) = 0 AND sourceDuplicates GLOB '[a-zA-Z]*:*' GROUP BY sources")) ?? []
            for r in rows {
                guard let mask = r[0].int, mask > 0, let dup = r[1].string else { continue }
                let bit = mask.trailingZeroBitCount
                if catalog.kinds[bit] == nil, let kind = SourceRecord.split(dup).lazy.compactMap(SourceRecord.kind).first {
                    catalog.kinds[bit] = kind
                }
            }
        }
        // Bits that never occur alone: a row whose kinds and bits each leave exactly one
        // unknown identifies the remaining pair.
        if let rows = try? await db.rows("SELECT sources, sourceDuplicates FROM stable_graph WHERE (sources & (sources - 1)) != 0 GROUP BY sources LIMIT 500") {
            for _ in 0..<3 {
                var progressed = false
                for r in rows {
                    guard let mask = r[0].int, let dup = r[1].string else { continue }
                    let unknownBits = catalog.bits(of: mask).filter { catalog.kinds[$0] == nil }
                    let knownKinds = Set(catalog.kinds.values)
                    let unknownKinds = Set(SourceRecord.split(dup).compactMap(SourceRecord.kind)).subtracting(knownKinds)
                    if unknownBits.count == 1, unknownKinds.count == 1, let kind = unknownKinds.first {
                        catalog.kinds[unknownBits[0]] = kind
                        progressed = true
                    }
                }
                if !progressed { break }
            }
        }

        // Assemble.
        var entities: [Int64: EntityInfo] = [:]
        entities.reserveCapacity(builder.nodes.count)
        var ownerID: Int64?
        for (id, node) in builder.nodes {
            let label = ontology.classLabels[node.classID]
            let kind = EntityKind.from(classID: node.classID, label: label)
            var name = node.names.max { $0.score < $1.score }?.text ?? ""
            if name.isEmpty {
                let parts = [node.first, node.family].compactMap { $0 }.filter { !$0.isEmpty }
                name = parts.joined(separator: " ")
            }
            var detail = ""
            switch kind {
            case .software:
                if name.isEmpty { name = node.bundle ?? "" }
                detail = node.bundle ?? ""
            case .place:
                let parts = [node.street, node.city, node.country].compactMap { $0 }.filter { !$0.isEmpty }
                if name.isEmpty { name = parts.joined(separator: ", ") } else { detail = parts.joined(separator: ", ") }
            default:
                // People known only by a handle (calendar attendees) are named by it.
                let handle = node.email ?? node.phone ?? ""
                if name.isEmpty { name = handle } else { detail = handle }
            }
            if name.isEmpty {
                // Name unnamed nodes after their class and, if unambiguous, their source system.
                let systems = catalog.bits(of: node.sources)
                if node.classID.isEmpty { name = "Unnamed node" }
                else if kind != .person, systems.count == 1, catalog.kinds[systems[0]] != nil { name = "\((label ?? node.classID).capitalized) (\(catalog.title(bit: systems[0])))" }
                else { name = "Unnamed \(label ?? node.classID)" }
            }
            if node.isOwner { ownerID = id }
            entities[id] = EntityInfo(
                id: id, classID: node.classID, kind: kind, name: name, detail: detail,
                rowCount: counts[id] ?? 0, sources: node.sources, confidence: node.classConfidence,
                updated: node.updated, isOwner: node.isOwner)
        }
        // Nodes without a class row still exist as subjects.
        for (id, n) in counts where entities[id] == nil && entities.count < cap {
            entities[id] = EntityInfo(id: id, classID: "", kind: .other, name: "Unclassified node", detail: "", rowCount: n, sources: 0, confidence: 0, updated: 0, isOwner: false)
        }
        // De-duplicate links per (from, to, predicate) and count degrees.
        var seen = Set<GraphEdge>()
        var edges: [GraphEdge] = []
        for e in edgeList where seen.insert(e).inserted {
            edges.append(e)
            entities[e.from]?.outgoing += 1
            entities[e.to]?.incoming += 1
        }
        let total = counts.values.reduce(0, +)
        return GraphIndex(entities: entities, ownerID: ownerID, edges: edges, sources: catalog, ontology: ontology, stableRows: total, truncated: builder.overflow)
    }

    // MARK: Triples

    static func triple(_ r: SQLRow) -> Triple? {
        guard let subject = r[0].int, let predicate = r[1].string else { return nil }
        return Triple(
            subject: subject, predicate: predicate, relationshipId: r[2].int ?? 0, relPredicate: r[3].string ?? "",
            object: r[4].string ?? "", sources: r[5].int ?? 0, confidence: r[6].double ?? 0,
            sourceDuplicates: r[7].string ?? "", timestamp: r[8].double ?? 0)
    }

    static let selectTriple = "SELECT subject, predicate, relationshipId, relationshipPredicate, object, sources, confidence, sourceDuplicates, timestamp FROM "

    /// All rows of one node (primary-key prefix lookup).
    func triples(subject: Int64, table: String = "stable_graph", limit: Int = 20_000) async throws -> [Triple] {
        let db = try await GraphPaths.open(GraphPaths.graph)
        guard await db.hasColumns(table, Self.graphColumns) else { return [] }
        let rows = try await db.rows(Self.selectTriple + SQLiteDB.quote(table) + " WHERE subject = ? ORDER BY predicate, relationshipId, relationshipPredicate LIMIT ?", [.integer(subject), .integer(Int64(limit))])
        return rows.compactMap(Self.triple)
    }

    func detail(id: Int64) async throws -> EntityDetail {
        let index = try await index()
        let db = try await GraphPaths.open(GraphPaths.graph)
        var table = "stable_graph"
        var rows = try await triples(subject: id)
        var info = index.entities[id]
        if rows.isEmpty {
            rows = try await triples(subject: id, table: "event_graph")
            table = "event_graph"
        }
        if info == nil {
            let classID = rows.first { $0.predicate == P.isA && $0.relPredicate.isEmpty }?.object ?? ""
            let name = rows.first { $0.predicate == P.name && $0.relPredicate.isEmpty }?.object ?? "Node \(id)"
            info = EntityInfo(
                id: id, classID: classID, kind: EntityKind.from(classID: classID, label: index.ontology.classLabels[classID]),
                name: name, detail: "", rowCount: rows.count, sources: rows.reduce(0) { $0 | $1.sources },
                confidence: rows.first?.confidence ?? 0, updated: rows.map(\.timestamp).max() ?? 0, isOwner: false)
        }
        let ref = GraphRef.string(id)
        var incoming: [Triple] = []
        for t in ["stable_graph", "event_graph"] where await db.hasColumns(t, Self.graphColumns) {
            let r = try await db.rows(Self.selectTriple + t + " WHERE object = ? LIMIT 500", [.text(ref)])
            incoming += r.compactMap(Self.triple)
        }
        var expired: [Triple] = []
        let expiredTable = "expired_" + table
        if await db.hasColumns(expiredTable, Self.graphColumns) {
            let r = try await db.rows(Self.selectTriple + expiredTable + " WHERE subject = ? ORDER BY timestamp DESC LIMIT 1000", [.integer(id)])
            expired = r.compactMap(Self.triple)
        }
        var records: [String] = []
        var seen = Set<String>()
        for t in rows {
            if t.predicate == P.sameAs, seen.insert(t.object).inserted { records.append(t.object) }
        }
        for t in rows { for rec in SourceRecord.split(t.sourceDuplicates) where seen.insert(rec).inserted { records.append(rec) } }
        return EntityDetail(info: info!, statements: Statement.group(rows), incoming: incoming, expired: expired, fromEventGraph: table == "event_graph", sourceRecords: records)
    }

    // MARK: Counts for summary / self-test

    struct Counts: Sendable {
        var stable = 0, event = 0, expiredStable = 0, expiredEvent = 0
        var nodes = 0, eventNodes = 0
        var range: ClosedRange<Date>?
    }

    func counts() async -> Counts? {
        guard let db = await GraphPaths.openIfAvailable(GraphPaths.graph) else { return nil }
        var c = Counts()
        c.stable = await db.rowCount(of: "stable_graph") ?? 0
        c.event = await db.rowCount(of: "event_graph") ?? 0
        c.expiredStable = await db.rowCount(of: "expired_stable_graph") ?? 0
        c.expiredEvent = await db.rowCount(of: "expired_event_graph") ?? 0
        c.nodes = await db.count("SELECT count(DISTINCT subject) FROM stable_graph") ?? 0
        c.eventNodes = await db.count("SELECT count(DISTINCT subject) FROM event_graph") ?? 0
        var lo: Double?, hi: Double?
        for t in ["stable_graph", "event_graph"] {
            if let r = try? await db.first("SELECT min(timestamp), max(timestamp) FROM \(t)") {
                if let a = r[0].double, a > 0 { lo = Swift.min(lo ?? a, a) }
                if let b = r[1].double, b > 0 { hi = Swift.max(hi ?? b, b) }
            }
        }
        if let lo, let hi, lo <= hi { c.range = DossierDate.cocoa(lo)...DossierDate.cocoa(hi) }
        return c
    }

    // MARK: Events

    func events() async throws -> [EventInfo] {
        if let task = eventsTask {
            do { return try await task.value } catch { if eventsTask == task { eventsTask = nil }; throw error }
        }
        let index = try await index()
        let task = Task<[EventInfo], Error> { try await EventInfo.load(index: index) }
        eventsTask = task
        do { return try await task.value } catch { if eventsTask == task { eventsTask = nil }; throw error }
    }
}
