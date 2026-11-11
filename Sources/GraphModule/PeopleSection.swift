import SwiftUI
import Charts
import DossierCore

// MARK: - Model

/// How the relationship you declared compares with what the tagging model inferred.
enum RelationshipVerdict: String, Sendable, CaseIterable {
    case agree, disagree, inferredOnly, declaredOnly, none, owner

    var title: String {
        switch self {
        case .agree: return "Agrees"
        case .disagree: return "Disagrees"
        case .inferredOnly: return "Inferred only"
        case .declaredOnly: return "Declared only"
        case .none: return ""
        case .owner: return "You"
        }
    }

    var tint: Color {
        switch self {
        case .agree: return .green
        case .disagree: return .red
        case .inferredOnly: return .purple
        case .declaredOnly: return .blue
        case .none: return .secondary
        case .owner: return .accentColor
        }
    }

    var symbol: String {
        switch self {
        case .agree: return "checkmark.circle.fill"
        case .disagree: return "exclamationmark.triangle.fill"
        case .inferredOnly: return "sparkles"
        case .declaredOnly: return "person.text.rectangle"
        case .none: return "minus"
        case .owner: return "person.crop.circle.fill"
        }
    }
}

struct PersonRow: Identifiable, Sendable {
    let id: Int64
    let name: String
    let isOwner: Bool
    /// Relationship labels the owner's node declares toward this person (`PS598`).
    var declared: [String] = []
    var declaredSources: Int64 = 0
    /// One probability per ``PeopleData/labels`` entry; empty if the person has no tagging row.
    var probabilities: [Double] = []
    var topLabel = ""
    var topProbability = 0.0
    var verdict = RelationshipVerdict.none
    var verdictNote = ""
    /// Boolean importance flags that are set (column names of `entityImportanceSignalsIDMap`).
    var flags: [String] = []
    /// `relationshipLabel` of the importance table: labels found on this person's own card.
    var cardLabels = ""
    var relevance: Double?
    var longTermRelevance: Double?
    var explanation: String?
    var sources: Int64 = 0
    var links = 0
}

struct PeopleData: Sendable {
    /// Probability column names of `entity_tagging`, in table order.
    var labels: [String] = []
    var rows: [PersonRow] = []
    var index: GraphIndex
    var taggingRows = 0
    var importanceRows = 0
    var relevanceRows = 0
    var missing: [String] = []

    /// Maps a declared label to the tagging column that expresses it.
    static func column(for declared: String, labels: [String]) -> String? {
        let key = declared.lowercased().replacingOccurrences(of: " ", with: "")
        if let exact = labels.first(where: { $0.lowercased() == key }) { return exact }
        let synonyms: [String: String] = [
            "femalefriend": "friend", "malefriend": "friend", "girlfriend": "partner", "boyfriend": "partner",
            "spouse": "partner", "wife": "partner", "husband": "partner", "femalepartner": "partner", "malepartner": "partner",
            "colleague": "coworker", "manager": "coworker", "assistant": "coworker",
            "sisterinlaw": "family", "brotherinlaw": "family", "motherinlaw": "family", "fatherinlaw": "family",
            "cousin": "family", "uncle": "family", "aunt": "family", "grandmother": "family", "grandfather": "family",
        ]
        if let mapped = synonyms[key] { return labels.first { $0.lowercased() == mapped } }
        return nil
    }

    static func load() async throws -> PeopleData {
        let index = try await GraphStore.shared.index()
        var data = PeopleData(index: index)
        var rows: [Int64: PersonRow] = [:]
        for e in index.ordered where e.kind == .person {
            var row = PersonRow(id: e.id, name: e.name, isOwner: e.isOwner)
            row.sources = e.sources
            row.links = e.incoming + e.outgoing
            rows[e.id] = row
        }

        // Declared labels: association facets on the owner's node.
        if let owner = index.ownerID {
            let statements = Statement.group(try await GraphStore.shared.triples(subject: owner))
            for s in statements where s.predicate == P.association {
                guard let ref = s.field("nm_personIdentifier").flatMap(GraphRef.parse) else { continue }
                let label = s.field("nm_unlocalizedRelationshipLabel").map(GraphFormat.cleanLabel) ?? s.field("nm_relationshipLabel") ?? ""
                guard !label.isEmpty else { continue }
                if rows[ref] == nil {
                    // Linked node of another class (e.g. a pet): still worth listing.
                    rows[ref] = PersonRow(id: ref, name: index.name(ref) ?? "Unknown", isOwner: false)
                }
                if !(rows[ref]!.declared.contains(label)) { rows[ref]!.declared.append(label) }
                rows[ref]!.declaredSources |= s.sources
            }
        }

        // Inferred probabilities — columns are read dynamically.
        if let db = await GraphPaths.openIfAvailable(GraphPaths.entityTagging), await db.tableExists("entity_tagging") {
            let columns = await db.columns(of: "entity_tagging")
            let idColumn = columns.first { $0.name.lowercased() == "mdid" }?.name
            let labels = columns.filter { c in
                let n = c.name.lowercased()
                return n != "mdid" && n != "eventid" && !c.declaredType.uppercased().contains("INT") && !c.declaredType.uppercased().contains("TEXT")
            }.map(\.name)
            if let idColumn, !labels.isEmpty {
                data.labels = labels
                let sql = "SELECT " + SQLiteDB.quote(idColumn) + ", " + labels.map(SQLiteDB.quote).joined(separator: ", ") + " FROM entity_tagging LIMIT 250000"
                let result = try await db.rows(sql, maxRows: 250_000)
                data.taggingRows = result.count
                for r in result {
                    guard let id = DerivedStore.nodeID(r[0]) else { continue }
                    if rows[id] == nil { rows[id] = PersonRow(id: id, name: index.name(id) ?? "Unknown", isOwner: id == index.ownerID) }
                    rows[id]!.probabilities = (1...labels.count).map { r[$0].double ?? 0 }
                }
            } else { data.missing.append("entity_tagging columns") }
        } else { data.missing.append("entityTagging.db") }

        // Importance signals — boolean columns are read dynamically.
        if let db = await GraphPaths.openIfAvailable(GraphPaths.importance), await db.tableExists("entityImportanceSignalsIDMap") {
            let columns = await db.columns(of: "entityImportanceSignalsIDMap").map(\.name)
            if let idColumn = columns.first(where: { $0.lowercased() == "entityidentifier" }) {
                let flags = columns.filter { $0.lowercased().hasPrefix("is") }
                let hasLabel = columns.contains("relationshipLabel")
                let select = [idColumn] + flags + (hasLabel ? ["relationshipLabel"] : [])
                let result = try await db.rows("SELECT " + select.map(SQLiteDB.quote).joined(separator: ", ") + " FROM entityImportanceSignalsIDMap LIMIT 250000", maxRows: 250_000)
                data.importanceRows = result.count
                for r in result {
                    guard let id = DerivedStore.nodeID(r[0]), rows[id] != nil else { continue }
                    for (i, flag) in flags.enumerated() where r[i + 1].bool == true {
                        rows[id]!.flags.append(Ontology.prettifyKey(String(flag.dropFirst(2))))
                    }
                    if hasLabel { rows[id]!.cardLabels = (r[flags.count + 1].string ?? "").replacingOccurrences(of: ",", with: ", ") }
                }
            }
        } else { data.missing.append("entityImportanceSignals.db") }

        // Relevance scores with their explanation JSON.
        if let db = await GraphPaths.openIfAvailable(GraphPaths.relevance) {
            for (table, longTerm) in [("person_entity_relevance", false), ("person_entity_longterm", true)] where await db.hasColumns(table, ["mdid", "relevanceScore"]) {
                let hasExplanation = await db.hasColumns(table, ["explanation"])
                let result = (try? await db.rows("SELECT mdid, relevanceScore\(hasExplanation ? ", explanation" : "") FROM \(table) LIMIT 100000")) ?? []
                data.relevanceRows += result.count
                for r in result {
                    guard let id = DerivedStore.nodeID(r[0]), rows[id] != nil else { continue }
                    if longTerm { rows[id]!.longTermRelevance = r[1].double } else {
                        rows[id]!.relevance = r[1].double
                        if hasExplanation { rows[id]!.explanation = r[2].string }
                    }
                    if longTerm, rows[id]!.explanation == nil, hasExplanation { rows[id]!.explanation = r[2].string }
                }
            }
        } else { data.missing.append("entityRelevanceInferences.db") }

        // Verdicts.
        let generic: Set<String> = ["unknown", "myself", "familyandfriends"]
        let labels = data.labels
        var out: [PersonRow] = []
        out.reserveCapacity(rows.count)
        for var row in rows.values {
            if !row.probabilities.isEmpty {
                var best = -1.0
                for (i, p) in row.probabilities.enumerated() where !generic.contains(labels[i].lowercased()) && p > best {
                    best = p; row.topLabel = labels[i]; row.topProbability = p
                }
            }
            if row.isOwner {
                if let i = labels.firstIndex(where: { $0.lowercased() == "myself" }), row.probabilities.indices.contains(i) {
                    row.topLabel = labels[i]; row.topProbability = row.probabilities[i]
                }
                row.verdict = .owner
            } else if !row.declared.isEmpty {
                var notes: [String] = []
                var anyMapped = false, anyDisagree = false
                for d in row.declared {
                    guard let column = column(for: d, labels: labels), let i = labels.firstIndex(of: column), !row.probabilities.isEmpty else { continue }
                    anyMapped = true
                    let p = row.probabilities[i]
                    if p < 0.5 { anyDisagree = true; notes.append("you say \(d.lowercased()), model gives \(column) \(GraphFormat.percent(p))") }
                    else { notes.append("\(d.lowercased()) confirmed at \(GraphFormat.percent(p))") }
                }
                row.verdict = anyMapped ? (anyDisagree ? .disagree : .agree) : .declaredOnly
                row.verdictNote = notes.joined(separator: "; ")
                if !anyMapped { row.verdictNote = row.probabilities.isEmpty ? "no inference row for this node" : "label has no matching model column" }
            } else if row.topProbability >= 0.5 {
                row.verdict = .inferredOnly
                row.verdictNote = "model: \(row.topLabel) \(GraphFormat.percent(row.topProbability)), nothing declared"
            }
            out.append(row)
        }
        let rank: [RelationshipVerdict: Int] = [.owner: 0, .disagree: 1, .agree: 2, .declaredOnly: 3, .inferredOnly: 4, .none: 5]
        out.sort { a, b in
            let ra = rank[a.verdict] ?? 9, rb = rank[b.verdict] ?? 9
            if ra != rb { return ra < rb }
            let sa = (a.relevance ?? 0) + a.topProbability + Double(a.flags.count), sb = (b.relevance ?? 0) + b.topProbability + Double(b.flags.count)
            if sa != sb { return sa > sb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        data.rows = out
        return data
    }
}

// MARK: - View

/// (3) People & relationship inference.
struct PeopleSection: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", declared = "Declared", disagree = "Disagreements", inferred = "Inferred Only", signals = "With Signals"
        var id: String { rawValue }
    }

    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var scope = Scope.all
    @State private var selected: Int64?
    @State private var showNode = false
    @State private var filter = ""

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (scope, selected, showNode, filter)
        let token = refreshToken
        // Read state here so SwiftUI re-evaluates this body (the content closures below run inside AsyncContent).
        let _ = (scope, selected, showNode)
        VStack(spacing: 0) {
            ExplainerBar(text: "For every person node the system keeps a relationship model: a probability per relationship type (entity_tagging), importance flags and a relevance score. “Declared” is what your own contact card says; the rest is inferred — highlighted where the two disagree.")
            Divider()
            AsyncContent(reloadKey: token) {
                await GraphStore.shared.sync(token: token)
                return try await PeopleData.load()
            } isEmpty: { $0.rows.isEmpty } content: { data in
                content(data)
            }
            StoreFooter(GraphPaths.entityTagging, note: "entity_tagging ⨝ entityImportanceSignals ⨝ entityRelevanceInferences ⨝ graph.db")
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink else { return }
            if link.payload.hasPrefix("person:"), let id = Int64(link.payload.dropFirst(7)) { selected = id }
            else if !link.payload.isEmpty { filter = link.payload }
        }
    }

    private func rows(_ data: PeopleData) -> [PersonRow] {
        switch scope {
        case .all: return data.rows
        case .declared: return data.rows.filter { !$0.declared.isEmpty }
        case .disagree: return data.rows.filter { $0.verdict == .disagree }
        case .inferred: return data.rows.filter { $0.verdict == .inferredOnly }
        case .signals: return data.rows.filter { !$0.flags.isEmpty || $0.relevance != nil || !$0.cardLabels.isEmpty }
        }
    }

    @ViewBuilder
    private func content(_ data: PeopleData) -> some View {
        let visible = rows(data)
        VStack(spacing: 0) {
            // Widest variant that fits: the summary text goes first, then the segmented control
            // becomes a pop-up, then the verdict chips go (inspector open in a minimum window).
            // Nested in pairs: see GraphViewSection.controls.
            ViewThatFits(in: .horizontal) {
                strip(data, segmented: true, text: true, chips: true)
                ViewThatFits(in: .horizontal) {
                    strip(data, segmented: true, text: false, chips: true)
                    ViewThatFits(in: .horizontal) {
                        strip(data, segmented: false, text: false, chips: true)
                        strip(data, segmented: false, text: false, chips: false)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.bar)
            Divider()
        PagedTable(
            rows: visible,
            columns: columns(data),
            searchPrompt: "Filter people",
            reloadKey: AnyHashable([AnyHashable(scope), AnyHashable(visible.count), AnyHashable(ObjectIdentifier(data.index))]),
            exportName: "graph-people",
            emptyTitle: "No People in This View",
            filter: $filter,
            onSelect: { rows in
                if rows.count == 1 { selected = rows[0].id; showNode = false } else if rows.isEmpty { selected = nil }
            }
        )
        }
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                if showNode {
                    EntityInspector(entityID: selected, subtitle: "Graph node", onClose: { showNode = false })
                } else if let row = data.rows.first(where: { $0.id == selected }) {
                    inspector(row, data)
                } else {
                    EntityInspector(entityID: selected, onClose: { self.selected = nil })
                }
            }
        }
    }

    private func strip(_ data: PeopleData, segmented: Bool, text: Bool, chips: Bool) -> some View {
        let counts = Dictionary(grouping: data.rows, by: \.verdict).mapValues(\.count)
        let summary = "\(Format.count(data.rows.count)) people · \(Format.count(data.taggingRows)) with a model row"
        return HStack(spacing: 10) {
            Group {
                if segmented {
                    Picker("Show", selection: $scope) {
                        ForEach(Scope.allCases) { s in Text(s.rawValue).tag(s) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Picker("Show", selection: $scope) {
                        ForEach(Scope.allCases) { s in Text(s.rawValue).tag(s) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            if chips {
                HStack(spacing: 6) {
                    if text {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ForEach([RelationshipVerdict.disagree, .agree, .declaredOnly, .inferredOnly], id: \.self) { v in
                        if let n = counts[v], n > 0 {
                            TagLabel("\(n) \(v.title.lowercased())", tint: v.tint)
                        }
                    }
                }
                .fixedSize()
                .help(summary)
            }
        }
    }

    private func columns(_ data: PeopleData) -> [PagedColumn<PersonRow>] {
        var cols: [PagedColumn<PersonRow>] = [
            PagedColumn<PersonRow>("Person", id: "name", width: 210, min: 130, sensitivity: .sensitive) { $0.name }
                .cell { row in
                    HStack(spacing: 6) {
                        Text(row.name).font(.callout).lineLimit(1)
                        if row.isOwner { TagLabel("you", tint: .accentColor) }
                    }
                },
            PagedColumn<PersonRow>("Declared", id: "declared", width: 150, sensitivity: .sensitive) { $0.declared.joined(separator: ", ") },
            PagedColumn<PersonRow>("Check", id: "verdict", width: 118) { $0.verdict.title }
                .cell { row in
                    if row.verdict != .none {
                        HStack(spacing: 4) {
                            Image(systemName: row.verdict.symbol).imageScale(.small)
                            Text(row.verdict.title)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(row.verdict.tint)
                        .help(row.verdictNote)
                    }
                },
            PagedColumn<PersonRow>("Top Inferred", id: "top", width: 150, sensitivity: .personal) { row in
                row.probabilities.isEmpty ? "" : "\(GraphFormat.percent(row.topProbability)) \(Ontology.prettifyKey(row.topLabel))"
            },
        ]
        // One column per probability label; informative ones are visible by default.
        for (i, label) in data.labels.enumerated() {
            let maxP = data.rows.reduce(0.0) { max($0, $1.probabilities.indices.contains(i) ? $1.probabilities[i] : 0) }
            let minP = data.rows.reduce(1.0) { min($0, $1.probabilities.indices.contains(i) ? $1.probabilities[i] : 1) }
            let informative = maxP >= 0.5 && maxP - minP > 0.2
            cols.append(
                PagedColumn<PersonRow>(Ontology.prettifyKey(label).capitalized, id: "p|" + label, width: 74, alignment: .trailing, sensitivity: .personal, hiddenByDefault: !informative) { row in
                    row.probabilities.indices.contains(i) ? GraphFormat.percent(row.probabilities[i]) : ""
                }
                .cell { row in
                    if row.probabilities.indices.contains(i) {
                        let p = row.probabilities[i]
                        Text(GraphFormat.percent(p))
                            .font(.callout).monospacedDigit()
                            .foregroundStyle(p >= 0.5 ? Color.primary : Color.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(p * 0.32), in: RoundedRectangle(cornerRadius: 4))
                    }
                })
        }
        cols += [
            PagedColumn<PersonRow>("Signals", id: "flags", width: 130, sensitivity: .personal) { $0.flags.joined(separator: ", ") },
            PagedColumn<PersonRow>("Relevance", id: "relevance", width: 80, alignment: .trailing, sensitivity: .personal) { $0.relevance.map { Format.number($0, maxDigits: 4) } ?? "" },
            PagedColumn<PersonRow>("Labels on Their Card", id: "card", width: 170, sensitivity: .sensitive, hiddenByDefault: true) { $0.cardLabels },
            PagedColumn<PersonRow>("Sources", id: "sources", width: 180) { data.index.sources.titles(mask: $0.sources).joined(separator: ", ") }
                .cell { SourceBadges(mask: $0.sources, catalog: data.index.sources, limit: 4, fitting: true) },
            PagedColumn<PersonRow>("Node id", id: "id", width: 170, monospaced: true, secondary: true, hiddenByDefault: true) { GraphRef.string($0.id) },
        ]
        return cols
    }

    // MARK: Inspector

    private struct ProbabilityBar: Identifiable { let id: String; let label: String; let value: Double }

    private func inspector(_ row: PersonRow, _ data: PeopleData) -> some View {
        InspectorPage(title: row.name, subtitle: "Relationship model", sensitivity: .sensitive, onClose: { selected = nil }) {
            if row.verdict != .none {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: row.verdict.symbol).foregroundStyle(row.verdict.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verdictTitle(row)).font(.callout.weight(.semibold))
                        if !row.verdictNote.isEmpty {
                            Text(row.verdictNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).sensitive(.sensitive)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(row.verdict.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            KeyValueGrid([
                KeyValueItem("Declared", row.declared.isEmpty ? "nothing declared" : row.declared.joined(separator: ", "), sensitivity: .sensitive),
                KeyValueItem("Importance", row.flags.isEmpty ? "no flags set" : row.flags.joined(separator: ", "), sensitivity: .personal),
                KeyValueItem("Labels on their card", row.cardLabels.isEmpty ? "—" : row.cardLabels, sensitivity: .sensitive),
                KeyValueItem("Relevance now", row.relevance.map { Format.number($0, maxDigits: 5) } ?? "not scored"),
                KeyValueItem("Relevance long-term", row.longTermRelevance.map { Format.number($0, maxDigits: 5) } ?? "not scored"),
            ])
            if !row.probabilities.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    InspectorGroupTitle("Inferred relationship probabilities")
                    let bars = zip(data.labels, row.probabilities)
                        .map { ProbabilityBar(id: $0.0, label: Ontology.prettifyKey($0.0), value: $0.1) }
                        .sorted { $0.value > $1.value }
                    Chart(bars) { bar in
                        BarMark(x: .value("Probability", bar.value), y: .value("Relationship", bar.label))
                            .foregroundStyle(bar.value >= 0.5 ? Color.accentColor : Color.secondary.opacity(0.5))
                            .cornerRadius(2)
                            .annotation(position: .trailing, spacing: 3) {
                                Text(GraphFormat.percent(bar.value)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                    }
                    .chartYScale(domain: bars.map(\.label))
                    .chartXScale(domain: 0...1.25)
                    .chartXAxis {
                        AxisMarks(values: [0, 0.5, 1]) { value in
                            AxisGridLine().foregroundStyle(.quaternary)
                            AxisValueLabel { if let v = value.as(Double.self) { Text(GraphFormat.percent(v)).fixedSize() } }
                        }
                    }
                    .chartYAxis { AxisMarks(preset: .aligned, position: .leading) { _ in AxisValueLabel() } }
                    .frame(height: CGFloat(bars.count) * 17 + 26)
                    .padding(.trailing, 16)
                    .sensitive(.personal)
                    Text("Columns of entity_tagging. Values near 12.5% / 25% are the model’s priors, not evidence.")
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("The tagging model has no row for this node.").font(.callout).foregroundStyle(.secondary)
            }
            if let explanation = row.explanation, !explanation.isEmpty {
                ExplanationView(json: explanation)
            }
            PersonFeaturesView(node: row.id)
            Button("Show graph node with all statements") { showNode = true }
                .buttonStyle(.link).font(.callout)
        }
    }

    private func verdictTitle(_ row: PersonRow) -> String {
        switch row.verdict {
        case .agree: return "The model agrees with your label"
        case .disagree: return "Declared and inferred disagree"
        case .inferredOnly: return "Inferred without any declaration"
        case .declaredOnly: return "Declared, not modelled"
        case .owner: return "This is your own node"
        case .none: return ""
        }
    }
}

/// Decodes the relevance model's explanation JSON: lists of feature contributions
/// (`name`, `value`, `importance`, `zScore`) under keys such as `positiveContributions`.
private struct ExplanationView: View {
    let json: String

    private struct Contribution: Identifiable {
        let id: String
        let group: String
        let name: String
        let value: Double?
        let importance: Double?
        let zScore: Double?
    }

    private var contributions: [Contribution] {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [Contribution] = []
        for key in object.keys.sorted().reversed() {
            guard let list = object[key] as? [[String: Any]] else { continue }
            for (i, item) in list.enumerated() {
                out.append(Contribution(
                    id: "\(key)|\(i)", group: key, name: item["name"] as? String ?? "feature \(i)",
                    value: (item["value"] as? NSNumber)?.doubleValue, importance: (item["importance"] as? NSNumber)?.doubleValue,
                    zScore: (item["zScore"] as? NSNumber)?.doubleValue))
            }
        }
        return out
    }

    var body: some View {
        let items = contributions
        VStack(alignment: .leading, spacing: 6) {
            InspectorGroupTitle("Why this relevance score")
            if items.isEmpty {
                Text(Format.oneLine(json, max: 600)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                ForEach(Dictionary(grouping: items, by: \.group).keys.sorted().reversed(), id: \.self) { group in
                    let positive = group.lowercased().contains("positive")
                    Text(Ontology.prettifyKey(group).capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(positive ? Color.green : Color.orange)
                    ForEach(items.filter { $0.group == group }.sorted { ($0.importance ?? 0) > ($1.importance ?? 0) }.prefix(12)) { c in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name.replacingOccurrences(of: ":", with: ": ")).font(.caption).lineLimit(2)
                            HStack(spacing: 8) {
                                if let v = c.importance { Text("weight \(Format.number(v, maxDigits: 3))") }
                                if let v = c.zScore { Text("z \(Format.number(v, maxDigits: 2))") }
                                if let v = c.value { Text("value \(Format.number(v, maxDigits: 4))") }
                            }
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Lazily loaded feature-store values for one person (features.db › kv).
private struct PersonFeaturesView: View {
    let node: Int64
    @State private var features: [DerivedStore.FeatureValue]?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                if let features {
                    if features.isEmpty {
                        Text("No features stored for this node.").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    } else {
                        let facts = features.filter { $0.view.hasSuffix("Facts") }
                        let behaviour = features.filter { !$0.view.hasSuffix("Facts") && $0.value != "0" && $0.value != "undefined" }
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(facts + behaviour.prefix(60)) { f in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(Ontology.prettifyKey(f.feature)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(f.value).font(.caption.monospacedDigit()).lineLimit(1).sensitive(.personal)
                                }
                            }
                            if behaviour.count > 60 {
                                Text("+ \(behaviour.count - 60) more non-zero features").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text("\(features.count) feature values stored; zero-valued behaviour features are hidden.").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.top, 4)
                    }
                } else {
                    ProgressView().controlSize(.small).padding(.top, 4)
                }
            } label: {
                InspectorGroupTitle("Model input features\(features.map { " (\($0.count))" } ?? "")")
            }
        }
        .task(id: node) {
            features = nil
            let loaded = await SnapshotReadiness.track { await DerivedStore.features(for: node) }
            if !Task.isCancelled {
                features = loaded
                expanded = loaded.contains { $0.view.hasSuffix("Facts") }
            }
        }
    }
}
