import SwiftUI
import DossierCore

/// (4) Spotlight knowledge — the identity graph Spotlight keeps about you and the people
/// around you, the bookkeeping of the document-processing pipelines, and the loose
/// property-list files of the Spotlight index.
struct SpotlightView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case graph = "Identity Graph", processing = "Document Processing", files = "Index Files"
        var id: String { rawValue }
    }

    @Environment(\.deepLink) private var deepLink
    @State private var mode: Mode = .graph
    @State private var linkedNode: Int64?

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (mode, linkedNode)
        VStack(spacing: 0) {
            // The caption is dropped before it would be truncated; the segmented control
            // becomes a pop-up menu before it would be clipped.
            ViewThatFits(in: .horizontal) {
                modeBar(segmented: true, captioned: true)
                modeBar(segmented: true, captioned: false)
                modeBar(segmented: false, captioned: false)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(.bar)
            Divider()
            switch mode {
            case .graph: IdentityGraphPane(linkedNode: $linkedNode)
            case .processing: DocumentProcessingPane()
            case .files: SpotlightFilesPane()
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) { _, _ in
            guard let link = deepLink else { return }
            if link.payload.hasPrefix("node:"), let id = Int64(link.payload.dropFirst(5)) { mode = .graph; linkedNode = id }
            if link.payload == "processing" { mode = .processing }
            if link.payload == "files" { mode = .files }
        }
    }

    @ViewBuilder
    private func modeBar(segmented: Bool, captioned: Bool) -> some View {
        HStack(spacing: 12) {
            let picker = Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            if segmented { picker.pickerStyle(.segmented).fixedSize() } else { picker.pickerStyle(.menu).fixedSize() }
            Spacer(minLength: 0)
            if captioned {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
    }

    private var caption: String {
        switch mode {
        case .graph: return "Who Spotlight thinks you are, and how your identifiers connect"
        case .processing: return "Which pipelines ran over which of your documents"
        case .files: return "Small state files of the Spotlight index, decoded as-is"
        }
    }
}

// MARK: - Identity graph

private struct IdentityGraphPane: View {
    @Binding var linkedNode: Int64?
    @State private var selected: KGNode?
    @State private var kind = ""
    @State private var didAutoSelect = false
    @State private var compact = false

    var body: some View {
        AsyncContent {
            try await KnowledgeGraphStore.overview()
        } isEmpty: { $0.nodes.isEmpty } content: { overview in
            content(overview)
        }
    }

    @ViewBuilder
    private func content(_ overview: KGOverview) -> some View {
        let kinds = Array(Set(overview.nodes.map(\.kind))).sorted()
        let rows = kind.isEmpty ? overview.nodes : overview.nodes.filter { $0.kind == kind || $0.labels.contains(kind) }
        VStack(spacing: 0) {
            PageIntro(
                text: "Spotlight maintains a small graph that ties your identifiers together: one node for you (“personUser”), nodes for every e-mail address, phone number, name and contact card it has seen, scored links saying which identifier belongs to which persona and app domain, and dated links from you to the people and names you dealt with (calendar invitations, calls). It is how a search can understand that several addresses are the same person.",
                stats: [
                    Stat("Nodes", Format.count(overview.nodeCount), caption: overview.truncated ? "first \(Format.count(KnowledgeGraphStore.nodeLimit)) loaded" : "identifiers and personas", symbol: "circle.grid.cross", tint: .blue),
                    Stat("Links", Format.count(overview.edgeCount), caption: "\(overview.relationshipCounts.count) relationship types", symbol: "arrow.triangle.branch", tint: .purple),
                    Stat("Your Node", overview.user.map { "\(Format.count($0.outDegree + $0.inDegree)) links" } ?? "not found", caption: "personUser", symbol: "person.crop.circle", tint: .green),
                    Stat("E-mail Addresses", Format.count(overview.labelCounts.first { $0.label == "emailAddress" }?.count ?? 0), symbol: "envelope", tint: .teal),
                    Stat("Phone Numbers", Format.count(overview.labelCounts.first { $0.label == "phoneNumber" }?.count ?? 0), symbol: "phone", tint: .orange),
                    Stat("Names", Format.count(overview.labelCounts.first { $0.label == "name" || $0.label == "displayName" }?.count ?? 0), symbol: "textformat", tint: .pink),
                ],
                compact: compact
            )
            Divider()
            PagedTable(
                rows: rows,
                columns: [
                    PagedColumn<KGNode>("Value", id: "value", width: 320, min: 140, sensitivity: .sensitive) { $0.value },
                    PagedColumn("Kind", id: "kind", width: 160) { $0.kind }.cell { node in
                        TagLabel(node.kind, tint: node.isUser ? .green : .secondary)
                    },
                    PagedColumn("Name", id: "name", width: 180, sensitivity: .sensitive) { [$0.firstName, $0.lastName].filter { !$0.isEmpty }.joined(separator: " ") },
                    PagedColumn("Links Out", id: "out", width: 80, alignment: .trailing) { String(format: "%6d", $0.outDegree) },
                    PagedColumn("Links In", id: "in", width: 80, alignment: .trailing) { String(format: "%6d", $0.inDegree) },
                    PagedColumn("All Labels", id: "labels", width: 300, secondary: true, hiddenByDefault: true) { $0.labels.joined(separator: ", ") },
                    PagedColumn("Node", id: "id", width: 70, alignment: .trailing, monospaced: true, secondary: true, hiddenByDefault: true) { String(format: "%8d", $0.id) },
                ],
                searchPrompt: "Filter identifiers",
                reloadKey: "\(rows.count)|\(kind)",
                exportName: "spotlight-identity-graph",
                onSelect: { rows in
                    if rows.count == 1 { selected = rows.first } else if didAutoSelect { selected = nil }
                }
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Picker("Kind", selection: $kind) {
                        Text("All Kinds (\(Format.count(overview.nodes.count)))").tag("")
                        ForEach(kinds, id: \.self) { k in
                            Text("\(k) (\(Format.count(overview.labelCounts.first { $0.label == k }?.count ?? 0)))").tag(k)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    Spacer(minLength: 0)
                    if let user = overview.user {
                        Button("Show My Node") { selected = user }.controlSize(.small).fixedSize()
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.bar)
                .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5) }
            }
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { NodeInspector(node: selected) { self.selected = nil } }
            }
            StoreFooter(MSPaths.knowledgeGraph, note: "Node · Edge · NodeValue · EdgeValue")
        }
        // This pane sits below the 46-pt mode bar of the section.
        .tracksCompactHeight($compact, below: MSLayout.compactHeight - 47)
        .onAppear {
            // Open on the owner's node: that is the identity graph most people look for.
            if !didAutoSelect, selected == nil { selected = overview.user }
            didAutoSelect = true
        }
        .onChange(of: linkedNode, initial: true) { _, id in
            if let id, let node = overview.nodes.first(where: { $0.id == id }) { selected = node; linkedNode = nil }
        }
    }
}

private struct NodeInspector: View {
    let node: KGNode
    let onClose: () -> Void

    var body: some View {
        let id = node.id
        InspectorPage(title: node.isUser ? "You (\(node.value))" : node.value, subtitle: node.kind + " · node \(node.id)", sensitivity: .sensitive, onClose: onClose) {
            KeyValueGrid([
                KeyValueItem("Value", node.value, sensitivity: .sensitive),
                KeyValueItem("Name", [node.firstName, node.lastName].filter { !$0.isEmpty }.joined(separator: " "), sensitivity: .sensitive),
                KeyValueItem("Labels", node.labels.joined(separator: ", ")),
                KeyValueItem("Links", "\(node.outDegree) out, \(node.inDegree) in"),
            ].filter { !$0.value.isEmpty })
            AsyncContent(reloadKey: id) {
                try await KnowledgeGraphStore.edges(of: id, limit: 20_000)
            } isEmpty: { $0.isEmpty } content: { edges in
                edgeList(edges)
            }
            .frame(minHeight: 120)
        }
    }

    @ViewBuilder
    private func edgeList(_ edges: [KGEdge]) -> some View {
        let groups = Dictionary(grouping: edges) { ($0.outgoing ? "→ " : "← ") + ($0.relationship.isEmpty ? "linked" : $0.relationship) }
        // Small groups first: identity links (name, phone, e-mail) are few and telling,
        // dated interaction links and per-reference bookkeeping run into the thousands.
        let keys = groups.keys.sorted { (groups[$0]?.count ?? 0, $0) < (groups[$1]?.count ?? 0, $1) }
        VStack(alignment: .leading, spacing: 14) {
            ForEach(keys, id: \.self) { key in
                let members = groups[key] ?? []
                let peers = Peer.make(members)
                VStack(alignment: .leading, spacing: 6) {
                    InspectorGroupTitle(peers.count == members.count ? "\(key) (\(Format.count(members.count)))" : "\(key) (\(Format.count(members.count)) links, \(Format.count(peers.count)) nodes)")
                    ForEach(peers.prefix(40)) { peer in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(peer.edge.otherValue.isEmpty ? "node \(peer.edge.otherID)" : peer.edge.otherValue)
                                    .font(.callout).lineLimit(1).truncationMode(.middle)
                                    .sensitive(.sensitive)
                                Text(caption(peer)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            if peer.count > 1 { Text("×\(Format.count(peer.count))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    }
                    if peers.count > 40 { Text("and \(Format.count(peers.count - 40)) more nodes").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// All links of one kind between the inspected node and one other node.
private struct Peer: Identifiable {
    var id: Int64 { edge.otherID }
    let edge: KGEdge
    let count: Int
    let domains: [String]
    let latest: Double?

    static func make(_ edges: [KGEdge]) -> [Peer] {
        var order: [Int64] = []
        var grouped: [Int64: [KGEdge]] = [:]
        for e in edges {
            if grouped[e.otherID] == nil { order.append(e.otherID) }
            grouped[e.otherID, default: []].append(e)
        }
        return order.compactMap { id -> Peer? in
            guard let list = grouped[id], let first = list.first else { return nil }
            var domains: [String] = []
            for d in list.map(\.domain) where !d.isEmpty && !domains.contains(d) { domains.append(d) }
            return Peer(edge: first, count: list.count, domains: domains, latest: list.compactMap(\.score).max())
        }.sorted { ($0.count, $1.id) > ($1.count, $0.id) }
    }
}

extension NodeInspector {
    /// "emailAddress · com.apple.CalendarUI · last 3 Nov 2026" — for date-valued links the
    /// numeric attribute holds a Cocoa timestamp instead of a score.
    fileprivate func caption(_ peer: Peer) -> String {
        var parts: [String] = []
        if !peer.edge.otherKind.isEmpty { parts.append(peer.edge.otherKind) }
        if !peer.domains.isEmpty { parts.append(peer.domains.prefix(2).joined(separator: ", ") + (peer.domains.count > 2 ? " +\(peer.domains.count - 2)" : "")) }
        if let score = peer.latest {
            if score > 100_000_000, peer.edge.relationship.lowercased().contains("date") {
                parts.append((peer.count > 1 ? "latest " : "") + DossierDate.day(DossierDate.cocoa(score)))
            } else {
                parts.append("score " + Format.number(score, maxDigits: 2))
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Document processing

private struct DocumentProcessingPane: View {
    var body: some View {
        AsyncContent {
            let sets = await CascadeLinks.shared.allSummaries()
            let report = await SpotlightStore.documentProcessing(cascade: sets)
            if case .inaccessible(let reason) = report.stateAvailability { throw DossierError.inaccessible(reason) }
            if report.pipelines.isEmpty { throw DossierError.missing("Spotlight's document-processing store (DocumentProcessing/PipelineStorage) does not exist on this Mac.") }
            return report
        } content: { report in
            ScrollPage {
                Text("Every document an app donates to the system index (mail messages and attachments above all) is run through a set of pipelines: embedding for semantic search, indexing into the hybrid search database, and scans for events, orders, identity documents and reply suggestions. This store is their ledger — it holds no text, only which item was processed by which pipeline, when, and with what outcome.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                StatTileRow([
                    Stat("Tracked Documents", Format.compact(report.totalItems), caption: "\(report.sources.count) donating sources", symbol: "doc.on.doc", tint: .blue),
                    Stat("Pipelines", "\(report.pipelines.filter(\.isActive).count) of \(report.pipelines.count)", caption: "have processed items", symbol: "gearshape.2", tint: .purple),
                    Stat("Embedded", Format.compact(report.embeddings), caption: report.embeddingDimensions.map { "\($0)-d vectors" } ?? "documents", symbol: "circle.hexagongrid", tint: .pink),
                    Stat("Embedding Cache", Format.compact(report.cachedEmbeddings), caption: "results kept on disk", symbol: "clock.arrow.circlepath", tint: .orange),
                    Stat("Errors", Format.count(report.errors.map(\.count).reduce(0, +)), caption: "items that failed a pipeline", symbol: "exclamationmark.triangle", tint: .yellow),
                ])
                SectionHeader("Pipelines", subtitle: "Processed items per pipeline, with results and failures", symbol: "gearshape.2")
                PipelineTable(pipelines: report.pipelines).card()

                if !report.years.isEmpty {
                    SectionHeader("Tracked Documents by Year", subtitle: "Priority date (message date) of the items from “\(report.yearsSourceLabel)”", symbol: "calendar")
                    YearChart(years: report.years).frame(height: 200).card()
                }

                SectionHeader("Donating Sources", subtitle: "The store names sources by a numeric hash; labels are inferred by matching item counts to the Cascade sets", symbol: "tray.and.arrow.down")
                InfoTable(
                    columns: [.init(title: "Source"), .init(title: "Items", alignment: .trailing), .init(title: "Document Dates", alignment: .trailing)],
                    rows: report.sources.map { s in
                        .init(id: String(s.id), symbol: "tray", cells: [s.label, Format.count(s.items), DossierDate.range(s.range)], caption: "source \(s.id)")
                    }
                )
                .card()

                if !report.completeness.isEmpty {
                    SectionHeader("Indexing Completeness per App", subtitle: "What System Settings reports as indexing progress" + (report.completenessComputed.map { " · computed \(DossierDate.relative($0))" } ?? ""), symbol: "chart.bar")
                    InfoTable(
                        columns: [.init(title: "App"), .init(title: "Known Items", alignment: .trailing), .init(title: "Processed", alignment: .trailing), .init(title: "Complete", alignment: .trailing), .init(title: "Rank", alignment: .trailing)],
                        rows: report.completeness.map { c in
                            .init(id: c.bundle, symbol: "app", cells: [c.bundle, Format.count(c.knownItems), c.eligible > 0 ? MSFormat.fraction(c.processed, of: c.eligible) : "—", Format.percent(c.percent, digits: 0), c.rank],
                                  caption: c.needingDonation > 0 ? "\(Format.count(c.needingDonation)) items still to be donated · \(c.classification)" : c.classification)
                        }
                    )
                    .card()
                }

                if !report.errors.isEmpty {
                    SectionHeader("Failures", subtitle: "Items a pipeline could not process, by error", symbol: "exclamationmark.triangle")
                    InfoTable(
                        columns: [.init(title: "Error"), .init(title: "Pipeline", alignment: .trailing), .init(title: "Items", alignment: .trailing)],
                        rows: report.errors.prefix(20).map { e in
                            .init(id: e.id, symbol: "xmark.octagon", cells: ["\(e.domain) (\(e.code))", e.pipeline, Format.count(e.count)])
                        }
                    )
                    .card()
                }
                StoreFooter(MSPaths.stateStore, note: "pipeline · item · pipeline_item · destination").clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Loose files

private struct SpotlightFilesPane: View {
    struct Loaded: Sendable {
        let files: [SpotlightFile]
        let directories: [DirectorySize]
    }
    struct DirectorySize: Sendable, Identifiable {
        var id: String { name }
        let name: String
        let bytes: Int64
        let files: Int
    }

    @State private var selected: String?
    @State private var widthClass = MSLayout.WidthClass.regular

    var body: some View {
        AsyncContent {
            Loaded(files: SpotlightFiles.list(), directories: SpotlightFiles.indexDirectories().map { DirectorySize(name: $0.name, bytes: $0.bytes, files: $0.files) })
        } isEmpty: { $0.files.isEmpty && $0.directories.isEmpty } content: { loaded in
            let current = loaded.files.first { $0.id == selected } ?? loaded.files.first
            HStack(spacing: 0) {
                List(selection: Binding(get: { current?.id }, set: { selected = $0 })) {
                    ForEach(groups(loaded.files), id: \.self) { group in
                        Section(group) {
                            ForEach(loaded.files.filter { $0.group == group }) { file in
                                MasterRow(
                                    symbol: file.url.pathExtension == "json" ? "curlybraces" : "doc.badge.gearshape", title: file.name,
                                    subtitle: file.name == "meCardInfo.plist" ? file.url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: "NSFileProtection", with: "") : nil,
                                    count: Format.bytes(file.bytes)
                                )
                                    .tag(file.id)
                            }
                        }
                    }
                    if !loaded.directories.isEmpty {
                        Section("App-Content Index (not decoded)") {
                            ForEach(loaded.directories) { dir in
                                MasterRow(symbol: "folder", title: dir.name.replacingOccurrences(of: "NSFileProtection", with: ""), subtitle: "\(Format.count(dir.files)) files", count: Format.bytes(dir.bytes), dimmed: true)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                .frame(width: widthClass == .narrow ? 250 : 320)
                Divider()
                if let current {
                    VStack(spacing: 0) {
                        PaneHeader(symbol: "doc.text.magnifyingglass", title: current.name, subtitle: current.explanation) {
                            Text(current.modified.map { "modified " + DossierDate.relative($0) } ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        AsyncContent(reloadKey: current.id) {
                            try SpotlightFiles.tree(current)
                        } content: { nodes in
                            DataTreeView(nodes, sensitivity: .personal, expandedDepth: 3)
                        }
                        StoreFooter(current.url)
                    }
                } else {
                    StatePlaceholder(title: "No Files", symbol: "doc", message: "No previewable Spotlight state files were found.")
                }
            }
            .tracksWidthClass($widthClass)
        }
    }

    private func groups(_ files: [SpotlightFile]) -> [String] {
        var out: [String] = []
        for f in files where !out.contains(f.group) { out.append(f.group) }
        return out
    }
}
