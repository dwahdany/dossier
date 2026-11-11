import SwiftUI
import DossierCore

/// Knowledge Graph — the personal knowledge graph kept by IntelligencePlatform
/// (`~/Library/IntelligencePlatform`): a triple store of people, apps, places,
/// organizations and calendar events merged from Contacts, Photos, Calendar, Family
/// Sharing and Launch Services, plus the views and inferences derived from it.
///
/// Files: `GraphModels` (triples, statements, formatting), `GraphStore` (index + queries),
/// `DerivedStore` (artifact databases), one file per section, `GraphLayout` (force layout).
public final class GraphModule: DossierModule {
    public let id = "graph"
    public let title = "Knowledge Graph"
    public let symbol = "point.3.connected.trianglepath.dotted"
    public let group = SidebarGroup.identity

    public init() {}

    public var sections: [ModuleSection] {
        [
            ModuleSection(id: "graph.me", title: "Me", symbol: "person.crop.circle") { MeSection() },
            ModuleSection(id: "graph.entities", title: "Entities", symbol: "circle.grid.cross") { EntitiesSection() },
            ModuleSection(id: "graph.people", title: "People & Relationships", symbol: "person.2") { PeopleSection() },
            ModuleSection(id: "graph.view", title: "Graph View", symbol: "point.3.connected.trianglepath.dotted") { GraphViewSection() },
            ModuleSection(id: "graph.events", title: "Events", symbol: "calendar") { EventsSection() },
            ModuleSection(id: "graph.derived", title: "Derived Views & Inferences", symbol: "wand.and.stars") { DerivedSection() },
            ModuleSection(id: "graph.ontology", title: "Ontology", symbol: "list.bullet.indent") { OntologySection() },
        ]
    }

    // MARK: Summary

    public func summary() async -> ModuleSummary {
        var graph = StoreInfo.file("graph.db", GraphPaths.graph, note: "Personal knowledge graph (stable_graph, event_graph)")
        var ontology = StoreInfo.file("ontology.db", GraphPaths.ontology, note: "Vocabulary: classes and predicates (generic)")
        var artifacts = StoreInfo(name: "Artifacts", path: GraphPaths.artifacts, availability: Paths.probe(GraphPaths.artifacts), note: "Derived views: relationship model, relevance, features, aliases")
        if artifacts.availability.isAvailable {
            artifacts.sizeBytes = FileProbe.directorySize(GraphPaths.artifacts, maxFiles: 5_000).bytes
        }
        let views = StoreInfo.file("views.db", GraphPaths.views, note: "View engine state")
        var keyvalue = StoreInfo.file("keyvalue.db", GraphPaths.keyvalue, note: "Pipeline bookkeeping")
        var aliases = StoreInfo.file("aliases.db", GraphPaths.aliases, note: "Relationship words (generic)")
        var global = StoreInfo.file("globalKnowledge.db", GraphPaths.globalKnowledge, note: "Apple world knowledge (generic)")
        var facts: [Fact] = []

        if let counts = await GraphStore.shared.counts() {
            graph.rowCount = counts.stable + counts.event
            graph.timeRange = counts.range
            if let index = try? await GraphStore.shared.index() {
                let parts = EntityKind.allCases.compactMap { kind -> String? in
                    let n = index.count(kind)
                    return n > 0 ? "\(Format.count(n)) \(kind.title.lowercased())" : nil
                }
                facts.append(Fact("Nodes in your knowledge graph", "\(Format.count(index.entities.count)) — \(parts.joined(separator: ", "))", sensitivity: .personal, symbol: "circle.grid.cross", sectionID: "graph.entities"))
                if let owner = index.owner {
                    let systems = index.sources.titles(mask: owner.sources)
                    facts.append(Fact("Your identity node", "\(Format.count(owner.rowCount)) facts merged from \(systems.joined(separator: ", "))", sensitivity: .personal, symbol: "person.crop.circle", sectionID: "graph.me"))
                    if let profile = try? await MeProfile.load() {
                        facts.append(Fact("Ways the system can refer to you", "\(profile.names.count) names, \(profile.aliases.count) aliases, \(profile.handles.count) handles", sensitivity: .personal, symbol: "textformat", sectionID: "graph.me"))
                        if !profile.relationships.isEmpty {
                            let people = Set(profile.relationships.compactMap(\.reference)).count
                            facts.append(Fact("Relationships recorded for you", "\(profile.relationships.count) labels toward \(people) nodes (\(Set(profile.relationships.compactMap(\.tag)).sorted().joined(separator: ", ")))", sensitivity: .sensitive, symbol: "heart", sectionID: "graph.people"))
                        }
                        if !profile.languages.isEmpty {
                            facts.append(Fact("Languages inferred", profile.languages.joined(separator: ", "), sensitivity: .personal, symbol: "character.bubble", sectionID: "graph.derived"))
                        }
                    }
                }
            }
            if counts.eventNodes > 0 {
                facts.append(Fact("Calendar events mirrored into the graph", "\(Format.count(counts.eventNodes)) events (\(Format.count(counts.event)) rows)", sensitivity: .personal, symbol: "calendar", sectionID: "graph.events"))
            }
            if counts.expiredStable + counts.expiredEvent > 0 {
                facts.append(Fact("Superseded facts still kept", Format.count(counts.expiredStable + counts.expiredEvent), sensitivity: .low, symbol: "clock.arrow.circlepath", sectionID: "graph.entities"))
            }
        }
        if let n = await DerivedStore.rowCount(GraphPaths.entityTagging, "entity_tagging"), n > 0 {
            facts.append(Fact("People with an inferred relationship model", "\(Format.count(n)) (probability of mother, partner, coworker, … per person)", sensitivity: .personal, symbol: "person.2", sectionID: "graph.people"))
        }
        if let db = await GraphPaths.openIfAvailable(GraphPaths.ontology) {
            ontology.rowCount = (await db.rowCount(of: "class") ?? 0) + (await db.rowCount(of: "predicate") ?? 0)
        }
        keyvalue.rowCount = await DerivedStore.rowCount(GraphPaths.keyvalue, "keyvalue")
        aliases.rowCount = await DerivedStore.rowCount(GraphPaths.aliases, "aliases")
        global.rowCount = await DerivedStore.rowCount(GraphPaths.globalKnowledge, "static_graph")
        return ModuleSummary(stores: [graph, ontology, artifacts, views, keyvalue, aliases, global], facts: facts)
    }

    // MARK: Search

    public func search(_ query: String, limit: Int) async -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2, limit > 0, let index = try? await GraphStore.shared.index() else { return [] }
        var hits: [SearchHit] = []
        var seen = Set<Int64>()

        // 1. Node names.
        for e in index.ordered {
            if Task.isCancelled || hits.count >= limit { return hits }
            guard e.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
            seen.insert(e.id)
            hits.append(SearchHit(
                id: "graph.entity.\(e.id)", title: e.name,
                subtitle: "\(index.ontology.classLabel(e.classID).capitalized) node\(e.isOwner ? " — you" : "") · \(Format.count(e.rowCount)) facts",
                moduleID: id, sectionID: "graph.entities", payload: "entity:\(e.id)", symbol: e.kind.symbol, sensitivity: .sensitive))
        }
        // 2. Events by title.
        if hits.count < limit, let events = try? await GraphStore.shared.events() {
            for e in events where e.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                if hits.count >= limit { break }
                hits.append(SearchHit(
                    id: "graph.event.\(e.id)", title: e.title, subtitle: "Calendar event in the graph · \(e.startText)",
                    moduleID: id, sectionID: "graph.events", payload: "event:\(e.id)", symbol: "calendar", sensitivity: .sensitive))
            }
        }
        // 3. Any stored value (e-mail, phone, alias, bundle id, …).
        if hits.count < limit, !Task.isCancelled, let db = await GraphPaths.openIfAvailable(GraphPaths.graph), await db.tableExists("stable_graph") {
            let pattern = "%" + GraphSearch.escapeLike(needle) + "%"
            let rows = (try? await db.rows(
                "SELECT subject, predicate, relationshipPredicate, object FROM stable_graph WHERE object LIKE ? ESCAPE '\\' AND object NOT LIKE 'md:%' LIMIT ?",
                [.text(pattern), .integer(Int64(limit * 6))])) ?? []
            for r in rows {
                if Task.isCancelled || hits.count >= limit { break }
                guard let subject = r[0].int, seen.insert(subject).inserted else { continue }
                let field = (r[2].string ?? "").isEmpty ? (r[1].string ?? "") : (r[2].string ?? "")
                let e = index.entities[subject]
                hits.append(SearchHit(
                    id: "graph.value.\(subject)", title: e?.name ?? "Graph node",
                    subtitle: "\(index.ontology.predicateLabel(field)): \(Format.oneLine(index.display(r[3].string ?? "", predicate: field), max: 80))",
                    moduleID: id, sectionID: "graph.entities", payload: "entity:\(subject)", symbol: (e?.kind ?? .other).symbol, sensitivity: .sensitive))
            }
        }
        return hits
    }

    // MARK: Self-test

    public func selfTest() async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        func timed<T>(_ work: () async throws -> T) async rethrows -> (T, String) {
            let start = Date()
            let value = try await work()
            return (value, String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000))
        }

        // graph.db
        let availability = Paths.probe(GraphPaths.graph)
        switch availability {
        case .available: lines.append(.pass("graph.db readable", Format.bytes(FileProbe.databaseSize(GraphPaths.graph))))
        case .missing: lines.append(.warn("graph.db", "not present on this Mac")); return lines + (await artifactLines())
        case .inaccessible(let reason): lines.append(.warn("graph.db", "no access: \(reason)")); return lines
        }
        guard let db = await GraphPaths.openIfAvailable(GraphPaths.graph) else {
            lines.append(.fail("graph.db open", "could not open read-only"))
            return lines
        }
        for table in ["stable_graph", "event_graph", "expired_stable_graph", "expired_event_graph"] {
            let ok = await db.hasColumns(table, GraphStore.graphColumns)
            let n = await db.rowCount(of: table)
            lines.append(ok ? .pass("graph.db › \(table)", "\(Format.count(n)) rows") : .warn("graph.db › \(table)", "missing or schema changed"))
        }
        if let counts = await GraphStore.shared.counts() {
            lines.append(.info("graph.db time range", DossierDate.range(counts.range)))
            lines.append(.info("graph.db nodes", "\(Format.count(counts.nodes)) stable subjects, \(Format.count(counts.eventNodes)) event subjects"))
        }
        do {
            let (index, t) = try await timed { try await GraphStore.shared.index() }
            lines.append(.pass("node index built", "\(Format.count(index.entities.count)) nodes, \(Format.count(index.edges.count)) links in \(t)"))
            let distinct = await db.count("SELECT count(DISTINCT subject) FROM stable_graph") ?? -1
            lines.append(.check("index node count = count(DISTINCT subject)", index.entities.count == distinct, "\(index.entities.count) vs \(distinct)"))
            let stable = await db.rowCount(of: "stable_graph") ?? -1
            lines.append(.check("index row total = stable_graph rows", index.stableRows == stable, "\(index.stableRows) vs \(stable)"))
            let breakdown = EntityKind.allCases.compactMap { k -> String? in let n = index.count(k); return n > 0 ? "\(k.rawValue) \(n)" : nil }
            lines.append(.info("node classes", breakdown.joined(separator: ", ")))
            let bits = index.sources.kinds.keys.sorted().map { "bit \($0) = \(index.sources.kinds[$0] ?? "?")" }
            lines.append(bits.isEmpty ? .warn("source bits", "none derivable") : .pass("source bits derived from sourceDuplicates", bits.joined(separator: ", ")))
            if let owner = index.owner {
                let (detail, t2) = try await timed { try await GraphStore.shared.detail(id: owner.id) }
                let direct = await db.count("SELECT count(*) FROM stable_graph WHERE subject = ?", [.integer(owner.id)]) ?? -1
                lines.append(.check("owner node (nm_isCurrentUser)", owner.rowCount == direct, "\(owner.rowCount) rows → \(detail.statements.count) statements, \(detail.incoming.count) incoming refs, \(detail.expired.count) superseded, \(detail.sourceRecords.count) source records (\(t2))"))
                let regrouped = detail.statements.reduce(0) { $0 + ($1.isFacet ? $1.fields.count + ($1.typeClass == nil ? 0 : 1) : 1) }
                lines.append(.check("statement grouping is lossless", regrouped == direct, "\(regrouped) rows regrouped vs \(direct)"))
            } else {
                lines.append(.warn("owner node", "no nm_isCurrentUser row"))
            }
            let (events, t3) = try await timed { try await GraphStore.shared.events() }
            let eventSubjects = await db.count("SELECT count(DISTINCT subject) FROM event_graph") ?? -1
            let starts = events.compactMap(\.start)
            let range = starts.min().flatMap { lo in starts.max().map { lo...$0 } }
            lines.append(.check("events decoded", events.count == eventSubjects, "\(events.count) events (\(eventSubjects) subjects), \(events.filter { !$0.conferenceURLs.isEmpty }.count) with call link, \(Set(events.flatMap { $0.participants.map(\.node) }).count) people, starts \(DossierDate.range(range)) (\(t3))"))
            for (name, options) in [("ego 2 hops", GraphOptions()), ("everything + software", GraphOptions(scope: .everything, hops: 2, kinds: Set(EntityKind.allCases)))] {
                let (scene, tb) = try await timed { try await GraphScene.build(options: options) }
                let start = Date()
                let positions = ForceLayout.run(scene: scene)
                lines.append(.check("graph layout · \(name)", positions.count == scene.nodes.count && positions.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(scene.nodes.count) nodes, \(scene.edges.count) links; build \(tb), layout \(String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000))"))
            }
            let (people, t4) = try await timed { try await PeopleData.load() }
            let verdicts = Dictionary(grouping: people.rows, by: \.verdict).map { "\($0.key.rawValue) \($0.value.count)" }.sorted()
            lines.append(.pass("people & relationship join", "\(people.rows.count) rows, \(people.labels.count) probability columns, \(people.taggingRows) tagging / \(people.importanceRows) importance / \(people.relevanceRows) relevance rows; \(verdicts.joined(separator: ", ")) (\(t4))"))
            if !people.missing.isEmpty { lines.append(.warn("people inputs missing", people.missing.joined(separator: ", "))) }
        } catch {
            lines.append(.fail("graph index", error.localizedDescription))
        }

        // ontology.db
        do {
            let (ontology, t) = try await timed { try await OntologyData.load() }
            lines.append(.pass("ontology.db", "\(ontology.classes.filter(\.defined).count) classes (\(ontology.classes.filter { $0.total > 0 }.count) used), \(ontology.predicates.filter(\.defined).count) predicates (\(ontology.predicates.filter { $0.total > 0 }.count) used), \(ontology.predicates.filter { !$0.defined }.count + ontology.classes.filter { !$0.defined }.count) used-but-undefined (\(t))"))
        } catch {
            lines.append(.warn("ontology.db", error.localizedDescription))
        }
        lines += await artifactLines()
        return lines
    }

    private func artifactLines() async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        var empty: [String] = []
        var missing: [String] = []
        for item in DerivedItem.catalog {
            switch await DerivedStore.rowCount(item.store, item.tableName) {
            case .some(let n) where n > 0:
                lines.append(.pass("derived · \(item.title)", "\(item.store.lastPathComponent) › \(item.tableName): \(Format.count(n)) rows"))
            case .some: empty.append(item.title)
            case .none: missing.append(item.title)
            }
        }
        if !empty.isEmpty { lines.append(.info("derived views empty on this Mac", empty.joined(separator: ", "))) }
        if !missing.isEmpty { lines.append(.warn("derived views not present", missing.joined(separator: ", "))) }
        if let languages = try? await DerivedStore.languages() {
            lines.append(.pass("language inference decoded", "\(languages.count) language(s)"))
        }
        if let db = await GraphPaths.openIfAvailable(GraphPaths.features), let row = try? await db.first("SELECT value FROM kv LIMIT 1"), let data = row[0].data {
            let decoded = DerivedStore.describeBlob(data)
            lines.append(.check("feature value decodes (NSKeyedArchiver MLFeatureValue)", !decoded.contains("binary data") && !decoded.hasPrefix("{"), "sample decoded to a \(Double(decoded) != nil ? "number" : "string")"))
        }
        if let status = try? await DerivedStore.pipelineStatus() {
            lines.append(.pass("pipeline status", "\(status.viewCount) views (\(status.viewsWithTables) materialised, \(status.viewErrors) errors), \(status.sourcesAvailable)/\(status.sourcesTotal) inputs available, \(status.phases.count) source phases, \(status.facts.count) run facts"))
        }
        return lines
    }
}
