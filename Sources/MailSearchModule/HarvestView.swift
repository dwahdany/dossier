import SwiftUI
import DossierCore

/// (5) Harvesting pipeline — the Biome streams through which content travels on its way
/// into the derived stores: the harvest queues (full copies waiting to be analysed), the
/// text-understanding output (processed documents, extracted events) and the deletion log.
struct HarvestView: View {
    @Environment(\.deepLink) private var deepLink
    @State private var selectedStream: String?
    @State private var selected: HarvestRow?
    @State private var compact = false
    @State private var widthClass = MSLayout.WidthClass.regular

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selectedStream, selected)
        AsyncContent {
            let availability = Paths.probe(Paths.biomeRestrictedStreams)
            if case .inaccessible(let reason) = availability { throw DossierError.inaccessible(reason) }
            let streams = HarvestStore.streams()
            if streams.isEmpty { throw DossierError.missing("No harvesting or text-understanding streams exist on this Mac.") }
            return streams
        } content: { streams in
            content(streams)
        }
    }

    private func current(_ streams: [HarvestStream]) -> HarvestStream? {
        if let selectedStream, let hit = streams.first(where: { $0.id == selectedStream }) { return hit }
        return streams.first { $0.live > 0 } ?? streams.first
    }

    @ViewBuilder
    private func content(_ streams: [HarvestStream]) -> some View {
        let active = current(streams)
        VStack(spacing: 0) {
            PageIntro(
                text: "Before your content lands in the indexes it passes through these streams. Harvest queues hold complete copies (a mail message with headers and body) only until the analysis daemons have consumed them — the erased slots remain countable. What the analysis produced, and every later request to forget a document, is logged alongside.",
                stats: tiles(streams), compact: compact
            )
            Divider()
            HStack(spacing: 0) {
                List(selection: Binding(get: { active?.id }, set: { if let id = $0 { selectedStream = id; selected = nil } })) {
                    ForEach(HarvestGroup.allCases, id: \.self) { group in
                        let members = streams.filter { $0.group == group }
                        if !members.isEmpty {
                            Section(group.rawValue) {
                                ForEach(members) { s in
                                    MasterRow(
                                        symbol: s.symbol, title: s.title,
                                        subtitle: s.live == 0 && s.deleted > 0 ? "\(Format.count(s.deleted)) consumed" : nil,
                                        count: s.live > 0 ? Format.count(s.live) : (s.deleted > 0 ? "0" : "empty"),
                                        dimmed: s.live == 0
                                    )
                                    .tag(s.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                .frame(width: widthClass == .narrow ? 215 : 260)
                Divider()
                if let active {
                    StreamPane(stream: active, selected: $selected).id(active.id)
                }
            }
        }
        .tracksCompactHeight($compact)
        .tracksWidthClass($widthClass)
        .onChange(of: deepLink?.nonce, initial: true) { _, _ in
            guard let link = deepLink, !link.payload.isEmpty, streams.contains(where: { $0.id == link.payload }) else { return }
            selectedStream = link.payload
        }
    }

    private func tiles(_ streams: [HarvestStream]) -> [Stat] {
        func sum(_ group: HarvestGroup, _ key: KeyPath<HarvestStream, Int>) -> Int { streams.filter { $0.group == group }.map { $0[keyPath: key] }.reduce(0, +) }
        let queued = sum(.queue, \.live), consumed = sum(.queue, \.deleted)
        var out = [
            Stat("In Harvest Queues", Format.count(queued), caption: "awaiting analysis", symbol: "tray.and.arrow.down", tint: queued > 0 ? .orange : .green),
            Stat("Consumed & Erased", Format.count(consumed), caption: "slots already wiped", symbol: "eraser", tint: .secondary),
            Stat("Documents Read", Format.count(streams.first { $0.name == "TextUnderstanding.Output.Document" }?.live ?? 0), caption: "in the output stream", symbol: "doc.text.magnifyingglass", tint: .blue),
            Stat("Events Extracted", Format.count(streams.first { $0.name == "TextUnderstanding.Output.Event" }?.live ?? 0), caption: "from your documents", symbol: "calendar.badge.clock", tint: .purple),
            Stat("Deletions Logged", Format.count(sum(.deletions, \.live)), caption: "forget requests", symbol: "trash", tint: .red),
        ]
        let searches = streams.first { $0.name == "Mail.Search.Query" }?.live ?? 0
        if searches > 0 { out.append(Stat("Mail Searches", Format.count(searches), caption: "queries recorded", symbol: "magnifyingglass", tint: .teal)) }
        return out
    }
}

private struct StreamPane: View {
    let stream: HarvestStream
    @Binding var selected: HarvestRow?

    var body: some View {
        let stream = self.stream
        VStack(spacing: 0) {
            PaneHeader(symbol: stream.symbol, title: stream.title, subtitle: stream.explanation) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Format.count(stream.live)) live · \(Format.count(stream.deleted)) erased").font(.callout.monospacedDigit())
                    Text(stream.range.map { DossierDate.range($0) } ?? Format.bytes(stream.bytes)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if stream.live == 0 {
                StatePlaceholder(
                    title: stream.deleted > 0 ? "Queue Is Empty" : "No Records",
                    symbol: stream.deleted > 0 ? "checkmark.circle" : stream.symbol,
                    message: stream.deleted > 0
                        ? "All \(Format.count(stream.deleted)) records written to this stream have been consumed and erased; only their empty slots remain."
                        : "Nothing has been written to this stream on this Mac."
                )
            } else {
                AsyncContent(reloadKey: stream.id) {
                    HarvestStore.rows(stream)
                } isEmpty: { $0.isEmpty } content: { rows in
                    VStack(spacing: 0) {
                        if stream.group == .deletions, rows.count > 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("When Documents Were Forgotten").font(.subheadline.weight(.medium))
                                TimelineHeatmap(.dayByHour(rows.map(\.when), days: 14), tint: .red)
                            }
                            .padding(12)
                            Divider()
                        }
                        PagedTable(
                            rows: rows,
                            columns: columns,
                            searchPrompt: "Filter records",
                            reloadKey: "\(stream.id)|\(rows.count)",
                            exportName: stream.name,
                            onSelect: { selected = $0.count == 1 ? $0.first : nil }
                        )
                    }
                }
                .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                    if let selected { RecordInspector(stream: stream, row: selected) { self.selected = nil } }
                }
            }
            StoreFooter(stream.stream.url, note: "Biome SEGB stream")
        }
    }

    private var columns: [PagedColumn<HarvestRow>] {
        let level = stream.sensitivity
        let (first, second, third): (String, String, String)
        switch stream.name {
        case "ProactiveHarvesting.Mail": (first, second, third) = ("Subject", "From", "Account")
        case "TextUnderstanding.Output.Document": (first, second, third) = ("Title", "Author", "Source App")
        case "TextUnderstanding.Output.Event": (first, second, third) = ("Event", "When", "Extraction")
        case "TextUnderstanding.Deletions.Document": (first, second, third) = ("App", "Item", "Reason")
        case "Mail.Search.Query": (first, second, third) = ("Query", "Context", "")
        default: (first, second, third) = ("Content", "Details", "More")
        }
        var out: [PagedColumn<HarvestRow>] = [
            PagedColumn("Recorded", id: "when", width: 150, min: 130) { DossierDate.sortable($0.when) },
            PagedColumn(first, id: "title", width: 340, min: 140, sensitivity: level) { $0.title },
            PagedColumn(second, id: "subtitle", width: 250, min: 100, sensitivity: level) { $0.subtitle },
        ]
        if !third.isEmpty { out.append(PagedColumn(third, id: "extra", width: 170, sensitivity: .personal, secondary: true) { $0.extra }) }
        out.append(PagedColumn("Size", id: "bytes", width: 80, alignment: .trailing, secondary: true) { Format.bytes($0.bytes) })
        out.append(PagedColumn("Device", id: "device", width: 80, secondary: true, hiddenByDefault: true) { $0.remote ? "synced" : "this Mac" })
        return out
    }
}

private struct RecordInspector: View {
    let stream: HarvestStream
    let row: HarvestRow
    let onClose: () -> Void

    var body: some View {
        let stream = self.stream, row = self.row
        AsyncContent(reloadKey: row.id) {
            try HarvestStore.detail(stream, row: row)
        } content: { detail in
            InspectorPage(title: row.title, subtitle: stream.title, sensitivity: stream.sensitivity, onClose: onClose) {
                KeyValueGrid(detail.items)
                if let text = detail.text, !text.isEmpty {
                    InspectorGroupTitle(detail.textLabel)
                    RevealText(label: detail.textLabel, reloadKey: row.id) { text }
                }
                if !detail.headers.isEmpty {
                    InspectorDisclosure("Headers (\(detail.headers.count))") {
                        KeyValueGrid(detail.headers, valueLineLimit: 4)
                    }
                }
                if !detail.nodes.isEmpty {
                    InspectorDisclosure("Raw Record") {
                        DataTreeView(detail.nodes, sensitivity: stream.sensitivity, expandedDepth: 1).frame(height: 320)
                    }
                }
            }
        }
    }
}
