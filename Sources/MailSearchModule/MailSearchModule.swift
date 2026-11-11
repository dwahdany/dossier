import SwiftUI
import DossierCore

/// Mail & Search Index — the secondary copies and indexes the system keeps of your
/// content: Cascade entity sets (mail messages, plain-text bodies, attachment text,
/// reminders, contacts, …), the hybrid semantic index, Spotlight's knowledge graph and
/// document-processing bookkeeping, the harvesting / text-understanding streams and the
/// iCloud key-value cache.
///
/// Layout of the target:
///   Support.swift          paths, LZFSE, protobuf walker, small helpers
///   CascadeModel.swift     set classification, row / detail decoding
///   CascadeStore.swift     Set.db access (paged, linked lookups)
///   MailIndex.swift        background in-memory index over the mail entities
///   KuzuScanner.swift      mmap JSON scanner for the hybrid search (Kuzu) file
///   SpotlightStore.swift   document-processing stats, knowledge graph, loose files
///   HarvestStore.swift     ProactiveHarvesting / TextUnderstanding / Mail.Search streams
///   KVSStore.swift         iCloud key-value cache
///   *View.swift            one file per section
public final class MailSearchModule: DossierModule {
    public let id = "mailsearch"
    public let title = "Mail & Search Index"
    public let symbol = "envelope.open"
    public let group = SidebarGroup.people

    public init() {}

    public var sections: [ModuleSection] {
        [
            ModuleSection(id: "mailsearch.summary", title: "Summary", symbol: "square.stack.3d.up") { SummaryView() },
            ModuleSection(id: "mailsearch.cascade", title: "Cascade Entities", symbol: "tray.full") { CascadeView() },
            ModuleSection(id: "mailsearch.semantic", title: "Semantic Index", symbol: "circle.hexagongrid") { SemanticView() },
            ModuleSection(id: "mailsearch.spotlight", title: "Spotlight Knowledge", symbol: "sparkle.magnifyingglass") { SpotlightView() },
            ModuleSection(id: "mailsearch.harvest", title: "Harvesting Pipeline", symbol: "tray.and.arrow.down") { HarvestView() },
            ModuleSection(id: "mailsearch.kvs", title: "iCloud Key-Value Cache", symbol: "icloud") { KVSView() },
        ]
    }

    // MARK: Summary

    public func summary() async -> ModuleSummary {
        var stores: [StoreInfo] = []
        var facts: [Fact] = []

        // Cascade sets
        let root = MSPaths.cascadeRoot
        let rootAvailability = Paths.probe(root)
        let summaries = rootAvailability.isAvailable ? await CascadeLinks.shared.allSummaries() : []
        let totalLive = summaries.compactMap(\.live).reduce(0, +)
        let lastWrite = summaries.compactMap(\.lastWrite).max()
        let firstWrite = summaries.compactMap(\.lastWrite).min()
        stores.append(StoreInfo(
            name: "Cascade sets", path: root, sizeBytes: summaries.isEmpty ? nil : summaries.reduce(Int64(0)) { $0 + $1.info.bytes },
            rowCount: summaries.isEmpty ? nil : totalLive,
            timeRange: (firstWrite != nil && lastWrite != nil) ? firstWrite!...lastWrite! : nil,
            availability: rootAvailability, note: "\(summaries.count) sets"
        ))
        func set(_ kind: CascadeKind) -> CascadeSetSummary? { summaries.first { $0.info.kind == kind } }
        if let mail = set(.mail), let live = mail.live {
            stores.append(StoreInfo(name: "Mail message entities", path: mail.info.url, sizeBytes: mail.info.bytes, rowCount: live, note: "App.Intents.IndexedEntity"))
            facts.append(Fact("Mail messages and attachments mirrored as entities", Format.count(live), sensitivity: .personal, symbol: "envelope", sectionID: "mailsearch.cascade"))
        }
        if let body = set(.mailBody), let live = body.live {
            stores.append(StoreInfo(name: "Mail body text cache", path: body.info.url, sizeBytes: body.info.bytes, rowCount: live, note: "Cascade.CachedDocument"))
            facts.append(Fact("Plain-text mail bodies cached", "\(Format.count(live)) (\(Format.bytes(body.info.bytes)))", sensitivity: .personal, symbol: "text.alignleft", sectionID: "mailsearch.cascade"))
        }
        if let text = set(.attachmentText), let live = text.live, live > 0 {
            let all = set(.attachment)?.live
            facts.append(Fact("Mail attachments with extracted text", all.map { MSFormat.fraction(live, of: $0) } ?? Format.count(live), sensitivity: .personal, symbol: "paperclip", sectionID: "mailsearch.cascade"))
        }
        let others = summaries.filter { $0.info.group == .personal && ($0.live ?? 0) > 0 }.sorted { ($0.live ?? 0) > ($1.live ?? 0) }.prefix(4)
        if !others.isEmpty {
            facts.append(Fact("Also mirrored as entities", others.map { "\(Format.compact($0.live ?? 0)) \($0.info.title.lowercased())" }.joined(separator: ", "), sensitivity: .personal, symbol: "tray.full", sectionID: "mailsearch.cascade"))
        }

        // Hybrid search
        let quick = KuzuScanner.quickLook()
        if let file = quick.file {
            stores.append(StoreInfo(name: "Hybrid search index (Kuzu)", path: file, sizeBytes: quick.availability.isAvailable ? quick.bytes + quick.walBytes : nil, availability: quick.availability, note: "\(quick.collections.count) collections"))
        } else {
            stores.append(StoreInfo(name: "Hybrid search index (Kuzu)", path: Paths.daemonContainers, availability: .missing))
        }

        // Document processing
        let report = await SpotlightStore.documentProcessing(cascade: summaries)
        var state = StoreInfo.file("Document processing state", MSPaths.stateStore, note: "pipeline bookkeeping")
        if report.stateAvailability.isAvailable {
            state.rowCount = report.totalItems
            if let lo = report.sources.compactMap({ $0.range?.lowerBound }).min(), let hi = report.sources.compactMap({ $0.range?.upperBound }).max() { state.timeRange = lo...hi }
        }
        stores.append(state)
        stores.append(StoreInfo.file("Embedding result cache", MSPaths.cachedResultStore, rowCount: report.cacheAvailability.isAvailable ? report.pipelines.map(\.cached).reduce(0, +) : nil))
        if report.embeddings > 0 {
            let size = quick.availability.isAvailable ? " in a \(Format.bytes(quick.bytes)) semantic index" : ""
            facts.append(Fact("Documents turned into embedding vectors", Format.count(report.embeddings) + size, sensitivity: .low, symbol: "point.3.connected.trianglepath.dotted", sectionID: "mailsearch.semantic"))
        }
        if let first = report.years.first, let last = report.years.last, report.years.count > 1 {
            facts.append(Fact("Indexed mail spans", "\(first.year) – \(last.year)", sensitivity: .personal, symbol: "calendar", sectionID: "mailsearch.summary"))
        }

        // Spotlight knowledge graph
        var kg = StoreInfo.file("Spotlight knowledge graph", MSPaths.knowledgeGraph)
        if kg.availability.isAvailable, let db = await SQLiteDB.sharedIfAvailable(MSPaths.knowledgeGraph), await db.tableExists("Node") {
            let nodes = await db.rowCount(of: "Node") ?? 0
            let edges = await db.rowCount(of: "Edge") ?? 0
            kg.rowCount = nodes
            if nodes > 0 {
                facts.append(Fact("Spotlight identity graph", "\(Format.count(nodes)) nodes, \(Format.count(edges)) links", sensitivity: .personal, symbol: "sparkle.magnifyingglass", sectionID: "mailsearch.spotlight"))
            }
        }
        stores.append(kg)

        // Streams
        let streams = HarvestStore.streams()
        let liveRecords = streams.map(\.live).reduce(0, +)
        var streamRange: ClosedRange<Date>?
        for r in streams.compactMap(\.range) { streamRange = streamRange.map { min($0.lowerBound, r.lowerBound)...max($0.upperBound, r.upperBound) } ?? r }
        stores.append(StoreInfo(
            name: "Harvesting & text-understanding streams", path: Paths.biomeRestrictedStreams, sizeBytes: streams.map(\.bytes).reduce(0, +),
            rowCount: liveRecords, timeRange: streamRange, availability: Paths.probe(Paths.biomeRestrictedStreams), note: "\(streams.count) streams"
        ))
        if let deletions = streams.first(where: { $0.name == "TextUnderstanding.Deletions.Document" }), deletions.live > 0 {
            facts.append(Fact("Document deletions logged", Format.count(deletions.live), sensitivity: .low, symbol: "trash", sectionID: "mailsearch.harvest"))
        }

        // KVS
        if let dir = MSPaths.kvs {
            let kvsStores = await KVSStore.stores()
            let keys = kvsStores.map(\.keys).reduce(0, +)
            let availability = Paths.probe(dir)
            stores.append(StoreInfo(name: "iCloud key-value cache", path: dir, sizeBytes: availability.isAvailable ? KVSStore.databases().map(\.bytes).reduce(0, +) : nil, rowCount: availability.isAvailable ? keys : nil, availability: availability, note: "\(kvsStores.count) stores"))
            let recents = kvsStores.filter { $0.identifier == "com.apple.mail.recents" }.map(\.keys).reduce(0, +)
            if recents > 0 {
                facts.append(Fact("Recent mail recipients synced via iCloud", Format.count(recents), sensitivity: .personal, symbol: "icloud", sectionID: "mailsearch.kvs"))
            } else if keys > 0 {
                facts.append(Fact("iCloud key-value entries cached", "\(Format.count(keys)) in \(kvsStores.count) stores", sensitivity: .low, symbol: "icloud", sectionID: "mailsearch.kvs"))
            }
        } else {
            stores.append(StoreInfo(name: "iCloud key-value cache", path: Paths.daemonContainers, availability: .missing))
        }
        return ModuleSummary(stores: stores, facts: Array(facts.prefix(8)))
    }

    // MARK: Search

    public func search(_ query: String, limit: Int) async -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2, limit > 0 else { return [] }
        var hits: [SearchHit] = []
        let sets = await CascadeLinks.shared.allSets()

        // 1. Mail subjects / senders: the whole set when the in-memory index has been built,
        //    otherwise a bounded scan of the most recently written entities.
        if let mail = sets.first(where: { $0.kind == .mail }) {
            let wanted = max(3, limit / 2)
            var rows: [CascadeRow] = []
            if let page = await MailIndex.shared.page(search: needle, year: nil, ascending: false, offset: 0, limit: wanted) {
                rows = (try? await CascadeStore.rows(mail, seqs: page.seqs)) ?? []
            } else {
                rows = (try? await CascadeStore.page(mail, before: nil, limit: wanted, search: needle, maxScan: 3_000)) ?? []
            }
            for row in rows {
                hits.append(SearchHit(
                    id: "mailsearch.mail.\(row.id)", title: row.title,
                    subtitle: [row.subtitle, row.date.map { DossierDate.day($0) } ?? "", "Mail entity"].filter { !$0.isEmpty }.joined(separator: " · "),
                    moduleID: id, sectionID: "mailsearch.cascade", payload: "\(mail.id)\t\(row.id)", symbol: "envelope", sensitivity: .sensitive
                ))
            }
        }
        if Task.isCancelled { return Array(hits.prefix(limit)) }

        // 2. Small Cascade sets (reminders, contacts, bookmarks, devices, …): bounded scan.
        let summaries = await CascadeLinks.shared.allSummaries()
        for summary in summaries where hits.count < limit {
            if Task.isCancelled { break }
            let info = summary.info
            guard let live = summary.live, live > 0, live <= 30_000, !info.kind.isPlainText, info.kind != .mail, info.group != .apps else { continue }
            guard let rows = try? await CascadeStore.page(info, before: nil, limit: 3, search: needle) else { continue }
            for row in rows {
                hits.append(SearchHit(
                    id: "mailsearch.set.\(info.id).\(row.id)", title: row.title,
                    subtitle: [row.subtitle, info.title].filter { !$0.isEmpty }.joined(separator: " · "),
                    moduleID: id, sectionID: "mailsearch.cascade", payload: "\(info.id)\t\(row.id)", symbol: info.kind.symbol, sensitivity: info.kind.sensitivity
                ))
            }
        }
        if Task.isCancelled { return Array(hits.prefix(limit)) }

        // 3. iCloud key-value cache: key names and decoded values.
        if hits.count < limit {
            for (store, key, match) in await KVSStore.search(needle, limit: min(6, limit - hits.count)) {
                hits.append(SearchHit(
                    id: "mailsearch.kvs.\(store.id).\(key.id)", title: match,
                    subtitle: "\(store.highlight?.title ?? store.displayName) · iCloud key-value cache",
                    moduleID: id, sectionID: "mailsearch.kvs", payload: "\(store.database.url.lastPathComponent)\t\(store.identifier)\t\(key.id)",
                    symbol: store.highlight?.symbol ?? "icloud", sensitivity: store.highlight?.sensitivity ?? .personal
                ))
            }
        }
        return Array(hits.prefix(limit))
    }

    // MARK: Self-test

    public func selfTest() async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        func timed<T>(_ work: () async -> T) async -> (T, String) {
            let start = Date()
            let value = await work()
            return (value, String(format: "%.2f s", Date().timeIntervalSince(start)))
        }

        // Cascade
        let root = MSPaths.cascadeRoot
        let rootAvailability = Paths.probe(root)
        lines.append(rootAvailability.isAvailable ? .pass("Cascade sets readable", Format.tildePath(root)) : .warn("Cascade sets", "\(rootAvailability.label) — \(Format.tildePath(root))"))
        let (summaries, tSets) = await timed { rootAvailability.isAvailable ? await CascadeLinks.shared.allSummaries() : [] }
        let readable = summaries.filter { $0.live != nil }
        if rootAvailability.isAvailable {
            lines.append(.check("Cascade set schemas", readable.count == summaries.count && !summaries.isEmpty,
                                "\(readable.count)/\(summaries.count) sets, \(Format.count(readable.compactMap(\.live).reduce(0, +))) live items, \(Format.bytes(summaries.reduce(Int64(0)) { $0 + $1.info.bytes })) [\(tSets)]"))
        }
        for s in summaries where (s.live ?? 0) > 0 {
            lines.append(.info("  set \(s.info.title)", "live \(Format.count(s.live)) · contents \(Format.count(s.contents)) · deleted versions \(Format.count(s.deleted)) · \(Format.bytes(s.info.bytes)) · last write \(DossierDate.sortable(s.lastWrite))"))
        }
        let empty = summaries.filter { $0.live == 0 }
        if !empty.isEmpty { lines.append(.info("  empty sets", "\(empty.count): " + empty.map(\.info.stream).joined(separator: ", "))) }

        let sets = summaries.map(\.info)
        // Opt-in cross-check of the text search: DOSSIER_MAILSEARCH_VERIFY_SCAN=<needle>
        // scans the whole body-text set and prints the match count and timing.
        if let needle = ProcessInfo.processInfo.environment["DOSSIER_MAILSEARCH_VERIFY_SCAN"], !needle.isEmpty,
           let body = sets.first(where: { $0.kind == .mailBody }) {
            let examined = ScanCounter()
            let (rows, tScan) = await timed {
                (try? await CascadeStore.page(body, before: nil, limit: .max, search: needle) { n in examined.add(n) }) ?? []
            }
            lines.append(.info("Body-text search (verification)", "\(Format.count(rows.count)) matching items, \(Format.count(examined.value)) examined, first seq \(rows.first?.id ?? -1), last seq \(rows.last?.id ?? -1) [\(tScan)]"))
        }
        if let mail = sets.first(where: { $0.kind == .mail }) {
            let (page, tPage) = await timed { (try? await CascadeStore.page(mail, before: nil, limit: 200, search: "")) ?? [] }
            let titled = page.filter { $0.title != "Untitled" && !$0.title.isEmpty }.count
            let dated = page.filter { $0.date != nil }.count
            lines.append(.check("Mail entity decode (LZFSE + protobuf)", !page.isEmpty && titled * 10 >= page.count * 9,
                                "first page \(page.count) rows, \(titled) with subject, \(dated) with date, \(page.filter { !$0.subtitle.isEmpty }.count) with sender [\(tPage)]"))
            if let body = sets.first(where: { $0.kind == .mailBody }), let first = page.first,
               let detail = try? await CascadeStore.detail(mail, seq: first.id, siblings: sets) {
                var linked = 0, chars = 0, tried = 0
                let (_, tLink) = await timed {
                    for row in page.prefix(40) {
                        guard let d = try? await CascadeStore.detail(mail, seq: row.id, siblings: sets), let hash = d.sourceHash else { continue }
                        tried += 1
                        if let text = try? await CascadeStore.cachedText(in: body, sourceHash: hash) { linked += 1; chars += text.count }
                    }
                }
                lines.append(.check("Mail ↔ body-text link (source item hash)", linked > 0, "\(linked)/\(tried) newest messages have cached text, avg \(linked > 0 ? chars / linked : 0) chars; \(detail.headers.count) headers, \(detail.attributes.count) attributes in sample [\(tLink)]"))
            }
            if ProcessInfo.processInfo.environment["DOSSIER_MAILSEARCH_SKIP_INDEX"] == nil {
                await MailIndex.shared.start()
                var status = await MailIndex.shared.currentStatus()
                while status.phase == .building {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    status = await MailIndex.shared.currentStatus()
                }
                if let insights = await MailIndex.shared.insights() {
                    let live = summaries.first { $0.info.kind == .mail }?.live ?? -1
                    let mem = await MailIndex.shared.memoryBytes()
                    lines.append(.check("Mail index build", insights.entities == live,
                                        "\(Format.count(insights.entities)) entities = \(Format.count(insights.messages)) messages + \(Format.count(insights.attachments)) attachments (set live \(Format.count(live))), \(Format.count(insights.distinctSenders)) senders, \(insights.undated) undated, \(DossierDate.range(insights.range)), ~\(Format.bytes(mem)) in memory [\(String(format: "%.2f s", status.seconds))]"))
                    lines.append(.info("  mail by year", insights.years.map { "\($0.year): \($0.count)" }.joined(separator: ", ")))
                    let (found, tSearch) = await timed { await MailIndex.shared.page(search: "re:", year: nil, ascending: false, offset: 0, limit: 5) }
                    lines.append(.info("  index filter \"re:\"", "\(Format.count(found?.total ?? 0)) matches [\(tSearch)]"))
                } else {
                    lines.append(.warn("Mail index build", "\(status.phase)"))
                }
            }
        } else {
            lines.append(.warn("Mail entity set", "not present on this Mac"))
        }

        // Hybrid search
        let quick = KuzuScanner.quickLook()
        if let file = quick.file, quick.availability.isAvailable {
            lines.append(.check("Hybrid search index header", quick.header != nil,
                                "\(Format.bytes(quick.bytes)) + WAL \(Format.bytes(quick.walBytes)); storage version \(quick.header?.storageVersion ?? 0), \(Format.count(quick.header?.pageCount ?? 0)) pages, catalog @ page \(quick.header?.catalogPage ?? 0) (\(quick.header?.catalogPages ?? 0)); \(quick.collections.count) collections — \(Format.tildePath(file))"))
            await KuzuScanner.shared.start()
            var report = await KuzuScanner.shared.current()
            while report.phase == .scanning {
                try? await Task.sleep(nanoseconds: 100_000_000)
                report = await KuzuScanner.shared.current()
            }
            let counts = KuzuPayloadKind.allCases.map { "\($0.rawValue.lowercased()) \(report.kindCounts[$0] ?? 0)" }.joined(separator: ", ")
            lines.append(.check("Hybrid search JSON scan", report.phase == .finished,
                                "\(Format.count(report.candidates)) candidates → complete objects: \(counts); \(Format.count(report.payloadMarkers)) payload markers; WAL \(report.walPayloads); \(report.keyStats.count) distinct keys [\(String(format: "%.2f s", report.seconds))]"))
        } else {
            lines.append(.warn("Hybrid search index", quick.availability.label))
        }

        // Document processing
        let (report, tDoc) = await timed { await SpotlightStore.documentProcessing(cascade: summaries) }
        if report.stateAvailability.isAvailable {
            lines.append(.check("Document processing state", !report.pipelines.isEmpty,
                                "\(report.pipelines.count) pipelines (\(report.pipelines.filter(\.isActive).count) with items), \(Format.count(report.totalItems)) items in \(report.sources.count) sources, \(Format.count(report.embeddings)) embedded, \(report.errors.map(\.count).reduce(0, +)) errors [\(tDoc)]"))
            for p in report.pipelines where p.isActive {
                lines.append(.info("  pipeline \(p.name)", "items \(Format.count(p.items)) · processed \(Format.count(p.processed)) · results \(Format.count(p.withResult)) · errors \(p.errors) · cached \(Format.count(p.cached))/\(Format.count(p.cachedWithResult))"))
            }
            for s in report.sources {
                lines.append(.info("  source \(s.label)", "\(Format.count(s.items)) items, \(DossierDate.range(s.range))"))
            }
            lines.append(.info("  items by year", report.years.map { "\($0.year): \($0.count)" }.joined(separator: ", ")))
            lines.append(.info("  embedding cache sample", "\(report.embeddingVectorsPerItem ?? 0) vectors/item × \(report.embeddingDimensions ?? 0) dims, entity \(report.embeddingEntityType ?? "?"); completeness for \(report.completeness.count) apps"))
        } else {
            lines.append(.warn("Document processing state", report.stateAvailability.label))
        }

        // Knowledge graph
        do {
            let start = Date()
            let overview = try await KnowledgeGraphStore.overview()
            let userEdges = overview.user != nil ? (try? await KnowledgeGraphStore.edges(of: overview.user!.id).count) ?? 0 : 0
            lines.append(.check("Spotlight knowledge graph", overview.nodeCount > 0,
                                "\(Format.count(overview.nodeCount)) nodes, \(Format.count(overview.edgeCount)) edges, \(overview.labelCounts.count) labels, user node \(overview.user != nil ? "found with \(userEdges) links" : "not found") [\(String(format: "%.2f s", Date().timeIntervalSince(start)))]"))
            lines.append(.info("  node labels", overview.labelCounts.map { "\($0.label) \($0.count)" }.joined(separator: ", ")))
            lines.append(.info("  relationships", overview.relationshipCounts.prefix(12).map { "\($0.relationship) \($0.count)" }.joined(separator: ", ")))
        } catch {
            lines.append(.warn("Spotlight knowledge graph", error.localizedDescription))
        }
        let files = SpotlightFiles.list()
        lines.append(.info("Spotlight loose files", "\(files.count) previewable files, " + SpotlightFiles.indexDirectories().map { "\($0.name) \(Format.bytes($0.bytes))" }.joined(separator: ", ")))

        // Streams
        let (streams, tStreams) = await timed { HarvestStore.streams() }
        let streamDetail = "\(streams.count) streams, \(streams.filter { $0.live > 0 }.count) with live records [\(tStreams)]"
        lines.append(streams.isEmpty ? .warn("Harvesting / text-understanding streams", "none found — \(Paths.probe(Paths.biomeRestrictedStreams).label)") : .pass("Harvesting / text-understanding streams", streamDetail))
        for s in streams where s.live > 0 || s.deleted > 0 {
            let rows = HarvestStore.rows(s)
            let decoded = rows.filter { $0.title != "Undecoded record" && $0.title != "Record" }.count
            lines.append(.info("  stream \(s.name)", "live \(s.live) · deleted \(s.deleted) · decoded titles \(decoded)/\(rows.count) · \(DossierDate.range(s.range))"))
        }

        // KVS
        if let dir = MSPaths.kvs {
            let (kvs, tKVS) = await timed { await KVSStore.stores() }
            lines.append(.init(Paths.probe(dir).isAvailable && !kvs.isEmpty ? .pass : .warn, "iCloud key-value cache",
                                "\(KVSStore.databases().count) databases, \(kvs.count) non-empty stores, \(Format.count(kvs.map(\.keys).reduce(0, +))) keys, \(kvs.filter { $0.highlight != nil }.count) highlighted [\(tKVS)]"))
            for database in KVSStore.databases() {
                let mine = kvs.filter { $0.database == database }
                lines.append(.info("  \(database.title)", "\(mine.count) stores, \(Format.count(mine.map(\.keys).reduce(0, +))) keys, \(Format.bytes(database.bytes))"))
            }
            if let first = kvs.first, let keys = try? await KVSStore.keys(first, offset: 0, limit: 50, sort: nil, search: "") {
                lines.append(.check("Key-value plist decode", keys.contains { !$0.preview.isEmpty }, "\(keys.filter { !$0.preview.isEmpty }.count)/\(keys.count) values previewed in \(first.highlight?.title ?? first.displayName)"))
            }
        } else {
            lines.append(.warn("iCloud key-value cache", "com.apple.kvs daemon container not found"))
        }

        // Timings of the entry points
        let (sum, tSummary) = await timed { await self.summary() }
        lines.append(.info("summary()", "\(sum.stores.count) stores, \(sum.facts.count) facts [\(tSummary)]"))
        let (hits, tSearch) = await timed { await self.search("apple", limit: 20) }
        lines.append(.info("search(\"apple\")", "\(hits.count) hits [\(tSearch)]"))
        return lines
    }
}

/// Thread-safe counter for the scan-progress callback in the self-test.
private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ n: Int) { lock.lock(); total += n; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return total }
}
