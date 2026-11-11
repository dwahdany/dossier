import SwiftUI
import DossierCore

/// (2) Cascade entities — browser over the sets under `~/Library/Biome/sets`: pick a set
/// on the left, page through its live items, inspect one on the right.
struct CascadeView: View {
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @ObservedObject private var index = MailIndexMonitor.shared

    @State private var selectedSet: String?
    @State private var listFilter = ""
    @State private var selected: Selection?
    @State private var year: Int?
    @State private var tableFilter = ""
    @State private var widthClass = MSLayout.WidthClass.regular

    struct Selection: Hashable {
        let set: String
        let seq: Int64
    }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selectedSet, listFilter, selected, year, tableFilter)
        let token = refreshToken
        AsyncContent(reloadKey: token) {
            await CascadeLinks.shared.sync(token: token)
            let availability = Paths.probe(MSPaths.cascadeRoot)
            if case .inaccessible(let reason) = availability { throw DossierError.inaccessible(reason) }
            if case .missing = availability { throw DossierError.missing("This Mac has no Cascade sets (~/Library/Biome/sets).") }
            return await CascadeLinks.shared.allSummaries()
        } isEmpty: { $0.isEmpty } content: { summaries in
            content(summaries)
        }
        .onAppear { index.sync(token: refreshToken) }
        .onChange(of: refreshToken) { _, token in index.sync(token: token) }
    }

    private func current(_ summaries: [CascadeSetSummary]) -> CascadeSetSummary? {
        if let selectedSet, let hit = summaries.first(where: { $0.id == selectedSet }) { return hit }
        return summaries.first { ($0.live ?? 0) > 0 } ?? summaries.first
    }

    @ViewBuilder
    private func content(_ summaries: [CascadeSetSummary]) -> some View {
        let infos = summaries.map(\.info)
        HStack(spacing: 0) {
            // 300 pt shows every set title in full; a narrow window gives the table the room.
            setList(summaries).frame(width: widthClass == .narrow ? 230 : (widthClass == .wide ? 300 : 270))
            Divider()
            if let set = current(summaries) {
                CascadeSetPane(summary: set, index: index, year: $year, filter: $tableFilter) { rows in
                    selected = rows.count == 1 ? Selection(set: set.id, seq: rows[0].id) : nil
                }
                .id(set.id)
                .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                    if let selected, let owner = infos.first(where: { $0.id == selected.set }) {
                        CascadeInspector(set: owner, seq: selected.seq, siblings: infos) { self.selected = nil }
                    }
                }
            }
        }
        .tracksWidthClass($widthClass)
        .onChange(of: deepLink?.nonce, initial: true) { _, _ in
            guard let link = deepLink, !link.payload.isEmpty else { return }
            let parts = link.payload.components(separatedBy: "\t")
            guard let target = summaries.first(where: { $0.id == parts[0] }) else { return }
            // Payload: "<set id>[\t<sequence number>[\t<filter text>]]".
            selectedSet = target.id
            tableFilter = parts.count > 2 ? parts[2] : ""
            if parts.count > 1, let seq = Int64(parts[1]) { selected = Selection(set: target.id, seq: seq) }
        }
    }

    private func setList(_ summaries: [CascadeSetSummary]) -> some View {
        let needle = listFilter.lowercased()
        let visible = summaries.filter { needle.isEmpty || $0.info.title.lowercased().contains(needle) || $0.info.stream.lowercased().contains(needle) }
        let active = current(summaries)?.id
        return VStack(spacing: 0) {
            FilterField("Filter sets", text: $listFilter)
            Divider()
            List(selection: Binding(get: { active }, set: { if let id = $0, id != active { selectedSet = id; selected = nil; year = nil; tableFilter = "" } })) {
                ForEach(CascadeGroup.allCases, id: \.self) { group in
                    let members = visible.filter { $0.info.group == group }
                    if !members.isEmpty {
                        Section(group.rawValue) {
                            ForEach(members) { s in
                                MasterRow(
                                    symbol: s.info.kind.symbol, title: s.info.title,
                                    count: s.live.map { $0 == 0 ? "empty" : Format.compact($0) } ?? "—",
                                    dimmed: (s.live ?? 0) == 0
                                )
                                .tag(s.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }
}

/// Header + table for one set.
private struct CascadeSetPane: View {
    let summary: CascadeSetSummary
    @ObservedObject var index: MailIndexMonitor
    @Binding var year: Int?
    @Binding var filter: String
    let onSelect: ([CascadeRow]) -> Void
    @StateObject private var scan = CascadeScanMonitor()

    private var info: CascadeSetInfo { summary.info }
    private var isMail: Bool { info.kind == .mail }
    private var indexed: Bool { isMail && index.status.isReady }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: info.kind.symbol, title: info.title, subtitle: info.explanation) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(summary.live.map { "\(Format.count($0)) live items" } ?? summary.availability.label).font(.callout.monospacedDigit())
                    Text("\(Format.bytes(info.bytes))" + ((summary.deleted ?? 0) > 0 ? " · \(Format.count(summary.deleted)) superseded" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if isMail { indexStrip }
            if case .inaccessible(let reason) = summary.availability {
                StatePlaceholder.inaccessible(reason)
            } else if summary.live == nil {
                StatePlaceholder.missing("This set uses a schema Dossier does not understand.")
            } else if summary.live == 0 {
                StatePlaceholder(title: "Empty Set", symbol: info.kind.symbol, message: "The set exists but holds no live items on this Mac.\n\(info.explanation)")
            } else {
                table
            }
            StoreFooter(info.url, note: info.stream + (info.source.map { " · " + $0 } ?? ""))
        }
        // The index (a decode of every mail entity) is built on request only: the Build
        // Index button, or the first filter typed into the mail set.
        .onAppear {
            guard isMail else { return }
            index.refresh()
            if MSDebug.autoStartJobs { index.start() }
        }
    }

    @ViewBuilder
    private var indexStrip: some View {
        Group {
            switch index.status.phase {
            case .building:
                JobProgress(
                    title: "Building date and sender index — showing most recently written first meanwhile",
                    detail: MSFormat.fraction(index.status.done, of: index.status.total), fraction: index.status.fraction, onCancel: { index.cancel() }
                )
            case .ready:
                HStack(spacing: 10) {
                    Label("Sorted by message date; the filter matches subject and sender instantly.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Year", selection: $year) {
                        Text("All Years").tag(Int?.none)
                        ForEach((index.insights?.years ?? []).reversed(), id: \.year) { item in
                            Text("\(String(item.year)) (\(Format.compact(item.count)))").tag(Int?.some(item.year))
                        }
                    }
                    .pickerStyle(.menu).controlSize(.small).fixedSize()
                }
            case .idle, .cancelled:
                HStack(spacing: 10) {
                    Label(
                        "Showing most recently written first. An index sorts by message date, adds years and makes the filter instant; building it decodes every entity once (a few seconds). Filtering builds it too.",
                        systemImage: "info.circle"
                    )
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Build Index") { index.start() }.controlSize(.small)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var columns: [PagedColumn<CascadeRow>] {
        let level = info.kind.sensitivity
        switch info.kind {
        case .mail:
            return [
                PagedColumn("Date", id: "date", width: 150, min: 130, sortable: indexed) { DossierDate.sortable($0.date) },
                PagedColumn("From", id: "from", width: 250, min: 120, sortable: false, sensitivity: level) { $0.subtitle },
                PagedColumn("Subject / File", id: "subject", width: 400, min: 160, sortable: false, sensitivity: level) { $0.title },
                PagedColumn("Kind", id: "kind", width: 110, sortable: false, secondary: true) { row in
                    var kind = row.type
                    if kind.hasSuffix("Entity") { kind.removeLast(6) }
                    if kind.hasPrefix("Mail"), kind.count > 4 { kind.removeFirst(4) }
                    return CascadeSetInfo.spaced(kind)
                },
                PagedColumn("Written to Set", id: "written", width: 150, sortable: false, secondary: true, hiddenByDefault: true) { DossierDate.sortable($0.written) },
                PagedColumn("Size", id: "size", width: 80, alignment: .trailing, sortable: false, secondary: true, hiddenByDefault: true) { Format.bytes($0.bytes) },
                PagedColumn("Message ID", id: "item", width: 90, sortable: false, monospaced: true, secondary: true, hiddenByDefault: true) { $0.itemID },
            ]
        case .mailBody, .attachmentText:
            return [
                PagedColumn("Text", id: "text", width: 620, min: 200, sortable: false, sensitivity: level) { $0.title },
                PagedColumn("Length", id: "size", width: 90, alignment: .trailing, sortable: false) { Format.count($0.bytes) },
                PagedColumn("Cached", id: "written", width: 150, sortable: false, secondary: true) { DossierDate.sortable($0.written) },
                PagedColumn("Item", id: "item", width: 120, sortable: false, monospaced: true, secondary: true, hiddenByDefault: true) { $0.itemID },
            ]
        default:
            return [
                PagedColumn(info.kind == .attachment ? "File" : "Title", id: "title", width: 300, min: 140, sortable: false, sensitivity: level) { $0.title },
                PagedColumn(info.kind == .attachment ? "Sender" : "Details", id: "details", width: 260, min: 100, sortable: false, sensitivity: level) { $0.subtitle },
                PagedColumn("Type", id: "type", width: 130, sortable: false, secondary: true) { row in
                    row.type.hasSuffix("Entity") && row.type.count > 6 ? CascadeSetInfo.spaced(String(row.type.dropLast(6))) : row.type
                },
                PagedColumn("Date", id: "date", width: 150, min: 140, sortable: false) { $0.date.map { DossierDate.sortable($0) } ?? "" },
                PagedColumn("Written to Set", id: "written", width: 150, sortable: false, secondary: true, hiddenByDefault: true) { DossierDate.sortable($0.written) },
                PagedColumn("Size", id: "size", width: 80, alignment: .trailing, sortable: false, secondary: true, hiddenByDefault: true) { Format.bytes($0.bytes) },
                PagedColumn("Item", id: "item", width: 160, sortable: false, monospaced: true, secondary: true, hiddenByDefault: true) { $0.itemID },
            ]
        }
    }

    private struct ReloadKey: Hashable {
        let set: String
        let indexed: Bool
        let year: Int?
    }

    private var table: some View {
        let info = self.info
        let live = summary.live
        let indexed = self.indexed
        let year = self.year
        let isMail = self.isMail
        let scan = self.scan
        return PagedTable(
            columns: columns,
            // Smaller pages while scanning text, so the first hits show before 200 are found.
            pageSize: info.kind.isPlainText ? 100 : 200,
            searchPrompt: info.kind.isPlainText ? "Search inside the text" : (info.kind == .mail ? "Filter by subject or sender" : "Filter"),
            reloadKey: ReloadKey(set: info.id, indexed: indexed, year: year),
            exportName: "cascade-" + info.kind.rawValue,
            emptyTitle: "No Matching Items",
            filter: $filter,
            fetch: { req in
                if indexed, let page = await MailIndex.shared.page(search: req.search, year: year, ascending: req.sort?.ascending ?? false, offset: req.offset, limit: req.limit) {
                    await scan.clear()
                    return try await CascadeStore.rows(info, seqs: page.seqs)
                }
                let cursor = req.offset == 0 ? nil : (req.cursor?.base as? Int64)
                let filtering = !req.search.trimmingCharacters(in: .whitespaces).isEmpty
                if isMail, filtering, !indexed {
                    // Scanning the GB-sized entity set for a filter costs more than building
                    // the index once, which then answers every further filter instantly.
                    if let seqs = try await Self.indexedMatches(req, year: year) {
                        return try await CascadeStore.rows(info, seqs: seqs)
                    }
                }
                guard filtering else {
                    await scan.clear()
                    return try await CascadeStore.page(info, before: cursor, limit: req.limit, search: "")
                }
                let run = await scan.begin(fresh: req.offset == 0)
                do {
                    let rows = try await CascadeStore.page(info, before: cursor, limit: req.limit, search: req.search) { examined in
                        Task { @MainActor in scan.advance(run, by: examined) }
                    }
                    await scan.end(run, exhausted: rows.count < req.limit)
                    return rows
                } catch {
                    await scan.end(run, exhausted: false)
                    throw error
                }
            },
            count: { req in
                if indexed, let page = await MailIndex.shared.page(search: req.search, year: year, ascending: false, offset: 0, limit: 0) { return page.total }
                return req.search.isEmpty ? live : nil
            },
            onSelect: onSelect
        ) {
            ScanProgressLabel(scan: scan, total: live ?? 0)
        }
    }

    /// Starts the mail index if it has never been built (or waits for a running build)
    /// and answers the request from it. Nil when the index is not available — the build
    /// was cancelled or failed — so the caller falls back to scanning the set.
    private static func indexedMatches(_ req: PageRequest, year: Int?) async throws -> [Int64]? {
        var phase = await MailIndex.shared.currentStatus().phase
        if phase == .idle {
            MailIndexMonitor.shared.start()
            phase = .building
        }
        while phase == .building {
            try await Task.sleep(nanoseconds: 150_000_000)
            phase = await MailIndex.shared.currentStatus().phase
        }
        guard phase == .ready else { return nil }
        return await MailIndex.shared.page(search: req.search, year: year, ascending: req.sort?.ascending ?? false, offset: req.offset, limit: req.limit)?.seqs
    }
}

/// Progress of a filter scan over a set, shown next to the filter field.
@MainActor
final class CascadeScanMonitor: ObservableObject {
    @Published private(set) var scanned = 0
    @Published private(set) var active = false
    @Published private(set) var exhausted = false
    private var run = 0

    /// Registers a page fetch; `fresh` (first page of a new filter) restarts the count.
    func begin(fresh: Bool) -> Int {
        if fresh { run += 1; scanned = 0; exhausted = false }
        active = true
        return run
    }

    /// Calls from a superseded scan (older `run`) are ignored.
    func advance(_ run: Int, by count: Int) {
        guard run == self.run else { return }
        scanned += count
    }

    func end(_ run: Int, exhausted: Bool) {
        guard run == self.run else { return }
        active = false
        if exhausted { self.exhausted = true }
    }

    func clear() {
        run += 1
        if scanned != 0 { scanned = 0 }
        if active { active = false }
        if exhausted { exhausted = false }
    }
}

private struct ScanProgressLabel: View {
    @ObservedObject var scan: CascadeScanMonitor
    let total: Int

    var body: some View {
        if scan.active || scan.scanned > 0 {
            let done = scan.exhausted ? max(total, scan.scanned) : min(scan.scanned, max(total, scan.scanned))
            HStack(spacing: 6) {
                if scan.active { ProgressView().controlSize(.small) }
                Text(text(done))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("A filter on this set reads and decompresses the items one batch at a time, newest first. Scroll to the end of the results to search further.")
        }
    }

    private func text(_ done: Int) -> String {
        if scan.active { return "Searching… \(MSFormat.fraction(done, of: max(total, done)))" }
        if scan.exhausted { return "Searched all \(Format.count(max(total, done))) items" }
        return "Searched the newest \(MSFormat.fraction(done, of: max(total, done)))"
    }
}

/// Inspector for one Cascade item.
struct CascadeInspector: View {
    let set: CascadeSetInfo
    let seq: Int64
    let siblings: [CascadeSetInfo]
    let onClose: () -> Void

    var body: some View {
        let set = self.set, seq = self.seq, siblings = self.siblings
        AsyncContent(reloadKey: "\(set.id)#\(seq)") {
            try await CascadeStore.detail(set, seq: seq, siblings: siblings)
        } content: { detail in
            page(detail)
        }
    }

    @ViewBuilder
    private func page(_ detail: CascadeDetail) -> some View {
        let level = set.kind.sensitivity
        InspectorPage(
            title: set.kind.isPlainText ? set.title : detail.row.title,
            subtitle: [detail.row.type, set.title].filter { !$0.isEmpty }.joined(separator: " · "),
            sensitivity: set.kind.isPlainText ? .low : level, onClose: onClose
        ) {
            if !detail.origin.isEmpty {
                InspectorGroupTitle(set.kind == .mailBody ? "Belongs to Message" : "Belongs to Attachment")
                KeyValueGrid(detail.origin)
            }
            let named = detail.attributes.filter { !$0.label.hasPrefix("Attribute ") }
            let unnamed = detail.attributes.filter { $0.label.hasPrefix("Attribute ") }
            if !named.isEmpty {
                KeyValueGrid(named)
            }
            if let text = detail.text {
                InspectorGroupTitle("Cached Text")
                RevealText(label: "Text", reloadKey: "\(set.id)#\(seq)") { text }
            }
            if set.kind == .mail, detail.row.type != "MailAttachmentEntity" {
                InspectorGroupTitle("Body Text")
                if let hash = detail.sourceHash, let bodySet = siblings.first(where: { $0.kind == .mailBody }) {
                    RevealText(label: "Body Text", reloadKey: "\(set.id)#\(seq)") {
                        try await CascadeStore.cachedText(in: bodySet, sourceHash: hash)
                    }
                } else {
                    Text("No body-text cache exists for this set.").font(.caption).foregroundStyle(.secondary)
                }
                if !detail.attachments.isEmpty {
                    InspectorGroupTitle("Attachments (\(detail.attachments.count))")
                    ForEach(detail.attachments) { attachment in
                        attachmentView(attachment)
                    }
                }
            }
            if set.kind == .attachment {
                InspectorGroupTitle("Extracted Text")
                if let hash = detail.sourceHash, let textSet = siblings.first(where: { $0.kind == .attachmentText }) {
                    RevealText(label: "Extracted Text", reloadKey: "\(set.id)#\(seq)") {
                        try await CascadeStore.cachedText(in: textSet, sourceHash: hash)
                    }
                }
            }
            if !detail.headers.isEmpty {
                InspectorDisclosure("Headers (\(detail.headers.count))") {
                    KeyValueGrid(detail.headers, valueLineLimit: 4)
                }
            }
            if !detail.custom.isEmpty {
                InspectorDisclosure("App Attributes (\(detail.custom.count))", expanded: set.kind != .mail) {
                    KeyValueGrid(detail.custom)
                }
            }
            if !unnamed.isEmpty {
                InspectorDisclosure("Unlabelled Attributes (\(unnamed.count))") {
                    KeyValueGrid(unnamed)
                }
            }
            InspectorDisclosure("Identifiers", expanded: true) {
                KeyValueGrid(detail.identifiers)
            }
            if !detail.nodes.isEmpty {
                InspectorDisclosure("Raw Record") {
                    DataTreeView(detail.nodes, sensitivity: level, expandedDepth: 1).frame(height: 320)
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentView(_ attachment: CascadeAttachmentRef) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip").foregroundStyle(.secondary)
                Text(attachment.name).font(.callout).lineLimit(2).sensitive(.sensitive)
                Spacer()
                Text(attachment.type).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let hash = attachment.sourceHash, let textSet = siblings.first(where: { $0.kind == .attachmentText }) {
                RevealText(label: "Extracted Text", reloadKey: "\(seq)#\(attachment.seq)") {
                    try await CascadeStore.cachedText(in: textSet, sourceHash: hash)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
