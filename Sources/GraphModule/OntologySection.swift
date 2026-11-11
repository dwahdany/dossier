import SwiftUI
import DossierCore

// MARK: - Model

struct OntologyRow: Identifiable, Sendable {
    let id: String
    var label: String
    var isPredicate: Bool
    /// Rows using it as the statement predicate (predicates) or as an `is a` value (classes).
    var used = 0
    /// Rows using it as a facet field (`relationshipPredicate`); predicates only.
    var usedAsField = 0
    var defined = true
    var parents: [String] = []
    var children: [String] = []
    var domain: [String] = []
    var range: [String] = []
    var maxCount: Int?
    /// For relationship-type classes: what the facet's object is.
    var objectType = ""
    var objectClass = ""

    var total: Int { used + usedAsField }
}

struct OntologyData: Sendable {
    var predicates: [OntologyRow] = []
    var classes: [OntologyRow] = []
    var versions: [(file: String, version: String)] = []
    var labels = Ontology.empty

    static func load() async throws -> OntologyData {
        let db = try await GraphPaths.open(GraphPaths.ontology)
        var data = OntologyData()
        data.labels = await GraphStore.shared.ontology()
        var predicates: [String: OntologyRow] = [:]
        var classes: [String: OntologyRow] = [:]

        if await db.hasColumns("predicate", ["id", "label"]) {
            let hasMax = await db.hasColumns("predicate", ["maxCount"])
            for r in try await db.rows("SELECT id, label\(hasMax ? ", maxCount" : "") FROM predicate") {
                guard let id = r[0].string else { continue }
                var row = OntologyRow(id: id, label: r[1].string ?? "", isPredicate: true)
                if hasMax { row.maxCount = r[2].int.map(Int.init) }
                predicates[id] = row
            }
        }
        if await db.hasColumns("class", ["id", "label"]) {
            for r in try await db.rows("SELECT id, label FROM class") {
                guard let id = r[0].string else { continue }
                classes[id] = OntologyRow(id: id, label: r[1].string ?? "", isPredicate: false)
            }
        }
        guard !predicates.isEmpty || !classes.isEmpty else {
            throw DossierError.missing("ontology.db has no class / predicate tables on this macOS version.")
        }
        if await db.hasColumns("predicate_domain", ["predicateId", "domain"]) {
            for r in try await db.rows("SELECT predicateId, domain FROM predicate_domain") {
                if let id = r[0].string, let d = r[1].string { predicates[id]?.domain.append(d) }
            }
        }
        if await db.hasColumns("predicate_range", ["predicateId", "dataType", "range"]) {
            for r in try await db.rows("SELECT predicateId, dataType, range FROM predicate_range") {
                if let id = r[0].string, let value = r[2].string { predicates[id]?.range.append(value) }
            }
        }
        if await db.hasColumns("inheritance", ["child", "parent"]) {
            for r in try await db.rows("SELECT child, parent FROM inheritance") {
                guard let child = r[0].string, let parent = r[1].string else { continue }
                classes[child]?.parents.append(parent)
                classes[parent]?.children.append(child)
            }
        }
        if await db.hasColumns("relationship_type", ["relationshipType", "objectType", "objectClass"]) {
            for r in try await db.rows("SELECT relationshipType, objectType, objectClass FROM relationship_type") {
                guard let id = r[0].string else { continue }
                classes[id]?.objectType = r[1].string ?? ""
                classes[id]?.objectClass = r[2].string ?? ""
            }
        }
        if await db.hasColumns("version", ["fileName", "versionNum"]) {
            data.versions = try await db.rows("SELECT fileName, versionNum FROM version ORDER BY fileName").map { ($0[0].string ?? "", $0[1].string ?? "") }
        }

        // Usage in the personal graph.
        if let graph = await GraphPaths.openIfAvailable(GraphPaths.graph) {
            for table in ["stable_graph", "event_graph"] where await graph.hasColumns(table, ["predicate", "relationshipPredicate", "object"]) {
                for r in (try? await graph.rows("SELECT predicate, count(*) FROM \(table) GROUP BY predicate")) ?? [] {
                    guard let id = r[0].string else { continue }
                    if predicates[id] == nil { predicates[id] = OntologyRow(id: id, label: Ontology.prettify(id), isPredicate: true, defined: false) }
                    predicates[id]!.used += Int(r[1].int ?? 0)
                }
                for r in (try? await graph.rows("SELECT relationshipPredicate, count(*) FROM \(table) WHERE relationshipPredicate != '' GROUP BY relationshipPredicate")) ?? [] {
                    guard let id = r[0].string else { continue }
                    if predicates[id] == nil { predicates[id] = OntologyRow(id: id, label: Ontology.prettify(id), isPredicate: true, defined: false) }
                    predicates[id]!.usedAsField += Int(r[1].int ?? 0)
                }
                for r in (try? await graph.rows("SELECT object, count(*) FROM \(table) WHERE predicate = 'PS1' OR relationshipPredicate = 'PS1' GROUP BY object")) ?? [] {
                    guard let id = r[0].string else { continue }
                    if classes[id] == nil { classes[id] = OntologyRow(id: id, label: Ontology.prettify(id), isPredicate: false, defined: false) }
                    classes[id]!.used += Int(r[1].int ?? 0)
                }
            }
        }
        let order: (OntologyRow, OntologyRow) -> Bool = { a, b in
            if a.total != b.total { return a.total > b.total }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
        data.predicates = predicates.values.sorted(by: order)
        data.classes = classes.values.sorted(by: order)
        return data
    }
}

// MARK: - View

/// (7) Ontology browser: the vocabulary of the graph, defined vs. actually used.
struct OntologySection: View {
    enum Mode: String, CaseIterable, Identifiable { case predicates = "Predicates", classes = "Classes"; var id: String { rawValue } }

    @Environment(\.refreshToken) private var refreshToken
    @State private var mode = Mode.predicates
    @State private var usedOnly = true
    @State private var selected: OntologyRow?

    var body: some View {
        // Read state here so SwiftUI re-evaluates this body (the content closures below run inside AsyncContent).
        let _ = (mode, usedOnly, selected?.id)
        VStack(spacing: 0) {
            ExplainerBar(text: "ontology.db is the graph’s vocabulary: classes (what a node can be) and predicates (what can be said about it), shipped by Apple and identical on every Mac. The usage counts show which parts of that vocabulary your personal graph actually uses.")
            Divider()
            AsyncContent(reloadKey: refreshToken) {
                try await OntologyData.load()
            } content: { data in
                content(data)
            }
            StoreFooter(GraphPaths.ontology, note: "class, predicate, inheritance, predicate_domain, predicate_range, relationship_type")
        }
    }

    @ViewBuilder
    private func content(_ data: OntologyData) -> some View {
        let all = mode == .predicates ? data.predicates : data.classes
        let rows = usedOnly ? all.filter { $0.total > 0 } : all
        VStack(spacing: 0) {
            // Widest variant that fits: the file versions go first, then the segmented control
            // becomes a pop-up, then the checkbox label shortens (inspector open in a minimum window).
            // Nested in pairs: see GraphViewSection.controls.
            ViewThatFits(in: .horizontal) {
                strip(data, segmented: true, versions: true, longToggle: true)
                ViewThatFits(in: .horizontal) {
                    strip(data, segmented: true, versions: false, longToggle: true)
                    ViewThatFits(in: .horizontal) {
                        strip(data, segmented: false, versions: false, longToggle: true)
                        strip(data, segmented: false, versions: false, longToggle: false)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.bar)
            Divider()
        PagedTable(
            rows: rows,
            columns: columns(data),
            searchPrompt: "Filter by code or label",
            reloadKey: AnyHashable([AnyHashable(mode), AnyHashable(usedOnly), AnyHashable(rows.count)]),
            exportName: "graph-ontology-\(mode.rawValue.lowercased())",
            onSelect: { selected = $0.count == 1 ? $0.first : nil }
        )
        }
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected { inspector(selected, data) }
        }
        .onChange(of: mode) { _, _ in selected = nil }
    }

    private func strip(_ data: OntologyData, segmented: Bool, versions: Bool, longToggle: Bool) -> some View {
        let versionText = data.versions.map { "\($0.file.replacingOccurrences(of: ".json", with: "")) \($0.version)" }.joined(separator: " · ")
        return HStack(spacing: 12) {
            Group {
                if segmented {
                    Picker("Vocabulary", selection: $mode) { modeOptions(data) }.pickerStyle(.segmented)
                } else {
                    Picker("Vocabulary", selection: $mode) { modeOptions(data) }.pickerStyle(.menu)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(versionText.isEmpty ? "" : "Ontology files: \(versionText)")
            Toggle(longToggle ? "Only used in your graph" : "Used only", isOn: $usedOnly)
                .toggleStyle(.checkbox)
                .font(.callout)
                .fixedSize()
                .help("Hide vocabulary that your personal graph never uses")
            Spacer(minLength: 8)
            if versions, !versionText.isEmpty {
                Text(versionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func modeOptions(_ data: OntologyData) -> some View {
        Text("Predicates  \(data.predicates.filter { $0.total > 0 }.count) used of \(data.predicates.filter(\.defined).count)").tag(Mode.predicates)
        Text("Classes  \(data.classes.filter { $0.total > 0 }.count) used of \(data.classes.filter(\.defined).count)").tag(Mode.classes)
    }

    private func columns(_ data: OntologyData) -> [PagedColumn<OntologyRow>] {
        let l = data.labels
        var cols: [PagedColumn<OntologyRow>] = [
            PagedColumn<OntologyRow>("Label", id: "label", width: 250, min: 140) { $0.label }
                .cell { row in
                    HStack(spacing: 6) {
                        Text(row.label.isEmpty ? "(no label)" : row.label).font(.callout).lineLimit(1)
                        if !row.defined { TagLabel("not in ontology", tint: .orange) }
                    }
                },
            PagedColumn<OntologyRow>("Code", id: "code", width: 170, monospaced: true, secondary: true) { $0.id },
        ]
        if mode == .predicates {
            cols += [
                PagedColumn<OntologyRow>("As Predicate", id: "used", width: 95, alignment: .trailing) { $0.used == 0 ? "" : Format.count($0.used) },
                PagedColumn<OntologyRow>("As Facet Field", id: "field", width: 100, alignment: .trailing) { $0.usedAsField == 0 ? "" : Format.count($0.usedAsField) },
                PagedColumn<OntologyRow>("Applies To", id: "domain", width: 180) { $0.domain.map(l.classLabel).joined(separator: ", ") },
                PagedColumn<OntologyRow>("Value Type", id: "range", width: 200) { $0.range.map { l.classLabels[$0] ?? $0 }.joined(separator: ", ") },
                PagedColumn<OntologyRow>("Max", id: "max", width: 50, alignment: .trailing, secondary: true) { $0.maxCount.map(String.init) ?? "" },
            ]
        } else {
            cols += [
                PagedColumn<OntologyRow>("Rows Using It", id: "used", width: 100, alignment: .trailing) { $0.used == 0 ? "" : Format.count($0.used) },
                PagedColumn<OntologyRow>("Parent Classes", id: "parents", width: 220) { $0.parents.map(l.classLabel).joined(separator: ", ") },
                PagedColumn<OntologyRow>("Subclasses", id: "children", width: 80, alignment: .trailing) { $0.children.isEmpty ? "" : "\($0.children.count)" },
                PagedColumn<OntologyRow>("Facet Object", id: "object", width: 180) { row in
                    row.objectType.isEmpty ? "" : (row.objectType == "class" ? l.classLabel(row.objectClass) : row.objectClass)
                },
            ]
        }
        return cols
    }

    private func inspector(_ row: OntologyRow, _ data: OntologyData) -> some View {
        let l = data.labels
        return InspectorPage(title: row.label.isEmpty ? row.id : row.label, subtitle: row.isPredicate ? "Predicate \(row.id)" : "Class \(row.id)", onClose: { selected = nil }) {
            KeyValueGrid([
                KeyValueItem("Code", row.id, monospaced: true),
                KeyValueItem("Defined in ontology", row.defined ? "Yes" : "No — used by the graph only"),
                KeyValueItem(row.isPredicate ? "Rows as predicate" : "Rows using it", Format.count(row.used)),
            ] + (row.isPredicate ? [
                KeyValueItem("Rows as facet field", Format.count(row.usedAsField)),
                KeyValueItem("Max values", row.maxCount.map { $0 == 0 ? "unlimited" : String($0) } ?? "—"),
            ] : []))
            if row.total == 0 {
                Text("Defined by Apple’s ontology but not used anywhere in your personal graph.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if row.isPredicate {
                chips("Applies to (domain)", row.domain.map { "\(l.classLabel($0))" })
                chips("Value type (range)", row.range.map { l.classLabels[$0] ?? $0 })
            } else {
                chips("Parent classes", row.parents.map(l.classLabel))
                chips("Subclasses", row.children.map(l.classLabel).sorted())
                if !row.objectType.isEmpty {
                    KeyValueGrid([KeyValueItem("Facet object", row.objectType == "class" ? "a \(l.classLabel(row.objectClass)) node" : "a \(row.objectClass) literal")])
                }
            }
        }
    }

    @ViewBuilder
    private func chips(_ title: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                InspectorGroupTitle("\(title) · \(values.count)")
                FlowLayout { ForEach(Array(values.prefix(80).enumerated()), id: \.offset) { _, v in TagLabel(v) } }
            }
        }
    }
}
