import SwiftUI
import DossierCore

// MARK: - Badges

/// One capsule per source bit set in `mask` ("Contacts", "Photos People", …).
struct SourceBadges: View {
    let mask: Int64
    let catalog: SourceCatalog
    var limit: Int = 6
    /// When true the chip count adapts to the offered width (table cells): as many chips as
    /// fit, up to `limit`, followed by a "+N" chip for the rest. Nothing is drawn outside
    /// the cell.
    var fitting = false

    var body: some View {
        let bits = catalog.bits(of: mask)
        if fitting {
            let most = min(limit, bits.count)
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: most, through: 0, by: -1)), id: \.self) { shown in
                    row(bits, shown: shown)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .help(catalog.titles(mask: mask).joined(separator: ", "))
        } else {
            row(bits, shown: min(limit, bits.count))
        }
    }

    private func row(_ bits: [Int], shown: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(bits.prefix(shown), id: \.self) { bit in
                TagLabel(catalog.title(bit: bit), tint: catalog.tint(bit: bit))
                    .help(help(bit))
            }
            if bits.count > shown { TagLabel(shown == 0 ? "\(bits.count) sources" : "+\(bits.count - shown)") }
        }
    }

    private func help(_ bit: Int) -> String {
        let kind = catalog.kind(bit: bit)
        let explanation = kind.flatMap { SourceCatalog.known[$0]?.explanation } ?? "Source system not identified on this Mac."
        return "Source bit \(bit)\(kind.map { " · \($0)" } ?? ""): \(explanation)"
    }
}

/// Small confidence indicator: a tiny meter plus percentage.
struct ConfidencePill: View {
    let value: Double

    var body: some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 26, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: max(2, 26 * min(max(value, 0), 1)), height: 4)
                }
            Text(GraphFormat.confidence(value))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("Confidence the system assigns to this fact: \(Format.number(value, maxDigits: 4))")
        .fixedSize()
    }

    private var tint: Color { value >= 0.95 ? .green : (value >= 0.75 ? .blue : .orange) }
}

/// Round icon for an entity kind.
struct KindIcon: View {
    let kind: EntityKind
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(kind.tint)
            .frame(width: size, height: size)
            .background(kind.tint.opacity(0.14), in: Circle())
    }
}

/// Explanatory banner used at the top of sections ("what is this store?").
struct ExplainerBar: View {
    let text: String
    var symbol: String = "info.circle"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

// MARK: - Statements

/// Statements grouped by predicate, each with decoded values, source badges and confidence.
struct StatementsView: View {
    let statements: [Statement]
    let index: GraphIndex
    var onOpen: ((Int64) -> Void)?
    /// Statements per predicate shown before "Show all".
    var collapseAfter: Int = 6

    @State private var expanded: Set<String> = []

    private struct PredicateGroup: Identifiable {
        let id: String
        let label: String
        let statements: [Statement]
    }

    private var groups: [PredicateGroup] {
        var order: [String] = []
        var map: [String: [Statement]] = [:]
        for s in statements {
            if map[s.predicate] == nil { order.append(s.predicate) }
            map[s.predicate, default: []].append(s)
        }
        return order
            .map { PredicateGroup(id: $0, label: index.ontology.predicateLabel($0), statements: map[$0] ?? []) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(group.label.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .kerning(0.4)
                        Text(group.id)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        if group.statements.count > 1 {
                            Text("\(group.statements.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    let showAll = expanded.contains(group.id) || group.statements.count <= collapseAfter
                    ForEach(showAll ? group.statements : Array(group.statements.prefix(collapseAfter))) { statement in
                        StatementRow(statement: statement, index: index, onOpen: onOpen)
                    }
                    if !showAll {
                        Button("Show all \(group.statements.count)") { expanded.insert(group.id) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }
}

/// One statement: value (or facet fields), badges, confidence.
struct StatementRow: View {
    let statement: Statement
    let index: GraphIndex
    var onOpen: ((Int64) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if statement.isFacet {
                        if statement.fields.isEmpty {
                            Text("(no fields)").font(.callout).foregroundStyle(.tertiary)
                        }
                        ForEach(statement.fields) { field in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(index.ontology.predicateLabel(field.predicate))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 70, alignment: .leading)
                                value(field.object, predicate: field.predicate)
                            }
                        }
                    } else if let object = statement.simpleValue {
                        value(object, predicate: statement.predicate)
                    }
                }
                Spacer(minLength: 4)
                ConfidencePill(value: statement.confidence)
            }
            FlowLayout(spacing: 4, lineSpacing: 4) {
                if let type = statement.typeClass {
                    TagLabel(index.ontology.classLabel(type).replacingOccurrences(of: " relationship type", with: ""))
                        .help("Facet type \(type)")
                }
                ForEach(index.sources.bits(of: statement.sources), id: \.self) { bit in
                    TagLabel(index.sources.title(bit: bit), tint: index.sources.tint(bit: bit))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(help)
    }

    private var help: String {
        var lines = ["Updated \(DossierDate.medium(DossierDate.cocoa(statement.timestamp)))"]
        if statement.isFacet { lines.append("Facet id \(statement.relationshipId)") }
        if !statement.sourceRecords.isEmpty { lines.append("\(statement.sourceRecords.count) source record(s)") }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func value(_ object: String, predicate: String) -> some View {
        let text = index.display(object, predicate: predicate)
        let level = GraphFormat.sensitivity(predicate: predicate, object: object, ontology: index.ontology)
        if let ref = GraphRef.parse(object) {
            Button {
                onOpen?(ref)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: (index.entities[ref]?.kind ?? .other).symbol).imageScale(.small)
                    Text(text).lineLimit(2)
                }
                .font(.callout)
            }
            .buttonStyle(.link)
            .disabled(onOpen == nil)
            .sensitive(.sensitive)
            .help("Node \(object)")
        } else {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(4)
                .sensitive(level)
        }
    }
}

// MARK: - Entity detail

/// Full detail of one node: identity header, statements by predicate, incoming references,
/// superseded triples and the source records it was merged from.
struct EntityDetailView: View {
    let entityID: Int64
    var onOpen: ((Int64) -> Void)?

    private struct Loaded: Sendable {
        let detail: EntityDetail
        let index: GraphIndex
    }

    var body: some View {
        AsyncContent(reloadKey: entityID) {
            let index = try await GraphStore.shared.index()
            let detail = try await GraphStore.shared.detail(id: entityID)
            return Loaded(detail: detail, index: index)
        } content: { loaded in
            content(loaded.detail, loaded.index)
        }
    }

    @ViewBuilder
    private func content(_ detail: EntityDetail, _ index: GraphIndex) -> some View {
        let info = detail.info
        HStack(alignment: .center, spacing: 10) {
            KindIcon(kind: info.kind, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled).sensitive(.sensitive)
                HStack(spacing: 5) {
                    Text(index.ontology.classLabel(info.classID).capitalized).font(.caption).foregroundStyle(.secondary)
                    if info.isOwner { TagLabel("This is you", tint: .accentColor) }
                    if detail.fromEventGraph { TagLabel("event graph", tint: .red) }
                }
            }
        }
        KeyValueGrid([
            KeyValueItem("Node id", GraphRef.string(info.id), monospaced: true),
            KeyValueItem("Class", "\(index.ontology.classLabel(info.classID)) (\(info.classID.isEmpty ? "none" : info.classID))"),
            KeyValueItem("Statements", "\(Format.count(detail.statements.count)) from \(Format.count(info.rowCount)) rows"),
            KeyValueItem("Last updated", DossierDate.medium(info.updatedDate)),
        ])
        if info.sources != 0 {
            VStack(alignment: .leading, spacing: 6) {
                InspectorGroupTitle("Contributing sources")
                FlowLayout {
                    ForEach(index.sources.bits(of: info.sources), id: \.self) { bit in
                        TagLabel(index.sources.title(bit: bit), tint: index.sources.tint(bit: bit))
                    }
                }
            }
        }
        if detail.statements.isEmpty {
            Text("No statements are stored for this node.").font(.callout).foregroundStyle(.secondary)
        } else {
            StatementsView(statements: detail.statements, index: index, onOpen: onOpen)
        }
        if !detail.incoming.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                InspectorGroupTitle("Referenced by (\(detail.incoming.count))")
                ForEach(Array(detail.incoming.prefix(60).enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button {
                            onOpen?(t.subject)
                        } label: {
                            Text(index.name(t.subject) ?? "Node \(t.subject)").font(.callout).lineLimit(1)
                        }
                        .buttonStyle(.link)
                        .disabled(onOpen == nil)
                        .sensitive(.sensitive)
                        Text(relation(t, index))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if detail.incoming.count > 60 {
                    Text("…and \(detail.incoming.count - 60) more").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        if !detail.expired.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(detail.expired.prefix(80).enumerated()), id: \.offset) { _, t in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(index.ontology.predicateLabel(t.predicate)).font(.caption).foregroundStyle(.secondary)
                                if !t.relPredicate.isEmpty {
                                    Text("› " + index.ontology.predicateLabel(t.relPredicate)).font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                Text(DossierDate.short(DossierDate.cocoa(t.timestamp))).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(index.display(t.object, predicate: t.relPredicate.isEmpty ? t.predicate : t.relPredicate))
                                .font(.callout)
                                .strikethrough(color: .secondary)
                                .lineLimit(2)
                                .sensitive(GraphFormat.sensitivity(predicate: t.relPredicate.isEmpty ? t.predicate : t.relPredicate, object: t.object, ontology: index.ontology))
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                InspectorGroupTitle("Superseded triples (\(detail.expired.count))")
            }
            .help("Rows moved to expired_\(detail.fromEventGraph ? "event" : "stable")_graph when a newer pipeline run replaced them.")
        }
        if !detail.sourceRecords.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(detail.sourceRecords.prefix(200), id: \.self) { record in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let kind = SourceRecord.kind(record) {
                                TagLabel(SourceCatalog.title(kind: kind), tint: SourceCatalog.known[kind]?.tint ?? .secondary)
                            }
                            Text(record.split(separator: ":", maxSplits: 1).last.map(String.init) ?? record)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .sensitive(.personal)
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                InspectorGroupTitle("Source records (\(detail.sourceRecords.count))")
            }
        }
    }

    private func relation(_ t: Triple, _ index: GraphIndex) -> String {
        let p = index.ontology.predicateLabel(t.predicate)
        return t.relPredicate.isEmpty ? p : "\(p) › \(index.ontology.predicateLabel(t.relPredicate))"
    }
}

/// Inspector wrapper around ``EntityDetailView`` with in-place navigation history.
struct EntityInspector: View {
    let entityID: Int64
    var subtitle: String = "Knowledge graph node"
    let onClose: () -> Void
    /// Called when the user follows a reference; nil keeps navigation inside the inspector.
    var onOpen: ((Int64) -> Void)?

    @State private var stack: [Int64] = []

    private var current: Int64 { stack.last ?? entityID }

    var body: some View {
        InspectorPage(title: "Node", subtitle: subtitle, onClose: onClose) {
            if !stack.isEmpty {
                Button {
                    stack.removeLast()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            EntityDetailView(entityID: current) { id in
                if let onOpen { onOpen(id) } else if id != current { stack.append(id) }
            }
            .id(current)
        }
        .onChange(of: entityID) { _, _ in stack = [] }
    }
}

// MARK: - Generic rows (dynamic-schema tables)

/// A row of display strings for tables whose columns are only known at runtime.
struct GenericRow: Identifiable, Sendable {
    let id: Int
    let cells: [String]
}

struct GenericTableData: Sendable {
    var columns: [String]
    var rows: [GenericRow]
    /// Columns whose values are personal (blurred in Privacy Mode).
    var sensitive: Set<String> = []
    var truncated = false

    static let empty = GenericTableData(columns: [], rows: [])
}

/// In-memory table over ``GenericTableData`` (bounded result sets only).
struct GenericTable: View {
    let data: GenericTableData
    var prompt: String = "Filter"
    var exportName: String = "export"
    var emptyTitle: String = "No Rows"
    var widths: [String: CGFloat] = [:]
    var onSelect: ((GenericRow?) -> Void)?

    var body: some View {
        PagedTable(
            rows: data.rows,
            columns: data.columns.enumerated().map { i, name in
                PagedColumn<GenericRow>(
                    name, id: "\(i)|\(name)", width: widths[name] ?? 150,
                    alignment: .leading, sensitivity: data.sensitive.contains(name) ? .sensitive : .low
                ) { $0.cells.indices.contains(i) ? $0.cells[i] : "" }
            },
            searchPrompt: prompt,
            reloadKey: AnyHashable([AnyHashable(data.rows.count), AnyHashable(data.columns)]),
            exportName: exportName,
            emptyTitle: emptyTitle,
            onSelect: { rows in onSelect?(rows.count == 1 ? rows.first : nil) }
        )
    }
}

// MARK: - Adaptive strip controls

/// Offers its content `reserve` points less width than it was offered, but reports the
/// content's own size. Used around a `ViewThatFits` in a shared strip so the wide variant is
/// only chosen while `reserve` points remain for the strip's other controls (a filter field).
/// A zero-width proposal is passed on as zero, so the minimum is the content's true minimum.
struct ReservingLayout: Layout {
    var reserve: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sub = subviews.first else { return .zero }
        return sub.sizeThatFits(ProposedViewSize(width: proposal.width.map { max(0, $0 - reserve) }, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A picker that is a segmented control while the strip has room for it (plus `reserve`
/// points for its neighbours) and collapses to a pop-up button otherwise. Its minimum width
/// is the pop-up button's, so it never forces a section wider than the window.
struct AdaptivePicker<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    var reserve: CGFloat = 0
    @ViewBuilder let options: () -> Options

    var body: some View {
        ReservingLayout(reserve: reserve) {
            ViewThatFits(in: .horizontal) {
                Picker(title, selection: $selection, content: options)
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                Picker(title, selection: $selection, content: options)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
            }
        }
    }
}
