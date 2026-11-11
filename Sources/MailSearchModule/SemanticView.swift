import SwiftUI
import DossierCore

/// (3) Semantic index — the hybrid (keyword + vector) search database of hybridsearchd.
/// The Kuzu file cannot be queried, so this section shows what a bounded scan of the
/// memory-mapped file recovers (complete JSON payloads and their key schema), next to the
/// collection list and the embedding counts from the document-processing bookkeeping.
struct SemanticView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case payloads = "Payload Samples", schema = "Payload Schema", collections = "Collections"
        var id: String { rawValue }
    }

    struct Context: Sendable {
        let sets: [CascadeSetSummary]
        let report: DocumentProcessingReport
        let quick: QuickLook
    }

    struct QuickLook: Sendable {
        let file: URL?
        let availability: Availability
        let bytes: Int64
        let walBytes: Int64
        let header: KuzuHeader?
        let collections: [KuzuCollection]
    }

    @Environment(\.refreshToken) private var refreshToken
    @ObservedObject private var monitor = KuzuMonitor.shared
    @State private var mode: Mode = .payloads
    @State private var kindFilter: KuzuPayloadKind? = .mail
    @State private var selected: KuzuPayload?
    @State private var compact = false

    var body: some View {
        let token = refreshToken
        AsyncContent(reloadKey: token) {
            await CascadeLinks.shared.sync(token: token)
            let sets = await CascadeLinks.shared.allSummaries()
            let report = await SpotlightStore.documentProcessing(cascade: sets)
            let q = KuzuScanner.quickLook()
            return Context(sets: sets, report: report, quick: QuickLook(file: q.file, availability: q.availability, bytes: q.bytes, walBytes: q.walBytes, header: q.header, collections: q.collections))
        } content: { context in
            if context.quick.file == nil || context.quick.availability == .missing {
                StatePlaceholder.missing("The hybrid search index (com.apple.hybridsearchd) does not exist on this Mac. It is created when on-device semantic search is enabled.")
            } else if case .inaccessible(let reason) = context.quick.availability {
                StatePlaceholder.inaccessible(reason)
            } else {
                content(context)
            }
        }
        // The scan reads the whole multi-GB file, so it runs only on request (Scan / Rescan);
        // appearing or refreshing merely picks up the state of an earlier scan.
        .onAppear { monitor.sync(token: refreshToken) }
        .onChange(of: refreshToken) { _, token in monitor.sync(token: token) }
    }

    @ViewBuilder
    private func content(_ context: Context) -> some View {
        let report = monitor.report
        VStack(spacing: 0) {
            PageIntro(
                text: "hybridsearchd keeps one database that answers both keyword and meaning-based (“semantic”) queries over your mail and other documents. It is a Kuzu graph / vector store, not SQLite. Dossier cannot query it, but each indexed item carries a JSON payload — the message as handed to the indexer — and payloads that sit whole inside a storage page can be read back by scanning the file.",
                stats: tiles(context, report), compact: compact
            ) {
                scanStrip(report, fileBytes: context.quick.bytes + context.quick.walBytes)
            }
            Divider()
            // Segmented control while it fits beside the kind filter, a pop-up menu otherwise.
            ViewThatFits(in: .horizontal) {
                modeBar(report, segmented: true)
                modeBar(report, segmented: false)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.bar)
            Divider()
            switch mode {
            case .payloads: payloadTable(report)
            case .schema: schemaTable(report)
            case .collections: collectionTable(context, report)
            }
            if let file = context.quick.file { StoreFooter(file, note: "Kuzu database + .wal, read through mmap") }
        }
        .tracksCompactHeight($compact)
    }

    @ViewBuilder
    private func modeBar(_ report: KuzuReport, segmented: Bool) -> some View {
        HStack(spacing: 12) {
            let picker = Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            if segmented { picker.pickerStyle(.segmented).fixedSize() } else { picker.pickerStyle(.menu).fixedSize() }
            if mode == .payloads {
                Picker("Kind", selection: $kindFilter) {
                    Text("All Kinds").tag(KuzuPayloadKind?.none)
                    ForEach(KuzuPayloadKind.allCases, id: \.self) { kind in
                        Text("\(kind.rawValue)s (\(Format.count(report.kindCounts[kind] ?? 0)))").tag(KuzuPayloadKind?.some(kind))
                    }
                }
                .pickerStyle(.menu).fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private func tiles(_ context: Context, _ report: KuzuReport) -> [Stat] {
        var out: [Stat] = [
            Stat("Index File", Format.bytes(context.quick.bytes), caption: context.quick.header.map { "\(Format.compact($0.pageCount)) pages · v\($0.storageVersion)" } ?? "unknown header", symbol: "internaldrive", tint: .purple),
        ]
        if context.report.embeddings > 0 {
            out.append(Stat("Embedded Documents", Format.compact(context.report.embeddings), caption: "have a vector", symbol: "circle.hexagongrid", tint: .pink))
        }
        if let dims = context.report.embeddingDimensions {
            out.append(Stat("Vector Size", "\(dims)", caption: "float16 dimensions", symbol: "ruler", tint: .teal))
        }
        out.append(Stat("Embedding Cache", Format.compact(context.report.cachedEmbeddings), caption: "recent results kept", symbol: "clock.arrow.circlepath", tint: .orange))
        let complete = (report.kindCounts[.mail] ?? 0) + (report.kindCounts[.attachment] ?? 0)
        out.append(Stat("Readable Payloads", report.phase == .idle ? "—" : Format.count(complete), caption: report.payloadMarkers > 0 ? "of \(Format.compact(report.payloadMarkers)) visible" : "complete JSON", symbol: "curlybraces", tint: .blue, sensitivity: .low))
        out.append(Stat("Collections", "\(context.quick.collections.count)", caption: "\(populated(context, report).count) populated", symbol: "square.stack.3d.up", tint: .indigo))
        return out
    }

    @ViewBuilder
    private func scanStrip(_ report: KuzuReport, fileBytes: Int64) -> some View {
        switch report.phase {
        case .scanning:
            JobProgress(
                title: "Scanning the index file for readable payloads…",
                detail: "\(Format.bytes(report.scannedBytes)) of \(Format.bytes(report.totalBytes))", fraction: report.fraction, onCancel: { monitor.cancel() }
            )
            .card(padding: compact ? 6 : 10)
        case .finished, .cancelled:
            HStack(spacing: 10) {
                Image(systemName: report.phase == .finished ? "checkmark.circle" : "pause.circle").foregroundStyle(.secondary)
                Text(report.phase == .finished
                     ? "Scanned \(Format.bytes(report.totalBytes)) in \(Format.duration(report.seconds)): \(Format.count(report.candidates)) candidates, \(Format.count(report.kindCounts.values.reduce(0, +))) complete JSON objects (\(report.walPayloads) in the write-ahead log). Results are kept in memory only."
                        + (report.stale ? " Scanned before the last refresh — the file may have changed since." : "")
                     : "Scan cancelled after \(Format.bytes(report.scannedBytes)); the lists below are partial.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 2 : nil)
                Spacer(minLength: 8)
                Button("Rescan") { monitor.rescan() }.controlSize(.small).fixedSize()
            }
        case .failed(let message), .inaccessible(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
        case .idle where compact:
            let explanation = "Not scanned yet. Reading back the payloads means scanning the whole index file once (\(Format.bytes(report.totalBytes > 0 ? report.totalBytes : fileBytes))) — a few seconds, read-only, results kept in memory only."
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                Text(explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(explanation)
                Spacer(minLength: 8)
                Button("Scan Index File") { monitor.start() }.controlSize(.small).fixedSize()
            }
        case .idle:
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not scanned yet.").font(.callout)
                    Text("Reading back the payloads means scanning the whole index file once (\(Format.bytes(report.totalBytes > 0 ? report.totalBytes : fileBytes))). It takes a few seconds, is read-only, can be cancelled, and keeps its results in memory only.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Scan Index File") { monitor.start() }.fixedSize()
            }
            .card(padding: 10)
        case .missing:
            EmptyView()
        }
    }

    // MARK: Payloads

    private func payloadTable(_ report: KuzuReport) -> some View {
        let rows = report.payloads.filter { kindFilter == nil || $0.kind == kindFilter }
            .sorted { ($0.date ?? .distantPast, $0.offset) > ($1.date ?? .distantPast, $1.offset) }
        return PagedTable(
            rows: rows,
            columns: [
                PagedColumn<KuzuPayload>("Kind", id: "kind", width: 150) { $0.kind.rawValue },
                PagedColumn("Title", id: "title", width: 360, min: 140, sensitivity: .sensitive) { $0.title },
                PagedColumn("From / Type", id: "sub", width: 240, sensitivity: .sensitive) { $0.subtitle },
                PagedColumn("Date", id: "date", width: 150) { $0.date.map { DossierDate.sortable($0) } ?? "" },
                PagedColumn("Text", id: "text", width: 80, alignment: .trailing) { $0.textLength > 0 ? Format.count($0.textLength) : "" },
                PagedColumn("Keys", id: "keys", width: 50, alignment: .trailing, secondary: true) { String($0.keyCount) },
                PagedColumn("JSON", id: "len", width: 80, alignment: .trailing, secondary: true) { Format.bytes($0.length) },
                PagedColumn("Offset", id: "offset", width: 110, alignment: .trailing, monospaced: true, secondary: true, hiddenByDefault: true) { ($0.inWAL ? "wal+" : "") + String($0.offset) },
            ],
            searchPrompt: "Filter payloads",
            reloadKey: "\(rows.count)|\(kindFilter?.rawValue ?? "all")|\(report.phase == .scanning)",
            exportName: "hybrid-search-payloads",
            emptyTitle: report.phase == .scanning ? "Scanning…" : (report.phase == .idle ? "Not Scanned Yet" : "No Complete Payloads"),
            onSelect: { selected = $0.count == 1 ? $0.first : nil }
        )
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected { PayloadInspector(payload: selected) { self.selected = nil } }
        }
    }

    // MARK: Schema

    private func schemaTable(_ report: KuzuReport) -> some View {
        let totals = report.kindCounts
        return PagedTable(
            rows: report.keyStats,
            columns: [
                PagedColumn<KuzuKeyStat>("Payload Kind", id: "kind", width: 170) { $0.kind.rawValue },
                PagedColumn("Key", id: "key", width: 260, monospaced: true) { $0.key },
                PagedColumn("Value Type", id: "type", width: 180) { $0.type },
                PagedColumn("Seen In", id: "count", width: 90, alignment: .trailing) { Format.count($0.count) },
                PagedColumn("Share", id: "share", width: 80, alignment: .trailing, secondary: true) { stat in
                    let total = totals[stat.kind] ?? 0
                    return total > 0 ? Format.percent(Double(stat.count) / Double(total), digits: 0) : ""
                },
            ],
            searchPrompt: "Filter keys",
            reloadKey: "\(report.keyStats.count)",
            exportName: "hybrid-search-schema",
            emptyTitle: report.phase == .scanning ? "Scanning…" : (report.phase == .idle ? "Not Scanned Yet" : "No Keys Observed")
        )
    }

    // MARK: Collections

    struct CollectionRow: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let hasNodes: Bool
        let source: String
        let items: Int?
        let payloads: Int
        let status: String
        let what: String
    }

    /// Maps a collection (bookmark) name to the Cascade set that feeds it.
    private func sourceSet(_ name: String, _ sets: [CascadeSetSummary]) -> CascadeSetSummary? {
        switch name {
        case "Mail": return sets.first { $0.info.kind == .mail }
        case "MailAttachment": return sets.first { $0.info.kind == .attachment }
        case "Contacts": return sets.first { $0.info.stream == "Contacts.Contact" }
        case "SiriTranscriptConversation": return sets.first { $0.info.stream == "Siri.Transcript.Conversation" }
        default:
            if name.hasPrefix("TextUnderstanding") {
                let suffix = String(name.dropFirst("TextUnderstanding".count))
                return sets.first { $0.info.stream == "TextUnderstanding.Extracted." + suffix }
            }
            return nil
        }
    }

    private func describe(_ name: String) -> String {
        switch name {
        case "Mail": return "Mail messages: metadata, body text and embeddings."
        case "MailAttachment": return "Text extracted from mail attachments."
        case "Contacts": return "Address-book names for resolving people."
        case "SiriTranscript", "SiriTranscriptConversation": return "Transcripts of conversations with Siri."
        case "WritingAssistantProfiles": return "Writing-style profiles for the writing assistant."
        default:
            if name.hasPrefix("TextUnderstanding") {
                return "Facts extracted from your text: " + CascadeSetInfo.spaced(String(name.dropFirst("TextUnderstanding".count))).lowercased() + "."
            }
            if name.hasSuffix("Test") { return "Internal test collection." }
            return "Index collection."
        }
    }

    private func collectionRows(_ context: Context, _ report: KuzuReport) -> [CollectionRow] {
        context.quick.collections.map { c in
            let set = sourceSet(c.name, context.sets)
            let payloads = c.name == "Mail" ? (report.kindCounts[.mail] ?? 0) : (c.name == "MailAttachment" ? (report.kindCounts[.attachment] ?? 0) : 0)
            let status: String
            if let live = set?.live { status = live > 0 || payloads > 0 ? "Populated" : "Empty" }
            else if payloads > 0 { status = "Populated" }
            else { status = "No local source" }
            return CollectionRow(name: c.name, hasNodes: c.hasNodes, source: set?.info.stream ?? "", items: set?.live, payloads: payloads, status: status, what: describe(c.name))
        }
    }

    private func populated(_ context: Context, _ report: KuzuReport) -> [CollectionRow] {
        collectionRows(context, report).filter { $0.status == "Populated" }
    }

    private func collectionTable(_ context: Context, _ report: KuzuReport) -> some View {
        let rows = collectionRows(context, report).sorted { ($0.status == "Populated" ? 0 : 1, $0.name) < ($1.status == "Populated" ? 0 : 1, $1.name) }
        return PagedTable(
            rows: rows,
            columns: [
                PagedColumn<CollectionRow>("Collection", id: "name", width: 270) { $0.name },
                PagedColumn("Status", id: "status", width: 120) { $0.status }.cell { row in
                    TagLabel(row.status, tint: row.status == "Populated" ? .green : .secondary)
                },
                PagedColumn("Source Items", id: "items", width: 100, alignment: .trailing) { $0.items.map { Format.count($0) } ?? "—" },
                PagedColumn("Payloads Read", id: "payloads", width: 110, alignment: .trailing) { $0.payloads > 0 ? Format.count($0.payloads) : "—" },
                PagedColumn("Fed From Set", id: "source", width: 280, monospaced: true, secondary: true) { $0.source },
                PagedColumn("What It Indexes", id: "what", width: 360) { $0.what },
                PagedColumn("Node Table", id: "nodes", width: 90, secondary: true, hiddenByDefault: true) { $0.hasNodes ? "yes" : "no" },
            ],
            searchPrompt: "Filter collections",
            reloadKey: "\(rows.count)|\(report.kindCounts.values.reduce(0, +))",
            exportName: "hybrid-search-collections"
        )
    }
}

/// Decoded JSON of one payload, read back from the mapped file.
private struct PayloadInspector: View {
    let payload: KuzuPayload
    let onClose: () -> Void

    struct Loaded: Sendable {
        let nodes: [DataNode]
        let items: [KeyValueItem]
        let text: String?
    }

    var body: some View {
        let payload = self.payload
        AsyncContent(reloadKey: payload.id) {
            guard let data = await KuzuScanner.shared.payloadData(payload) else {
                throw DossierError.message("The index file changed since the scan; rescan to read this payload.")
            }
            guard let value = PlistDecoder.decodeJSON(data) else { throw DossierError.message("This payload is no longer valid JSON.") }
            var items: [KeyValueItem] = []
            func add(_ label: String, _ text: String?, _ level: Sensitivity = .sensitive) {
                if let text, !text.isEmpty { items.append(KeyValueItem(label, text, sensitivity: level, id: "\(items.count)")) }
            }
            func people(_ v: PlistValue?) -> String? {
                guard let v else { return nil }
                let list = v.array ?? [v]
                return list.map { p in
                    let name = p["displayName"]?.string ?? "", mail = p["emailAddress"]?.string ?? ""
                    return name.isEmpty ? mail : (mail.isEmpty ? name : "\(name) <\(mail)>")
                }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            add("Subject", value["subject"]?.string)
            add("Name", value["name"]?.string)
            add("From", people(value["sender"]))
            add("To", people(value["to"] ?? value["recipients"]))
            add("Cc", people(value["cc"]))
            for key in ["dateSent", "dateReceived"] {
                if let n = value[key]?.double, let guess = DossierDate.guess(n) { add(key == "dateSent" ? "Sent" : "Received", DossierDate.medium(guess.date), .personal) }
            }
            add("Category", value["mailCategory"]?.string, .personal)
            add("Mailboxes", value["mailboxes"]?.array?.compactMap(\.string).joined(separator: "\n"), .personal)
            add("Type", value["type"]?.string ?? value["contentType"]?.string, .low)
            add("Path", value["path"]?.string ?? value["contentURL"]?.string)
            add("Source", value["sourceBundleIdentifier"]?.string, .low)
            add("Location", (payload.inWAL ? "write-ahead log, " : "") + "byte \(Format.count(payload.offset)), \(Format.bytes(payload.length))", .low)
            let text = value["body"]?.string ?? value["textContent"]?.string ?? value["bodySnippet"]?.string ?? value["textContentSnippet"]?.string
            return Loaded(nodes: [DataNode.from(value, key: "payload")], items: items, text: text)
        } content: { loaded in
            InspectorPage(title: payload.title.isEmpty ? payload.kind.rawValue : payload.title, subtitle: payload.kind.rawValue + " · JSON payload", sensitivity: .sensitive, onClose: onClose) {
                KeyValueGrid(loaded.items)
                if let text = loaded.text {
                    InspectorGroupTitle("Indexed Text")
                    RevealText(label: "Text", reloadKey: payload.id) { text }
                }
                InspectorGroupTitle("Payload")
                DataTreeView(loaded.nodes, sensitivity: .sensitive, expandedDepth: 1).frame(height: 360)
            }
        }
    }
}
