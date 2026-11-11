import SwiftUI
import DossierCore

// MARK: - Catalog

/// One entry of the derived-views catalog.
struct DerivedItem: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case languages
        case features
        case pipeline
        case table(TableSpec)
    }

    let id: String
    let title: String
    let symbol: String
    let group: String
    /// Plain-English description of what the view is and where it comes from.
    let explanation: String
    let kind: Kind
    var sensitivity: Sensitivity = .personal
    /// Marks reference data shipped by Apple (not about the owner).
    var generic = false
    /// Extra note for the empty state.
    var emptyNote: String = "The pipeline has not produced any rows for this view on this Mac."

    var spec: TableSpec? { if case .table(let s) = kind { return s } else { return nil } }

    var store: URL {
        switch kind {
        case .languages: return GraphPaths.inferredTriples
        case .features: return GraphPaths.features
        case .pipeline: return GraphPaths.views
        case .table(let s): return s.url
        }
    }

    var tableName: String {
        switch kind {
        case .languages: return "languages"
        case .features: return "kv"
        case .pipeline: return "viewConfigRecord"
        case .table(let s): return s.table
        }
    }

    static let groups = ["Inferences", "People Signals", "Resolution Tables", "Life Events & Topics", "Pipeline", "Generic Reference Data"]

    static let catalog: [DerivedItem] = {
        let internalViews = GraphPaths.internalViews
        func t(_ url: URL, _ table: String, nodes: [String] = [], sensitive: [String] = [], order: String? = nil, desc: Bool = false, skip: [String] = []) -> Kind {
            .table(TableSpec(url: url, table: table, nodeColumns: nodes, sensitiveColumns: sensitive, orderBy: order, descending: desc, skipColumns: skip))
        }
        return [
            DerivedItem(id: "languages", title: "Language Inference", symbol: "character.bubble", group: "Inferences",
                        explanation: "Languages the system believes you understand, inferred from keyboards, device language and region, with separate reading / writing / listening confidences.",
                        kind: .languages),
            DerivedItem(id: "features", title: "Feature Store", symbol: "slider.horizontal.3", group: "Inferences",
                        explanation: "Model input features computed per person: how popular each person is by time of day, weekday and Focus, preferred way of reaching them, age and name facts. Values are NSKeyedArchiver-encoded MLFeatureValue objects, decoded here.",
                        kind: .features),
            DerivedItem(id: "priors", title: "Source Confidence Priors", symbol: "dial.medium", group: "Inferences",
                        explanation: "How much the graph trusts each kind of source signal before any evidence — the origin of the confidence values on graph statements.",
                        kind: t(GraphPaths.sourceConfidence, "sourceConfidence", order: "source"), sensitivity: .low, generic: true),

            DerivedItem(id: "mechanisms2", title: "Interaction Mechanisms", symbol: "arrow.left.arrow.right", group: "People Signals",
                        explanation: "Each interaction with a person in either direction, with the app and channel used (communicationMechanism is a numeric channel code). Feeds “how do you usually reach this person”.",
                        kind: t(internalViews, "bidirectionalPersonInteractionMechanisms", nodes: ["entityIdentifier"], order: "interactionDate", desc: true), sensitivity: .sensitive),
            DerivedItem(id: "mechanisms1", title: "Outgoing Interactions", symbol: "arrow.up.right", group: "People Signals",
                        explanation: "Interactions you initiated, per person, with the app used.",
                        kind: t(internalViews, "personInteractionMechanisms", nodes: ["entityIdentifier"], order: "interactionDate", desc: true), sensitivity: .sensitive),
            DerivedItem(id: "ages", title: "Photos Observed Ages", symbol: "face.smiling", group: "People Signals",
                        explanation: "Age bracket codes the Photos face analysis observed for a person each time they appeared in a photo. Used to tell children from adults when guessing relationships.",
                        kind: t(internalViews, "photosObservedAges", nodes: ["entityIdentifier"], order: "interactionDate", desc: true), sensitivity: .sensitive),
            DerivedItem(id: "interactionEvents", title: "Interaction Event Log", symbol: "clock.arrow.2.circlepath", group: "People Signals",
                        explanation: "Timestamped behaviour events (per person node) from which the popularity histograms are built.",
                        kind: t(internalViews, "bidirectionalPersonEntityInteractionEvents", nodes: ["behaviorIdentifier"], order: "timestamp", desc: true), sensitivity: .sensitive),
            DerivedItem(id: "photoEvents", title: "Photos Appearance Log", symbol: "photo.on.rectangle", group: "People Signals",
                        explanation: "One event per appearance of a recognised person in your photos.",
                        kind: t(internalViews, "photosPersonEntityInteractionEvents", nodes: ["behaviorIdentifier"], order: "timestamp", desc: true), sensitivity: .sensitive),
            DerivedItem(id: "wifi", title: "Wi-Fi Context Events", symbol: "wifi", group: "People Signals",
                        explanation: "Wi-Fi connection events used as context (“who do you contact on this network”). The identifier contains the network name.",
                        kind: t(internalViews, "wifiContextEvents", sensitive: ["behaviorIdentifier"], order: "timestamp", desc: true), sensitivity: .sensitive),
            DerivedItem(id: "loi", title: "Location Context Events", symbol: "location", group: "People Signals",
                        explanation: "Location-of-interest context events (home, work, …) used to condition relevance on where you are.",
                        kind: t(internalViews, "loiContextEvents", sensitive: ["behaviorIdentifier"], order: "timestamp", desc: true), sensitivity: .sensitive),

            DerivedItem(id: "handles", title: "Handle Resolution", symbol: "at", group: "Resolution Tables",
                        explanation: "Lookup table from every e-mail address and phone number to the graph node it belongs to — how an incoming message is resolved to a person.",
                        kind: t(internalViews, "handle_id", nodes: ["id"], sensitive: ["handle"], order: "handle"), sensitivity: .sensitive),
            DerivedItem(id: "phperson", title: "Photos Person Map", symbol: "person.crop.square", group: "Resolution Tables",
                        explanation: "Maps each person recognised by Photos (local identifier) to a graph node.",
                        kind: t(internalViews, "phperson_id_map", nodes: ["id"], sensitive: ["phPersonIdentifier"]), sensitivity: .sensitive),
            DerivedItem(id: "aliases", title: "Entity Aliases", symbol: "quote.bubble", group: "Resolution Tables",
                        explanation: "Normalised spoken / typed aliases for every node, used by Siri and search to resolve a name mention.",
                        kind: t(internalViews, "entity_alias", nodes: ["MD_ID"], sensitive: ["alias"], order: "alias"), sensitivity: .sensitive),
            DerivedItem(id: "summaries", title: "Entity Summaries", symbol: "person.text.rectangle", group: "Resolution Tables",
                        explanation: "Per-person summary rows prepared for entity resolution: normalised names plus neighbour signals and a relevance score.",
                        kind: t(GraphPaths.ecr, "entity_summary", sensitive: ["primary_name", "first_name", "middle_name", "family_name", "alias", "location_name", "event_name"], order: "primary_name"), sensitivity: .sensitive),
            DerivedItem(id: "relationships", title: "People Relationships View", symbol: "heart.text.square", group: "Resolution Tables",
                        explanation: "Flattened person → relationship rows for clients that only need “who is my mother”.",
                        kind: t(internalViews, "people_relationship", nodes: ["subject"], sensitive: ["relation", "relationAlias"]), sensitivity: .sensitive),

            DerivedItem(id: "lifeEvents", title: "Life Events", symbol: "figure.walk.motion", group: "Life Events & Topics",
                        explanation: "Detected life events (trips, workouts, visits) with their time span. The pipeline exists on every Mac but only fills this from iPhone-style sensors.",
                        kind: t(GraphPaths.artifact("lifeEvent/lifeEventView.db"), "lifeEvent_map", nodes: ["subject"], order: "starttime", desc: true), sensitivity: .sensitive,
                        emptyNote: "No life events have been detected on this Mac. This view is normally fed by location and motion data that a Mac does not collect."),
            DerivedItem(id: "futureLifeEvents", title: "Future Life Events", symbol: "calendar.badge.clock", group: "Life Events & Topics",
                        explanation: "Upcoming events the system expects (reservations, tickets, travel).",
                        kind: t(GraphPaths.artifact("futureLifeEvent/futureLifeEventView.db"), "futureLifeEvent_map", nodes: ["subject"], order: "starttime"), sensitivity: .sensitive,
                        emptyNote: "No future life events are predicted on this Mac."),
            DerivedItem(id: "music", title: "Apple Music Events", symbol: "music.note", group: "Life Events & Topics",
                        explanation: "Listening sessions turned into graph events.",
                        kind: t(GraphPaths.artifact("appleMusicEvent/appleMusicEventView.db"), "appleMusicEvent_map", nodes: ["subject"], order: "starttime", desc: true),
                        emptyNote: "No Apple Music listening events have been recorded in the graph on this Mac."),
            DerivedItem(id: "topicsLong", title: "Topics (Long Term)", symbol: "text.badge.star", group: "Life Events & Topics",
                        explanation: "Topics of long-running interest scored from first-party app content.",
                        kind: t(GraphPaths.artifact("firstPartyTopics/scoredTopicsFirstPartyLongTerm.db"), "topics", order: "score", desc: true),
                        emptyNote: "No long-term topics have been scored on this Mac."),
            DerivedItem(id: "topicsShort", title: "Topics (Short Term)", symbol: "text.badge.plus", group: "Life Events & Topics",
                        explanation: "Topics of current interest scored from recent first-party app content.",
                        kind: t(GraphPaths.artifact("firstPartyTopics/scoredTopicsFirstPartyShortTerm.db"), "topics", order: "score", desc: true),
                        emptyNote: "No short-term topics have been scored on this Mac."),

            DerivedItem(id: "pipeline", title: "Pipeline Status", symbol: "gearshape.2", group: "Pipeline",
                        explanation: "When the graph was last rebuilt, which source phases completed and which of the derived views are materialised.",
                        kind: .pipeline, sensitivity: .low),
            DerivedItem(id: "sourceState", title: "View Sources", symbol: "arrow.triangle.branch", group: "Pipeline",
                        explanation: "Every input the view engine listens to (Biome streams, graph tables, other views) and when each last changed.",
                        kind: t(GraphPaths.views, "sourceState", order: "modifiedTimestamp", desc: true, skip: ["lastQueriedSourceData"]), sensitivity: .low),

            DerivedItem(id: "g.aliases", title: "Relationship Word Aliases", symbol: "globe", group: "Generic Reference Data",
                        explanation: "aliases.db: words for relationship types (mother, friend, …) in many languages, keyed by Wikidata id. Shipped reference data — identical on every Mac.",
                        kind: t(GraphPaths.aliases, "aliases", order: "qid"), sensitivity: .low, generic: true),
            DerivedItem(id: "g.keyvalue", title: "Key-Value Store", symbol: "key", group: "Generic Reference Data",
                        explanation: "keyvalue.db: pipeline bookkeeping (run timings, id resolvers, face-to-node signals) plus generic relationship vocabularies. Mostly technical; some keys are record identifiers from your data.",
                        kind: t(GraphPaths.keyvalue, "keyvalue", sensitive: ["key", "value"], order: "domain"), sensitivity: .personal),
            DerivedItem(id: "g.global", title: "Global Knowledge", symbol: "books.vertical", group: "Generic Reference Data",
                        explanation: "globalKnowledge.db: Apple-supplied world knowledge (holidays, sports leagues, media entities, prior beliefs). Not about you.",
                        kind: t(GraphPaths.globalKnowledge, "static_graph", order: "subject", skip: ["assetId"]), sensitivity: .low, generic: true),
        ]
    }()
}

// MARK: - Section

/// (6) Derived views & inferences.
struct DerivedSection: View {
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var selection: String? = "languages"
    @State private var filter = ""

    /// Row counts per catalog id (`-1` = table/store missing).
    private typealias Counts = [String: Int]

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selection, filter)
        let token = refreshToken
        // Read state here so SwiftUI re-evaluates this body (the content closures below run inside AsyncContent).
        let _ = (selection, filter)
        AsyncContent(reloadKey: token) { () -> Counts in
            var counts: Counts = [:]
            for item in DerivedItem.catalog {
                counts[item.id] = await DerivedStore.rowCount(item.store, item.tableName) ?? -1
            }
            return counts
        } content: { counts in
            HStack(spacing: 0) {
                list(counts)
                    .frame(width: 262)
                Divider()
                detail(counts)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, DerivedItem.catalog.contains(where: { $0.id == link.payload }) else { return }
            selection = link.payload
        }
    }

    private func list(_ counts: Counts) -> some View {
        VStack(spacing: 0) {
            FilterField("Filter views", text: $filter)
            Divider()
            List(selection: $selection) {
                ForEach(DerivedItem.groups, id: \.self) { group in
                    let items = DerivedItem.catalog.filter { $0.group == group && (filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter)) }
                    if !items.isEmpty {
                        Section(group) {
                            ForEach(items) { item in
                                HStack(spacing: 6) {
                                    Image(systemName: item.symbol)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    Text(item.title).font(.callout).lineLimit(1)
                                    Spacer(minLength: 4)
                                    let n = counts[item.id] ?? -1
                                    Text(n < 0 ? "n/a" : (n == 0 ? "empty" : Format.compact(n)))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(n <= 0 ? .tertiary : .secondary)
                                }
                                .tag(item.id as String?)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func detail(_ counts: Counts) -> some View {
        if let item = DerivedItem.catalog.first(where: { $0.id == selection }) {
            VStack(spacing: 0) {
                header(item, count: counts[item.id] ?? -1)
                Divider()
                Group {
                    switch item.kind {
                    case .languages: LanguagesPane()
                    case .features: FeaturesPane()
                    case .pipeline: PipelinePane()
                    case .table(let spec): TablePane(item: item, spec: spec, count: counts[item.id] ?? -1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                StoreFooter(item.store, note: item.tableName)
            }
            .id(item.id)
        } else {
            StatePlaceholder(title: "Select a View", symbol: "square.stack.3d.down.right", message: "Derived views are tables the knowledge pipeline computes from the graph and from behaviour streams.")
        }
    }

    private func header(_ item: DerivedItem, count: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(.headline)
                    if item.generic { TagLabel("generic · same on every Mac", tint: .secondary) } else { SensitivityBadge(item.sensitivity) }
                    if count == 0 { TagLabel("empty on this Mac", tint: .orange) }
                    if count < 0 { TagLabel("not on this Mac", tint: .orange) }
                }
                Text(item.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Panes

private struct TablePane: View {
    let item: DerivedItem
    let spec: TableSpec
    let count: Int
    @Environment(\.navigate) private var navigate

    var body: some View {
        if count == 0 {
            StatePlaceholder(title: "Empty on This Mac", symbol: item.symbol, message: "\(item.emptyNote)\nThe table \(spec.table) exists in \(spec.url.lastPathComponent) but has no rows.")
        } else {
            AsyncContent(reloadKey: spec) {
                try await DerivedStore.load(spec)
            } isEmpty: { $0.rows.isEmpty } content: { data in
                VStack(spacing: 0) {
                    GenericTable(data: data, prompt: "Filter rows", exportName: item.id, widths: ["value": 320, "object": 260, "explanation": 320, "neighbor_signals": 260, "sourceIdentifier": 260])
                    if data.truncated {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                            Text("Showing the first \(Format.count(data.rows.count)) of \(Format.count(count)) rows.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let navigate {
                                Button("Open full table in Raw Explorer") {
                                    navigate(DeepLink(sectionID: "raw.sqlite", payload: "\(spec.url.path)\t\(spec.table)\tbrowse"))
                                }
                                .buttonStyle(.link).font(.caption)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).frame(height: 26).background(.bar)
                    }
                }
            }
        }
    }
}

private struct LanguagesPane: View {
    var body: some View {
        AsyncContent(emptyTitle: "No Language Inferred", emptySymbol: "character.bubble") {
            try await DerivedStore.languages()
        } isEmpty: { $0.isEmpty } content: { languages in
            ScrollPage {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(languages) { language in card(language) }
                }
                Text("Confidence values are stored exactly as shown; low numbers mean the system has seen little reading, writing or listening evidence for that language on this device.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func card(_ l: LanguageInference) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(l.code.uppercased())
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.displayName).font(.title3.weight(.semibold)).sensitive(.personal)
                    Text([l.locale.isEmpty ? nil : "locale \(l.locale)", l.region.isEmpty ? nil : "region \(l.region)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 5) {
                meter("Overall", l.confidence)
                meter("Reading", l.reading)
                meter("Writing", l.writing)
                meter("Listening", l.listening)
            }
            if !l.sourceTypes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Evidence").font(.caption).foregroundStyle(.secondary)
                    FlowLayout { ForEach(l.sourceTypes, id: \.self) { TagLabel($0, tint: .teal) } }
                }
            }
            if !l.evidence.isEmpty {
                Text(l.evidence)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if let updated = l.updated {
                Text("Inferred \(DossierDate.medium(updated))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    private func meter(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(Color.secondary.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor).frame(width: max(value == nil ? 0 : 3, geo.size.width * min(max(value ?? 0, 0), 1)))
                    }
            }
            .frame(height: 6)
            Text(value.map { Format.number($0, maxDigits: 2) } ?? "—")
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// Feature store browser: SQL-paged, values decoded per page.
private struct FeaturesPane: View {
    struct Row: Identifiable, Sendable {
        let id: Int64
        let view: String
        let feature: String
        let subject: String
        let subjectName: String
        let value: String
        let bytes: Int
    }

    @State private var selected: Row?

    private static let sortable: [String: String] = ["view": "viewName", "feature": "featureName", "subject": "subidentifierName"]

    private static func whereClause(_ search: String) -> (String, [SQLValue]) {
        guard !search.isEmpty else { return ("", []) }
        let pattern = "%" + GraphSearch.escapeLike(search) + "%"
        return (" WHERE viewName LIKE ?1 ESCAPE '\\' OR featureName LIKE ?1 ESCAPE '\\' OR subidentifierName LIKE ?1 ESCAPE '\\'", [.text(pattern)])
    }

    var body: some View {
        PagedTable(
            columns: [
                PagedColumn<Row>("Feature", id: "feature", width: 300, min: 140) { Ontology.prettifyKey($0.feature) },
                PagedColumn<Row>("Value", id: "value", width: 150, sortable: false, sensitivity: .personal) { $0.value },
                PagedColumn<Row>("About", id: "subject", width: 190, sensitivity: .sensitive) { $0.subjectName.isEmpty ? $0.subject : $0.subjectName },
                PagedColumn<Row>("Feature Group", id: "view", width: 260, secondary: true) { $0.view },
                PagedColumn<Row>("Bytes", id: "bytes", width: 60, alignment: .trailing, sortable: false, secondary: true, hiddenByDefault: true) { "\($0.bytes)" },
            ],
            searchPrompt: "Filter by feature, group or node id",
            exportName: "graph-features",
            fetch: { request in
                let db = try await GraphPaths.open(GraphPaths.features)
                guard await db.hasColumns("kv", ["viewName", "featureName", "subidentifierName", "value"]) else {
                    throw DossierError.missing("features.db has no kv table with the expected columns on this macOS version.")
                }
                let index = try? await GraphStore.shared.index()
                let (filter, params) = Self.whereClause(request.search)
                var order = "viewName, featureName, subidentifierName"
                if let sort = request.sort, let column = Self.sortable[sort.columnID] { order = "\(column) \(sort.sqlDirection), rowid" }
                let rows = try await db.rows(
                    "SELECT rowid, viewName, featureName, subidentifierName, value FROM kv\(filter) ORDER BY \(order) LIMIT \(request.limit) OFFSET \(request.offset)", params)
                return rows.map { r in
                    let subject = r[3].string ?? ""
                    return Row(
                        id: r[0].int ?? 0, view: r[1].string ?? "", feature: r[2].string ?? "", subject: subject,
                        subjectName: GraphRef.parse(subject).flatMap { index?.name($0) } ?? "",
                        value: r[4].data.map(DerivedStore.describeBlob) ?? (r[4].string ?? ""), bytes: r[4].data?.count ?? 0)
                }
            },
            count: { request in
                guard let db = await GraphPaths.openIfAvailable(GraphPaths.features) else { return nil }
                let (filter, params) = Self.whereClause(request.search)
                return await db.count("SELECT count(*) FROM kv\(filter)", params)
            },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        )
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                InspectorPage(title: Ontology.prettifyKey(selected.feature), subtitle: selected.view, scrolls: false, onClose: { self.selected = nil }) {
                    VStack(alignment: .leading, spacing: 0) {
                        KeyValueGrid([
                            KeyValueItem("Decoded value", selected.value, sensitivity: .personal),
                            KeyValueItem("About", selected.subjectName.isEmpty ? (selected.subject.isEmpty ? "global (no subject)" : selected.subject) : selected.subjectName, sensitivity: .sensitive),
                            KeyValueItem("Subject key", selected.subject.isEmpty ? "—" : selected.subject, monospaced: true),
                        ])
                        .padding(14)
                        Divider()
                        AsyncContent(reloadKey: selected.id) {
                            let db = try await GraphPaths.open(GraphPaths.features)
                            return try await db.scalar("SELECT value FROM kv WHERE rowid = ?", [.integer(selected.id)]).data ?? Data()
                        } content: { data in
                            BlobInspector(data: data, title: "kv.value", sensitivity: .personal)
                        }
                    }
                }
            }
        }
    }
}

private struct PipelinePane: View {
    var body: some View {
        AsyncContent {
            try await DerivedStore.pipelineStatus()
        } content: { status in
            ScrollPage {
                StatTileRow([
                    Stat("Derived Views", Format.count(status.viewCount), caption: "\(status.viewsWithTables) materialised", symbol: "square.stack.3d.down.right"),
                    Stat("View Errors", Format.count(status.viewErrors), caption: status.viewErrors == 0 ? "none reported" : "see table", symbol: "exclamationmark.triangle", tint: status.viewErrors == 0 ? .green : .orange),
                    Stat("Inputs Available", "\(status.sourcesAvailable) of \(status.sourcesTotal)", caption: "streams, tables, views", symbol: "arrow.triangle.branch", tint: .teal),
                    Stat("Source Phases", Format.count(status.phases.count), caption: "graph construction", symbol: "gearshape.2", tint: .purple),
                ])
                if !status.facts.isEmpty {
                    SectionHeader("Last Runs", subtitle: "Bookkeeping from graph.db › graph_state and keyvalue.db › Pipeline.Status", symbol: "clock")
                    KeyValueGrid(status.facts.enumerated().map { KeyValueItem($0.element.label, $0.element.value, id: "\($0.offset)") }, labelWidth: 300)
                        .card()
                }
                if !status.phases.isEmpty {
                    SectionHeader("Source Phases", subtitle: "graph.db › phase_status — one entry per source system the graph builder knows; names are derived from the rows each source contributed", symbol: "square.3.layers.3d")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)], alignment: .leading, spacing: 6) {
                        ForEach(Array(status.phases.enumerated()), id: \.offset) { _, phase in
                            HStack(spacing: 6) {
                                Image(systemName: phase.source.contains("no rows") ? "circle.dotted" : "checkmark.circle.fill")
                                    .foregroundStyle(phase.source.contains("no rows") ? Color.secondary : Color.green)
                                Text(phase.source).font(.callout).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(phase.status).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .card()
                }
                if !status.schedules.isEmpty {
                    SectionHeader("Schedules", subtitle: "views.db › scheduleState", symbol: "calendar.badge.clock")
                    FlowLayout(spacing: 6, lineSpacing: 4) {
                        ForEach(Array(status.schedules.enumerated()), id: \.offset) { _, s in
                            TagLabel("\(s.name): \(Ontology.prettifyKey(s.state))", tint: s.state.lowercased().contains("needs") ? .orange : .green)
                        }
                    }
                    .card()
                }
                if !status.views.rows.isEmpty {
                    SectionHeader("View Catalog", subtitle: "views.db › viewConfigRecord ⨝ viewState — every derived view and where it is written", symbol: "tablecells")
                    GenericTable(data: status.views, prompt: "Filter views", exportName: "graph-views", widths: ["#": 40, "View": 260, "Generation": 90, "Artifact type": 100, "Artifact file": 280, "Table": 220, "Materialised": 85, "Attempts": 65, "Error": 200])
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
                }
            }
        }
    }
}
