import SwiftUI
import Charts
import DossierCore

/// (1) Summary — how many copies of your mail text exist where, how big they are, how
/// the indexed mail is spread over the years and which pipelines have run over it.
struct SummaryView: View {
    struct Loaded: Sendable {
        let sets: [CascadeSetSummary]
        let report: DocumentProcessingReport
        let kuzuFile: URL?
        let kuzuAvailability: Availability
        let kuzuBytes: Int64
        let collections: Int
        let streams: [HarvestStream]
        let kvsKeys: Int
        let kvsStores: Int
        let spotlightIndexBytes: Int64
        let kgNodes: Int

        func set(_ kind: CascadeKind) -> CascadeSetSummary? { sets.first { $0.info.kind == kind } }
    }

    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.navigate) private var navigate
    @ObservedObject private var index = MailIndexMonitor.shared

    var body: some View {
        let token = refreshToken
        AsyncContent(reloadKey: token) {
            await CascadeLinks.shared.sync(token: token)
            let sets = await CascadeLinks.shared.allSummaries()
            let report = await SpotlightStore.documentProcessing(cascade: sets)
            let quick = KuzuScanner.quickLook()
            let streams = HarvestStore.streams()
            let kvs = await KVSStore.stores()
            let indexBytes = SpotlightFiles.indexDirectories().map(\.bytes).reduce(0, +)
            var nodes = 0
            if let db = await SQLiteDB.sharedIfAvailable(MSPaths.knowledgeGraph), await db.tableExists("Node") { nodes = await db.rowCount(of: "Node") ?? 0 }
            return Loaded(
                sets: sets, report: report, kuzuFile: quick.file, kuzuAvailability: quick.availability, kuzuBytes: quick.bytes + quick.walBytes,
                collections: quick.collections.count, streams: streams, kvsKeys: kvs.map(\.keys).reduce(0, +), kvsStores: kvs.count,
                spotlightIndexBytes: indexBytes, kgNodes: nodes
            )
        } content: { loaded in
            if loaded.sets.isEmpty && loaded.report.pipelines.isEmpty && loaded.kuzuFile == nil {
                if case .inaccessible(let reason) = Paths.probe(MSPaths.cascadeRoot) {
                    StatePlaceholder.inaccessible(reason)
                } else {
                    StatePlaceholder.missing("None of the mail and search index stores exist on this Mac.")
                }
            } else {
                page(loaded)
            }
        }
        .onAppear {
            index.sync(token: refreshToken)
            if SnapshotReadiness.isSnapshotting { index.start() }
        }
        .onChange(of: refreshToken) { _, token in index.sync(token: token) }
    }

    @ViewBuilder
    private func page(_ loaded: Loaded) -> some View {
        ScrollPage {
            Text("Mail keeps your messages in its own store. Independently of that, macOS copies their text into several derived stores so that Spotlight, Siri and on-device language models can search and reason over them. This page counts those copies.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            StatTileRow(tiles(loaded))

            SectionHeader("Where Copies of Your Mail Text Live", subtitle: "Every derived store that holds message text, headers or vectors computed from them", symbol: "square.on.square")
            InfoTable(
                columns: [.init(title: "Store"), .init(title: "Holds", alignment: .trailing), .init(title: "Size", alignment: .trailing)],
                rows: copies(loaded)
            )
            .card()

            if !loaded.report.years.isEmpty {
                SectionHeader(
                    "Indexed Mail by Year",
                    subtitle: "Message dates of the \(Format.count(loaded.report.years.map(\.count).reduce(0, +))) items the document pipeline tracks for “\(loaded.report.yearsSourceLabel)”",
                    symbol: "calendar"
                )
                YearChart(years: loaded.report.years).frame(height: 220).card()
            }

            SectionHeader("What the Messages Say About Your Correspondents", subtitle: "Decodes every mail entity once, in memory only", symbol: "person.2")
            MailInsightsPanel(index: index)

            if !loaded.report.pipelines.isEmpty {
                SectionHeader("Pipelines Run Over Your Documents", subtitle: "From the document-processing bookkeeping of Spotlight", symbol: "gearshape.2")
                PipelineTable(pipelines: loaded.report.pipelines).card()
            }

            let other = loaded.sets.filter { !$0.info.kind.isPlainText && $0.info.kind != .mail && ($0.live ?? 0) > 0 }
                .sorted { ($0.live ?? 0) > ($1.live ?? 0) }.prefix(14)
            if !other.isEmpty {
                SectionHeader("Everything Else Mirrored as Entities", subtitle: "Live items per Cascade set, apart from mail", symbol: "tray.full")
                BarChartView(uniqueBars(other.map { ($0.info.title, Double($0.live ?? 0)) })).card()
            }
            StoreFooter(MSPaths.cascadeRoot, note: "Cascade sets · plus CoreSpotlight, HybridSearch and Biome streams")
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func uniqueBars(_ items: [(String, Double)]) -> [ChartBar] {
        var seen: [String: Int] = [:]
        return items.map { title, value in
            let n = (seen[title] ?? 0) + 1
            seen[title] = n
            return ChartBar(n == 1 ? title : "\(title) (\(n))", value)
        }
    }

    private func tiles(_ loaded: Loaded) -> [Stat] {
        var out: [Stat] = []
        if let mail = loaded.set(.mail) {
            out.append(Stat("Mail Entities", Format.compact(mail.live ?? 0), caption: "messages + attachments", symbol: "envelope", tint: .blue))
        }
        if let body = loaded.set(.mailBody) {
            out.append(Stat("Body Text Copies", Format.compact(body.live ?? 0), caption: "\(Format.compact(body.contents ?? 0)) distinct texts", symbol: "text.alignleft", tint: .indigo))
        }
        if let text = loaded.set(.attachmentText) {
            out.append(Stat("Attachment Texts", Format.compact(text.live ?? 0), caption: "of \(Format.compact(loaded.set(.attachment)?.live ?? 0)) attachments", symbol: "paperclip", tint: .teal))
        }
        if loaded.kuzuAvailability.isAvailable {
            out.append(Stat("Semantic Index", Format.bytes(loaded.kuzuBytes), caption: "\(loaded.collections) collections", symbol: "point.3.connected.trianglepath.dotted", tint: .purple))
        }
        if loaded.report.embeddings > 0 {
            out.append(Stat("Embedded Documents", Format.compact(loaded.report.embeddings), caption: loaded.report.embeddingDimensions.map { "\($0)-dimensional vectors" } ?? "vectors", symbol: "circle.hexagongrid", tint: .pink))
        }
        let total = loaded.sets.reduce(Int64(0)) { $0 + $1.info.bytes } + loaded.kuzuBytes
            + (FileProbe.info(MSPaths.stateStore) != nil ? FileProbe.databaseSize(MSPaths.stateStore) + FileProbe.databaseSize(MSPaths.cachedResultStore) : 0)
            + loaded.spotlightIndexBytes
        out.append(Stat("Derived Stores", Format.bytes(total), caption: "on disk, all of the below", symbol: "internaldrive", tint: .orange))
        return out
    }

    private func copies(_ loaded: Loaded) -> [InfoTable.Row] {
        var rows: [InfoTable.Row] = []
        func setRow(_ kind: CascadeKind, _ what: String) {
            guard let s = loaded.set(kind) else { return }
            let holds = s.live.map { Format.count($0) + " " + what } ?? s.availability.label
            rows.append(.init(id: s.id, symbol: kind.symbol, cells: [s.info.title, holds, Format.bytes(s.info.bytes)], caption: s.info.explanation))
        }
        setRow(.mail, "entities")
        setRow(.mailBody, "bodies")
        setRow(.attachment, "files")
        setRow(.attachmentText, "texts")
        if loaded.kuzuFile != nil {
            let embedded = loaded.report.embeddings
            rows.append(.init(
                id: "kuzu", symbol: "point.3.connected.trianglepath.dotted",
                cells: ["Hybrid Search Index", loaded.kuzuAvailability.isAvailable ? (embedded > 0 ? "\(Format.count(embedded)) embedded documents" : "keyword + vector index") : loaded.kuzuAvailability.label, loaded.kuzuAvailability.isAvailable ? Format.bytes(loaded.kuzuBytes) : "—"],
                caption: "The semantic index of hybridsearchd (a Kuzu graph / vector database): keyword postings, embedding vectors and a JSON payload per message and attachment, including body text."
            ))
        }
        if loaded.report.stateAvailability.isAvailable {
            rows.append(.init(
                id: "state", symbol: "gearshape.2",
                cells: ["Document Processing State", "\(Format.count(loaded.report.totalItems)) tracked items", Format.bytes(FileProbe.databaseSize(MSPaths.stateStore))],
                caption: "Bookkeeping only (hashes, dates, per-pipeline status) — no text, but it records which of your documents were embedded, indexed or scanned for events and identity documents."
            ))
        }
        if loaded.report.cacheAvailability.isAvailable {
            rows.append(.init(
                id: "cache", symbol: "circle.hexagongrid",
                cells: ["Embedding Result Cache", "\(Format.count(loaded.report.cachedEmbeddings)) cached results", Format.bytes(FileProbe.databaseSize(MSPaths.cachedResultStore))],
                caption: "Recently computed embedding vectors keyed by item, kept so unchanged text is not embedded twice."
            ))
        }
        if loaded.spotlightIndexBytes > 0 {
            rows.append(.init(
                id: "cs", symbol: "magnifyingglass",
                cells: ["Spotlight App-Content Index", "full-text index", Format.bytes(loaded.spotlightIndexBytes)],
                caption: "CoreSpotlight's classic index of items donated by apps (Mail among them), split by data-protection class. Binary index files; not decoded here."
            ))
        }
        for name in ["ProactiveHarvesting.Mail", "TextUnderstanding.Output.Document"] {
            guard let s = loaded.streams.first(where: { $0.name == name }), s.live + s.deleted > 0 else { continue }
            rows.append(.init(
                id: name, symbol: s.symbol,
                cells: [name == "ProactiveHarvesting.Mail" ? "Harvest Queue (Mail)" : "Text-Understanding Output", "\(Format.count(s.live)) live, \(Format.count(s.deleted)) erased", Format.bytes(s.bytes)],
                caption: s.explanation
            ))
        }
        return rows
    }
}

/// Vertical bars, one per year.
struct YearChart: View {
    let years: [(year: Int, count: Int)]

    var body: some View {
        Chart {
            ForEach(years, id: \.year) { item in
                BarMark(x: .value("Year", String(item.year)), y: .value("Messages", item.count))
                    .foregroundStyle(ChartPalette.color(0).gradient)
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        if years.count <= 20 {
                            Text(Format.compact(item.count)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Int.self) { Text(Format.compact(v)) } }
            }
        }
        .chartXAxisLabel("Year the message was sent", alignment: .center)
        .chartYAxisLabel("Messages")
    }
}

/// Pipelines with a progress bar each.
struct PipelineTable: View {
    let pipelines: [PipelineStat]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                header("Pipeline"); header("Progress"); header("Processed").gridColumnAlignment(.trailing)
                header("Results").gridColumnAlignment(.trailing); header("Errors").gridColumnAlignment(.trailing)
            }
            .padding(.bottom, 6)
            ForEach(pipelines) { p in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Name and tags on one line while they fit; otherwise the tags move
                        // below, so the name is never hyphenated into a narrow column.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { name(p).fixedSize(); tags(p) }
                            VStack(alignment: .leading, spacing: 3) { name(p); tags(p) }
                        }
                        Text(p.purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if p.isActive {
                            ProgressView(value: Double(p.processed), total: Double(max(p.items, 1)))
                                .tint(p.errors > 0 ? .orange : .accentColor)
                                .frame(width: 110)
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    Text(p.isActive ? MSFormat.fraction(p.processed, of: p.items) : "—").font(.callout.monospacedDigit())
                    Text(p.isActive ? Format.count(p.withResult) : "—").font(.callout.monospacedDigit())
                    Text(p.errors > 0 ? Format.count(p.errors) : "—").font(.callout.monospacedDigit()).foregroundStyle(p.errors > 0 ? .orange : .secondary)
                }
                .padding(.vertical, 7)
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func name(_ p: PipelineStat) -> some View {
        Text(p.name).font(.callout.weight(.medium)).foregroundStyle(p.isActive ? .primary : .secondary)
            .lineLimit(1).truncationMode(.middle).help(p.name)
    }

    @ViewBuilder
    private func tags(_ p: PipelineStat) -> some View {
        if !p.isActive { TagLabel("never ran") }
        if let d = p.destination { TagLabel("→ " + d, tint: .purple) }
    }
}

/// Top senders / year spread from the in-memory mail index, with build progress.
struct MailInsightsPanel: View {
    @ObservedObject var index: MailIndexMonitor

    var body: some View {
        Group {
            switch index.status.phase {
            case .ready:
                if let insights = index.insights { ready(insights) } else { ProgressView().controlSize(.small) }
            case .building:
                JobProgress(
                    title: "Decoding mail entities…",
                    detail: "\(MSFormat.fraction(index.status.done, of: index.status.total)) · \(Format.duration(index.status.seconds))",
                    fraction: index.status.fraction, onCancel: { index.cancel() }
                )
            case .idle, .cancelled:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(index.status.phase == .cancelled ? "Analysis cancelled." : "Not analysed yet.").font(.callout)
                        Text("Sender and subject are stored inside compressed entity records, so ranking your correspondents means decompressing every message entity once. This takes a few seconds, runs in the background and keeps the result in memory only.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Analyse Mail Entities") { index.start() }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            }
        }
        .card()
        .onAppear { index.refresh() }
    }

    @ViewBuilder
    private func ready(_ insights: MailIndex.Insights) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                fact("Messages", Format.count(insights.messages))
                fact("Attachment Entities", Format.count(insights.attachments))
                fact("Distinct Senders", Format.count(insights.distinctSenders))
                fact("Period", insights.range.map { "\(DossierDate.day($0.lowerBound)) – \(DossierDate.day($0.upperBound))" } ?? "—")
                Spacer()
                Text("decoded in \(Format.duration(index.status.seconds))").font(.caption).foregroundStyle(.tertiary)
            }
            Divider()
            Text("Most Frequent Senders").font(.subheadline.weight(.medium))
            BarChartView(
                insights.topSenders.prefix(15).map { ChartBar($0.name.isEmpty ? $0.address : "\($0.name) · \($0.address)", Double($0.count)) },
                labelSensitivity: .sensitive
            )
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
    }
}
