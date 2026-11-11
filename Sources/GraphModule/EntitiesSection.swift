import SwiftUI
import DossierCore

/// Filter / sort cache for the entity table so paging does not re-sort on every page.
actor EntityQuery {
    static let shared = EntityQuery()

    private struct Key: Hashable {
        let kind: EntityKind?
        let search: String
        let sort: PageSort?
        let generation: ObjectIdentifier
    }
    private var key: Key?
    private var cached: [EntityInfo] = []

    /// All nodes: the stable graph's index plus event nodes from the event graph.
    static func all(_ index: GraphIndex) async -> [EntityInfo] {
        let events = (try? await GraphStore.shared.events()) ?? []
        return index.ordered + events.map {
            EntityInfo(id: $0.id, classID: $0.classID, kind: .event, name: $0.title, detail: $0.startText, rowCount: $0.rows, sources: $0.sources, confidence: $0.confidence, updated: $0.updated, isOwner: false, outgoing: $0.participants.count + ($0.locationID == nil ? 0 : 1))
        }
    }

    func rows(kind: EntityKind?, request: PageRequest) async throws -> [EntityInfo] {
        let index = try await GraphStore.shared.index()
        let k = Key(kind: kind, search: request.search, sort: request.sort, generation: ObjectIdentifier(index))
        if k == key { return cached }
        var rows = await Self.all(index)
        if let kind { rows = rows.filter { $0.kind == kind } }
        let needle = request.search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            // Match the name / class locally, and any stored value through SQL.
            var valueMatches = Set<Int64>()
            if let db = await GraphPaths.openIfAvailable(GraphPaths.graph) {
                let pattern = "%" + GraphSearch.escapeLike(needle) + "%"
                for table in ["stable_graph", "event_graph"] where await db.tableExists(table) {
                    let found = try await db.rows("SELECT DISTINCT subject FROM \(table) WHERE object LIKE ? ESCAPE '\\' LIMIT 20000", [.text(pattern)])
                    for r in found { if let s = r[0].int { valueMatches.insert(s) } }
                }
            }
            try Task.checkCancellation()
            rows = rows.filter { e in
                valueMatches.contains(e.id)
                    || e.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || e.detail.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || index.ontology.classLabel(e.classID).range(of: needle, options: .caseInsensitive) != nil
            }
        }
        if let sort = request.sort {
            let asc = sort.ascending
            func ordered<T: Comparable>(_ key: (EntityInfo) -> T) -> [EntityInfo] {
                rows.sorted { asc ? key($0) < key($1) : key($0) > key($1) }
            }
            switch sort.columnID {
            case "name": rows = rows.sorted { let c = $0.name.localizedCaseInsensitiveCompare($1.name); return asc ? c == .orderedAscending : c == .orderedDescending }
            case "class": rows = ordered { index.ontology.classLabel($0.classID) }
            case "detail": rows = ordered { $0.detail }
            case "rows": rows = ordered { $0.rowCount }
            case "links": rows = ordered { $0.incoming + $0.outgoing }
            case "sources": rows = ordered { $0.sources.nonzeroBitCount * 100 + (63 - $0.sources.leadingZeroBitCount) }
            case "confidence": rows = ordered { $0.confidence }
            case "updated": rows = ordered { $0.updated }
            case "id": rows = ordered { $0.id }
            default: break
            }
        }
        key = k
        cached = rows
        return rows
    }
}

enum GraphSearch {
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}

/// (2) Entities: every node of the graph, by class, with a statement inspector.
struct EntitiesSection: View {
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var kind: EntityKind?
    @State private var selected: Int64?
    @State private var filter = ""

    private struct Loaded: Sendable {
        let index: GraphIndex
        let counts: [EntityKind: Int]
        let total: Int
    }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (kind, selected, filter)
        let token = refreshToken
        // Read state here so SwiftUI re-evaluates this body (the content closures below run inside AsyncContent).
        let _ = (kind, selected)
        VStack(spacing: 0) {
            ExplainerBar(text: "Every node the knowledge graph has built from your contacts, photos, calendar, apps and family circle. Each node merges records from several systems; select one to see every statement stored about it.")
            Divider()
            AsyncContent(reloadKey: token) {
                await GraphStore.shared.sync(token: token)
                let index = try await GraphStore.shared.index()
                let all = await EntityQuery.all(index)
                var counts: [EntityKind: Int] = [:]
                for e in all { counts[e.kind, default: 0] += 1 }
                return Loaded(index: index, counts: counts, total: all.count)
            } content: { loaded in
                table(loaded)
            }
            StoreFooter(GraphPaths.graph, note: "stable_graph + event_graph, labels from ontology.db")
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink else { return }
            if link.payload.hasPrefix("entity:"), let id = Int64(link.payload.dropFirst(7)) {
                selected = id
            } else if !link.payload.isEmpty {
                filter = link.payload
            }
        }
    }

    private func table(_ loaded: Loaded) -> some View {
        let index = loaded.index
        let kindKey = kind
        return PagedTable(
            columns: columns(index),
            searchPrompt: "Filter by name or any stored value",
            reloadKey: AnyHashable([AnyHashable(kind?.rawValue ?? "all"), AnyHashable(ObjectIdentifier(index))]),
            exportName: "graph-entities",
            emptyTitle: "No Matching Nodes",
            filter: $filter,
            fetch: { request in
                let rows = try await EntityQuery.shared.rows(kind: kindKey, request: request)
                guard request.offset < rows.count else { return [] }
                return Array(rows[request.offset..<min(rows.count, request.offset + request.limit)])
            },
            count: { request in try await EntityQuery.shared.rows(kind: kindKey, request: request).count },
            onSelect: { rows in if let only = rows.first, rows.count == 1 { selected = only.id } else if rows.isEmpty { selected = nil } }
        ) {
            // Segmented while the bar has room for it beside a usable filter field, else a pop-up.
            AdaptivePicker(title: "Class", selection: $kind, reserve: 180) {
                Text("All  \(Format.count(loaded.total))").tag(EntityKind?.none)
                ForEach(EntityKind.allCases.filter { (loaded.counts[$0] ?? 0) > 0 }) { k in
                    Text("\(k.title)  \(Format.count(loaded.counts[k] ?? 0))").tag(EntityKind?.some(k))
                }
            }
            .layoutPriority(1)
        }
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                EntityInspector(entityID: selected, onClose: { self.selected = nil })
            }
        }
    }

    private func columns(_ index: GraphIndex) -> [PagedColumn<EntityInfo>] {
        [
            PagedColumn<EntityInfo>("Name", id: "name", width: 250, min: 140, sensitivity: .sensitive) { $0.name }
                .cell { e in
                    HStack(spacing: 6) {
                        KindIcon(kind: e.kind, size: 18)
                        Text(e.name).font(.callout).lineLimit(1)
                        if e.isOwner { TagLabel("you", tint: .accentColor) }
                    }
                },
            PagedColumn("Class", id: "class", width: 110) { index.ontology.classLabel($0.classID) },
            PagedColumn("Detail", id: "detail", width: 200, sensitivity: .personal, secondary: true) { $0.detail },
            PagedColumn("Rows", id: "rows", width: 60, alignment: .trailing) { Format.count($0.rowCount) },
            PagedColumn("Links", id: "links", width: 55, alignment: .trailing) { $0.incoming + $0.outgoing == 0 ? "" : Format.count($0.incoming + $0.outgoing) },
            PagedColumn<EntityInfo>("Sources", id: "sources", width: 210) { index.sources.titles(mask: $0.sources).joined(separator: ", ") }
                .cell { SourceBadges(mask: $0.sources, catalog: index.sources, limit: 4, fitting: true) },
            PagedColumn("Confidence", id: "confidence", width: 96, min: 84, alignment: .trailing) { GraphFormat.confidence($0.confidence) },
            PagedColumn("Updated", id: "updated", width: 150, secondary: true) { DossierDate.sortable($0.updatedDate) },
            PagedColumn("Node id", id: "id", width: 170, monospaced: true, secondary: true, hiddenByDefault: true) { GraphRef.string($0.id) },
        ]
    }
}
