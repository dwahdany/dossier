import Foundation
import DossierCore

/// Read access to the Cascade sets under `~/Library/Biome/sets`.
///
/// On-disk format (established empirically): every set — optionally per donating source
/// (`sourceIdentifier=<bundle>`) or per associated set (`associatedSet=<name>`) — is a
/// directory `…/Database/Set.db`, a SQLite database with
///   * `content(content_hash, content)` — the item payloads (protobuf or plain text,
///     optionally LZFSE-compressed, see ``CascadeBlob``), de-duplicated by hash;
///   * `metacontent(instance_hash, metacontent)` — a small protobuf with the item's
///     identifiers;
///   * `metacontent_provenance` — the append-only log tying both together per device:
///     `source_item_id_hash`, `instance_hash`, `content_hash`, `sequence_number`,
///     `deleted_run_length` (0 = live), `written_date` / `deleted_date` (µs since 1970);
///   * `metacontent_field` — a few indexed fields with hashed column names.
/// `source_item_id_hash` is identical for the same item across sibling sets, which is how
/// a mail message is linked to its cached body text.
enum CascadeStore {
    static let liveFilter = "(p.deleted_run_length != 0) = 0"

    // MARK: Discovery

    /// Walks the sets root for `Database/Set.db` files. File-system only, no queries.
    static func discover() -> [CascadeSetInfo] {
        let root = MSPaths.cascadeRoot
        let fm = FileManager.default
        var out: [CascadeSetInfo] = []
        func walk(_ dir: URL, _ components: [String], _ depth: Int) {
            let db = dir.appendingPathComponent("Database/Set.db")
            if fm.fileExists(atPath: db.path) {
                // components[0] is the namespace ("Default"), [1] the set name.
                guard components.count >= 2 else { return }
                let stream = components[1]
                var source: String?, associated: String?
                for c in components.dropFirst(2) {
                    if c.hasPrefix("sourceIdentifier=") { source = String(c.dropFirst("sourceIdentifier=".count)) }
                    if c.hasPrefix("associatedSet=") { associated = String(c.dropFirst("associatedSet=".count)) }
                }
                let (kind, title, group, explanation) = CascadeSetInfo.classify(stream: stream, source: source, associated: associated)
                out.append(CascadeSetInfo(
                    id: components.joined(separator: "/"), stream: stream, source: source, associated: associated,
                    url: db, bytes: FileProbe.databaseSize(db), kind: kind, title: title, group: group, explanation: explanation
                ))
                return
            }
            guard depth < 5, let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walk(child, components + [child.lastPathComponent], depth + 1)
            }
        }
        walk(root, [], 0)
        let order: [CascadeKind] = [.mail, .mailBody, .attachment, .attachmentText]
        return out.sorted { a, b in
            let ia = order.firstIndex(of: a.kind) ?? order.count, ib = order.firstIndex(of: b.kind) ?? order.count
            if ia != ib { return ia < ib }
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            return a.title < b.title
        }
    }

    // MARK: Schema

    struct Schema: Sendable {
        let hasWritten: Bool
        let hasSourceHash: Bool
    }

    static func open(_ set: CascadeSetInfo) async throws -> (SQLiteDB, Schema) {
        switch Paths.probe(set.url) {
        case .missing: throw DossierError.missing("This Cascade set no longer exists.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        default: break
        }
        let db: SQLiteDB
        do { db = try await SQLiteDB.shared(set.url) } catch let error as SQLiteError {
            if error.isAccessProblem { throw DossierError.inaccessible(error.localizedDescription) }
            throw DossierError.message(error.localizedDescription)
        }
        let columns = await db.columnNames(of: "metacontent_provenance")
        let required: Set<String> = ["instance_hash", "content_hash", "sequence_number", "deleted_run_length"]
        guard required.isSubset(of: columns), await db.hasColumns("content", ["content_hash", "content"]),
              await db.hasColumns("metacontent", ["instance_hash", "metacontent"]) else {
            throw DossierError.missing("This set uses a schema Dossier does not understand (metacontent_provenance / content / metacontent changed).")
        }
        return (db, Schema(hasWritten: columns.contains("written_date"), hasSourceHash: columns.contains("source_item_id_hash")))
    }

    static func summary(_ set: CascadeSetInfo) async -> CascadeSetSummary {
        do {
            let (db, schema) = try await open(set)
            let live = await db.count("SELECT count(*) FROM metacontent_provenance p WHERE \(liveFilter)")
            let deleted = await db.count("SELECT count(*) FROM metacontent_provenance p WHERE (p.deleted_run_length != 0) = 1")
            // Distinct payloads of live items, from the covering provenance index (counting the
            // `content` table itself would read every blob page of a GB-sized set).
            let contents = await db.count("SELECT count(DISTINCT content_hash) FROM metacontent_provenance WHERE deleted_run_length = 0")
            var last: Date?
            if schema.hasWritten, let v = try? await db.scalar("SELECT max(written_date) FROM metacontent_provenance"), let micros = v.int, micros > 0 {
                last = DossierDate.unixMicros(micros)
            }
            return CascadeSetSummary(info: set, live: live, contents: contents, deleted: deleted, lastWrite: last, availability: .available)
        } catch {
            let availability: Availability
            if case DossierError.inaccessible(let reason) = error { availability = .inaccessible(reason) } else { availability = Paths.probe(set.url) }
            return CascadeSetSummary(info: set, live: nil, contents: nil, deleted: nil, lastWrite: nil, availability: availability)
        }
    }

    // MARK: Rows

    private static func select(_ schema: Schema) -> String {
        """
        SELECT p.sequence_number, \(schema.hasWritten ? "p.written_date" : "NULL"), \(schema.hasSourceHash ? "p.source_item_id_hash" : "NULL"), m.metacontent, c.content
        FROM metacontent_provenance p
        LEFT JOIN metacontent m ON m.instance_hash = p.instance_hash
        LEFT JOIN content c ON c.content_hash = p.content_hash
        """
    }

    private struct RawRow: Sendable {
        let seq: Int64
        let written: Int64?
        let sourceHash: Int64?
        let meta: Data?
        let content: Data?
    }

    private static func raw(_ row: SQLRow) -> RawRow {
        RawRow(seq: row[0].int ?? 0, written: row[1].int, sourceHash: row[2].int, meta: row[3].data, content: row[4].data)
    }

    private static func decode(_ set: CascadeSetInfo, _ rows: [RawRow]) -> [(row: CascadeRow, haystack: String)] {
        if rows.count < 16 {
            return rows.map { CascadeDecoder.row(set: set, seq: $0.seq, meta: $0.meta, raw: $0.content, written: $0.written) }
        }
        return msConcurrentMap(rows.count) { index in
            let r = rows[index]
            return CascadeDecoder.row(set: set, seq: r.seq, meta: r.meta, raw: r.content, written: r.written)
        }
    }

    /// Newest-written-first keyset page.
    ///
    /// With a search term the set is scanned in keyset batches until `limit` matches are
    /// found or `maxScan` items have been looked at; cancellable between batches (and
    /// inside a batch through the interrupted statement). `progress` is called after
    /// every batch with the number of items examined since the previous call.
    ///
    /// * Plain-text sets (mail bodies, attachment text): only `sequence_number` and
    ///   `content` are read, the needle is matched on the decompressed bytes, and rows
    ///   (with their metacontent) are built for the hits alone.
    /// * Entity sets: the filter means "title, details, type or item id contains", so
    ///   every item is decoded into its display row and that text is compared.
    static func page(
        _ set: CascadeSetInfo, before cursor: Int64?, limit: Int, search: String, maxScan: Int = .max,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [CascadeRow] {
        let (db, schema) = try await open(set)
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        var position = cursor ?? Int64.max
        var out: [CascadeRow] = []
        if !needle.isEmpty, set.kind.isPlainText {
            return try await textScan(set, db: db, needle: needle, before: position, limit: limit, maxScan: maxScan, progress: progress)
        }
        let batchSize = needle.isEmpty ? limit : 600
        var scanned = 0
        while out.count < limit, scanned < maxScan {
            try Task.checkCancellation()
            let rows = try await db.rows(
                select(schema) + " WHERE \(liveFilter) AND p.sequence_number < ? ORDER BY p.sequence_number DESC LIMIT ?",
                [.integer(position), .integer(Int64(batchSize))]
            ).map(raw)
            guard let last = rows.last else { break }
            position = last.seq
            scanned += rows.count
            let decoded = decode(set, rows)
            if needle.isEmpty {
                out.append(contentsOf: decoded.map(\.row))
            } else {
                var examined = rows.count
                for (index, item) in decoded.enumerated() where item.haystack.lowercased().contains(needle) {
                    out.append(item.row)
                    if out.count >= limit { examined = index + 1; break }
                }
                progress?(examined)
            }
            if rows.count < batchSize { break }
        }
        return out
    }

    /// Items examined per batch of a text search (≈ 3 MB of compressed text).
    private static let textScanBatch = 2_000

    private static func textScan(
        _ set: CascadeSetInfo, db: SQLiteDB, needle: String, before cursor: Int64, limit: Int, maxScan: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> [CascadeRow] {
        let matcher = TextNeedle(needle)
        var position = cursor
        var out: [CascadeRow] = []
        var scanned = 0
        while out.count < limit, scanned < maxScan {
            try Task.checkCancellation()
            let batch = min(textScanBatch, maxScan - scanned)
            let rows = try await db.rows(
                """
                SELECT p.sequence_number, c.content FROM metacontent_provenance p
                LEFT JOIN content c ON c.content_hash = p.content_hash
                WHERE \(liveFilter) AND p.sequence_number < ? ORDER BY p.sequence_number DESC LIMIT ?
                """, [.integer(position), .integer(Int64(batch))], maxRows: batch
            )
            guard let last = rows.last else { break }
            position = last[0].int ?? Int64.min
            scanned += rows.count
            let matched: [Bool] = msConcurrentMap(rows.count) { index in
                guard let raw = rows[index][1].data else { return false }
                return matcher.matches(CascadeBlob.decode(raw))
            }
            var hits: [Int64] = []
            var examined = rows.count
            for (index, isHit) in matched.enumerated() where isHit {
                hits.append(rows[index][0].int ?? 0)
                if out.count + hits.count >= limit { examined = index + 1; break }
            }
            if !hits.isEmpty {
                try Task.checkCancellation()
                out.append(contentsOf: try await self.rows(set, seqs: hits))
            }
            progress?(examined)
            if rows.count < batch { break }
        }
        return out
    }

    /// Specific items by sequence number, returned in the order given.
    static func rows(_ set: CascadeSetInfo, seqs: [Int64]) async throws -> [CascadeRow] {
        guard !seqs.isEmpty else { return [] }
        let (db, schema) = try await open(set)
        var found: [Int64: CascadeRow] = [:]
        for chunk in stride(from: 0, to: seqs.count, by: 400).map({ Array(seqs[$0..<min($0 + 400, seqs.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try await db.rows(
                select(schema) + " WHERE \(liveFilter) AND p.sequence_number IN (\(marks))", chunk.map { SQLValue.integer($0) }
            ).map(raw)
            for item in decode(set, rows) { found[item.row.id] = item.row }
        }
        return seqs.compactMap { found[$0] }
    }

    // MARK: Detail

    static func detail(_ set: CascadeSetInfo, seq: Int64, siblings: [CascadeSetInfo]) async throws -> CascadeDetail {
        let (db, schema) = try await open(set)
        guard let sql = try await db.first(select(schema) + " WHERE p.sequence_number = ? LIMIT 1", [.integer(seq)]) else {
            throw DossierError.message("This item is no longer in the set.")
        }
        let r = raw(sql)
        let row = CascadeDecoder.row(set: set, seq: r.seq, meta: r.meta, raw: r.content, written: r.written).row
        var attachments: [CascadeAttachmentRef] = []
        var origin: [KeyValueItem] = []
        if set.kind == .mail, !row.itemID.isEmpty, let attachmentSet = siblings.first(where: { $0.kind == .attachment }) {
            attachments = await CascadeLinks.shared.attachments(forMessage: row.itemID, in: attachmentSet)
        }
        if set.kind.isPlainText, let hash = r.sourceHash {
            let parentKind: CascadeKind = set.kind == .mailBody ? .mail : .attachment
            if let parent = siblings.first(where: { $0.kind == parentKind }), let item = try? await item(in: parent, sourceHash: hash) {
                origin = [
                    KeyValueItem(parentKind == .mail ? "Subject" : "File", item.title, sensitivity: .sensitive, id: "o:title"),
                    KeyValueItem(parentKind == .mail ? "From" : "Sender", item.subtitle, sensitivity: .sensitive, id: "o:sub"),
                    KeyValueItem("Date", item.date.map { DossierDate.medium($0) }, id: "o:date"),
                ]
            }
        }
        return CascadeDecoder.detail(set: set, row: row, meta: r.meta, raw: r.content, sourceHash: r.sourceHash, attachments: attachments, origin: origin)
    }

    /// The live item with a given `source_item_id_hash` (index-backed lookup).
    static func item(in set: CascadeSetInfo, sourceHash: Int64) async throws -> CascadeRow? {
        let (db, schema) = try await open(set)
        guard schema.hasSourceHash else { return nil }
        guard let sql = try await db.first(
            select(schema) + " WHERE p.source_item_id_hash = ? AND p.deleted_run_length = 0 LIMIT 1", [.integer(sourceHash)]
        ) else { return nil }
        let r = raw(sql)
        return CascadeDecoder.row(set: set, seq: r.seq, meta: r.meta, raw: r.content, written: r.written).row
    }

    /// Plain text cached for an item (mail body or attachment text), looked up in the
    /// sibling `Cascade.CachedDocument` set through the shared source-item hash.
    static func cachedText(in set: CascadeSetInfo, sourceHash: Int64) async throws -> String? {
        let (db, schema) = try await open(set)
        guard schema.hasSourceHash else { return nil }
        let value = try await db.scalar(
            "SELECT c.content FROM metacontent_provenance p JOIN content c ON c.content_hash = p.content_hash WHERE p.source_item_id_hash = ? AND p.deleted_run_length = 0 LIMIT 1",
            [.integer(sourceHash)]
        )
        guard let data = value.data else { return nil }
        return CascadeBlob.decode(data).lossyUTF8
    }
}

/// Caches derived from the sets (in memory only; reset on Refresh).
actor CascadeLinks {
    static let shared = CascadeLinks()

    private var token = -1
    private var sets: [CascadeSetInfo]?
    private var summaries: [CascadeSetSummary]?
    private var attachmentMap: [String: [CascadeAttachmentRef]]?

    func sync(token: Int) {
        if token != self.token {
            self.token = token
            sets = nil; summaries = nil; attachmentMap = nil
        }
    }

    func allSets() -> [CascadeSetInfo] {
        if let sets { return sets }
        let found = CascadeStore.discover()
        sets = found
        return found
    }

    func allSummaries() async -> [CascadeSetSummary] {
        if let summaries { return summaries }
        let infos = allSets()
        var out: [CascadeSetSummary] = []
        for info in infos {
            if Task.isCancelled { break }
            out.append(await CascadeStore.summary(info))
        }
        if !Task.isCancelled { summaries = out }
        return out
    }

    func set(kind: CascadeKind) -> CascadeSetInfo? { allSets().first { $0.kind == kind } }

    /// Attachments of a mail message. `Mail.ImportedAttachment` metacontent carries the
    /// message's item identifier in field 7; there is no index on it, so the (small,
    /// uncompressed) metacontent of the whole set is read once and kept.
    func attachments(forMessage itemID: String, in set: CascadeSetInfo) async -> [CascadeAttachmentRef] {
        if attachmentMap == nil {
            var map: [String: [CascadeAttachmentRef]] = [:]
            if let (db, schema) = try? await CascadeStore.open(set) {
                let sql = """
                SELECT p.sequence_number, \(schema.hasSourceHash ? "p.source_item_id_hash" : "NULL"), m.metacontent, c.content
                FROM metacontent_provenance p LEFT JOIN metacontent m ON m.instance_hash = p.instance_hash
                LEFT JOIN content c ON c.content_hash = p.content_hash
                WHERE \(CascadeStore.liveFilter) LIMIT 200000
                """
                let rows = (try? await db.rows(sql, maxRows: 200_000)) ?? []
                for row in rows {
                    guard let meta = row[2].data.flatMap({ ProtoMessage($0) }), let message = meta[7]?.string else { continue }
                    let content = row[3].data.flatMap { ProtoMessage(CascadeBlob.decode($0)) }
                    map[message, default: []].append(CascadeAttachmentRef(
                        seq: row[0].int ?? 0, name: content?[2]?.string ?? "Attachment", type: content?[1]?.string ?? "", sourceHash: row[1].int
                    ))
                }
            }
            attachmentMap = map
        }
        return attachmentMap?[itemID] ?? []
    }
}
