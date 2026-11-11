import Foundation
import DossierCore

// The Photos search index. Two generations are supported:
//
// "Leo" (current): a lexicon of terms plus, per indexed item, a packed list of lexeme ids.
//    Photos.sqlite:  ZLEOLEXEME(ZLEXEMEID, ZLEXEMETYPE 1 = term / 2 = synonym, ZCATEGORY, ZCONTENT, ZIDENTIFIER)
//                    ZLEOITEM(ZITEMTYPE 1 = asset, ZIDENTIFIER = asset UUID, ZDATECREATED, ZLEXEMEIDSDATA)
//    search/leo.sqlite mirrors it as lexicon(lexeme_id, type, category, content, identifier) / items(...).
//    ZLEXEMEIDSDATA is an ascending array of little-endian UInt32 lexeme ids. Asset counts per term
//    are therefore not stored anywhere: we count them in one streaming pass over the item blobs.
//
// "PSI" (legacy psi.sqlite): groups(category, content_string, lookup_identifier, owning_groupid)
//    and ga(groupid, assetid) link rows; counts come straight from SQL.

struct SearchCategoryRow: Sendable, Identifiable, Hashable {
    var id: Int { code }
    let code: Int
    let name: String
    let group: String
    let terms: Int
    let synonyms: Int
    let assetLinks: Int
    let reveal: Bool
    let sensitivity: Sensitivity
}

struct SearchTermRow: Sendable, Identifiable, Hashable {
    let id: Int64
    let content: String
    let identifier: String
    let assets: Int
    let isSynonym: Bool
    let lexeme: Int64
}

struct OCRAssetRow: Sendable, Identifiable, Hashable {
    let id: Int64
    let asset: String
    let date: Date?
    let tokens: Int
    let text: String
}

struct SearchIndexStats: Sendable {
    let backend: SearchBackend
    let source: URL
    var categories: [SearchCategoryRow] = []
    var items = 0
    var terms = 0
    var links = 0
    var range: ClosedRange<Date>?
    var ocrAssets = 0
    var ocrTokens = 0
    /// Leo only: lexeme id → number of asset items carrying it.
    var lexemeAssets: [Int64: Int32] = [:]
    /// Leo only: (item pk, OCR token count) for every asset with recognised text, most text first.
    var ocrItems: [(pk: Int64, tokens: Int32)] = []
}

/// Table and column names of the Leo lexicon in its two homes.
private struct LeoSchema: Sendable {
    let db: SQLiteDB
    let url: URL
    let lexicon: String, lexemeID: String, type: String, category: String, content: String, identifier: String, lexPK: String
    let items: String, itemPK: String, itemType: String, itemIdentifier: String, itemDate: String, itemLexemes: String
}

enum SearchIndexStore {
    static func availableBackends(_ lib: PhotosLibrary) async -> [SearchBackend] {
        var out: [SearchBackend] = []
        if (try? await leoSchema(lib)) != nil { out.append(.leo) }
        if Paths.probe(lib.psiDB).isAvailable, let db = await SQLiteDB.sharedIfAvailable(lib.psiDB), await db.hasColumns("groups", ["category", "content_string"]) { out.append(.psi) }
        return out
    }

    private static func leoSchema(_ lib: PhotosLibrary) async throws -> LeoSchema {
        if let db = await SQLiteDB.sharedIfAvailable(lib.photosDB),
           await db.hasColumns("ZLEOLEXEME", ["ZLEXEMEID", "ZLEXEMETYPE", "ZCATEGORY", "ZCONTENT"]),
           await db.hasColumns("ZLEOITEM", ["ZITEMTYPE", "ZIDENTIFIER", "ZLEXEMEIDSDATA"]) {
            return LeoSchema(db: db, url: lib.photosDB, lexicon: "ZLEOLEXEME", lexemeID: "ZLEXEMEID", type: "ZLEXEMETYPE", category: "ZCATEGORY", content: "ZCONTENT", identifier: "ZIDENTIFIER", lexPK: "Z_PK",
                             items: "ZLEOITEM", itemPK: "Z_PK", itemType: "ZITEMTYPE", itemIdentifier: "ZIDENTIFIER", itemDate: "ZDATECREATED", itemLexemes: "ZLEXEMEIDSDATA")
        }
        let leoURL = lib.databaseDirectory.appendingPathComponent("search/leo.sqlite")
        if let db = await SQLiteDB.sharedIfAvailable(leoURL),
           await db.hasColumns("lexicon", ["lexeme_id", "type", "category", "content"]),
           await db.hasColumns("items", ["type", "identifier", "lexeme_ids"]) {
            return LeoSchema(db: db, url: leoURL, lexicon: "lexicon", lexemeID: "lexeme_id", type: "type", category: "category", content: "content", identifier: "identifier", lexPK: "pk",
                             items: "items", itemPK: "pk", itemType: "type", itemIdentifier: "identifier", itemDate: "date_created", itemLexemes: "lexeme_ids")
        }
        throw DossierError.missing("This library has no Leo search lexicon (ZLEOLEXEME / leo.sqlite).")
    }

    private static func psi(_ lib: PhotosLibrary) async throws -> SQLiteDB {
        let db = try await lib.open(lib.psiDB, "psi.sqlite")
        guard await db.hasColumns("groups", ["category", "content_string"]), await db.hasColumns("ga", ["groupid", "assetid"]) else {
            throw DossierError.missing("psi.sqlite does not have the groups / ga layout this viewer understands.")
        }
        return db
    }

    static func preferredBackend(_ lib: PhotosLibrary) async -> SearchBackend? {
        await availableBackends(lib).first
    }

    /// Ascending UInt32 lexeme ids packed in a blob.
    @inline(__always)
    private static func forEachLexeme(_ data: Data, _ body: (Int64) -> Void) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset + 4 <= raw.count {
                body(Int64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))))
                offset += 4
            }
        }
    }

    static func stats(_ lib: PhotosLibrary, backend: SearchBackend) async throws -> SearchIndexStats {
        let key = lib.id + "|" + backend.rawValue
        if let cached = await PhotosCaches.shared.cachedSearchStats(key) { return cached }
        let stats: SearchIndexStats
        switch backend {
        case .leo: stats = try await leoStats(lib)
        case .psi: stats = try await psiStats(lib)
        }
        await PhotosCaches.shared.setSearchStats(stats, key: key)
        return stats
    }

    private static func leoStats(_ lib: PhotosLibrary) async throws -> SearchIndexStats {
        let s = try await leoSchema(lib)
        var stats = SearchIndexStats(backend: .leo, source: s.url)

        // Lexicon: id → category, plus term / synonym counts per category.
        struct LexAcc: Sendable {
            var category: [Int64: Int32] = [:]
            var terms: [Int32: Int] = [:]
            var synonyms: [Int32: Int] = [:]
        }
        let lex = try await s.db.reduce("SELECT \(s.lexemeID), \(s.category), \(s.type) FROM \(s.lexicon)", into: LexAcc()) { acc, row in
            guard let id = row[0].int, let c = row[1].int else { return }
            let cat = Int32(truncatingIfNeeded: c)
            acc.category[id] = cat
            if (row[2].int ?? 1) == 2 { acc.synonyms[cat, default: 0] += 1 } else { acc.terms[cat, default: 0] += 1 }
        }

        // Items: one streaming pass over the packed lexeme lists.
        struct ItemAcc: Sendable {
            var counts: [Int64: Int32] = [:]
            var items = 0
            var links = 0
            var lo: Double?
            var hi: Double?
            var ocr: [(pk: Int64, tokens: Int32)] = []
            var ocrTokens = 0
        }
        let ocrCategory = Int32(SearchBackend.leo.ocrCode)
        let categoryOf = lex.category
        let hasDate = await s.db.hasColumns(s.items, [s.itemDate])
        let items = try await s.db.reduce("SELECT \(s.itemPK), \(hasDate ? s.itemDate : "NULL"), \(s.itemLexemes) FROM \(s.items) WHERE \(s.itemType) = 1", into: ItemAcc()) { acc, row in
            acc.items += 1
            if let d = row[1].double, d != 0 {
                acc.lo = acc.lo.map { min($0, d) } ?? d
                acc.hi = acc.hi.map { max($0, d) } ?? d
            }
            guard let blob = row[2].data else { return }
            var ocr: Int32 = 0
            forEachLexeme(blob) { id in
                acc.counts[id, default: 0] += 1
                acc.links += 1
                if categoryOf[id] == ocrCategory { ocr += 1 }
            }
            if ocr > 0, let pk = row[0].int { acc.ocr.append((pk, ocr)); acc.ocrTokens += Int(ocr) }
        }
        stats.items = items.items
        stats.links = items.links
        stats.lexemeAssets = items.counts
        stats.ocrItems = items.ocr.sorted { $0.tokens > $1.tokens || ($0.tokens == $1.tokens && $0.pk > $1.pk) }
        stats.ocrAssets = items.ocr.count
        stats.ocrTokens = items.ocrTokens
        if let lo = items.lo, let hi = items.hi, lo <= hi { stats.range = DossierDate.cocoa(lo)...DossierDate.cocoa(hi) }

        var linksPerCategory: [Int32: Int] = [:]
        for (id, n) in items.counts { if let c = lex.category[id] { linksPerCategory[c, default: 0] += Int(n) } }
        let codes = Set(lex.terms.keys).union(lex.synonyms.keys)
        stats.categories = codes.map { code in
            let info = SearchCategories.info(Int(code), backend: .leo)
            return SearchCategoryRow(code: Int(code), name: info.name, group: info.group, terms: lex.terms[code] ?? 0, synonyms: lex.synonyms[code] ?? 0,
                                     assetLinks: linksPerCategory[code] ?? 0, reveal: info.reveal, sensitivity: info.sensitivity)
        }.sorted { $0.code < $1.code }
        stats.terms = stats.categories.reduce(0) { $0 + $1.terms + $1.synonyms }
        return stats
    }

    private static func psiStats(_ lib: PhotosLibrary) async throws -> SearchIndexStats {
        let db = try await psi(lib)
        var stats = SearchIndexStats(backend: .psi, source: lib.psiDB)
        var terms: [Int: Int] = [:], links: [Int: Int] = [:]
        for row in try await db.rows("SELECT category, count(*) FROM groups GROUP BY 1") { terms[Int(row[0].int ?? 0)] = Int(row[1].int ?? 0) }
        for row in try await db.rows("SELECT g.category, count(*) FROM ga JOIN groups g ON g.rowid = ga.groupid GROUP BY 1") { links[Int(row[0].int ?? 0)] = Int(row[1].int ?? 0) }
        stats.categories = terms.keys.sorted().map { code in
            let info = SearchCategories.info(code, backend: .psi)
            return SearchCategoryRow(code: code, name: info.name, group: info.group, terms: terms[code] ?? 0, synonyms: 0, assetLinks: links[code] ?? 0, reveal: info.reveal, sensitivity: info.sensitivity)
        }
        stats.items = await db.rowCount(of: "assets") ?? 0
        stats.terms = terms.values.reduce(0, +)
        stats.links = links.values.reduce(0, +)
        stats.ocrTokens = links[SearchBackend.psi.ocrCode] ?? 0
        stats.ocrAssets = await db.count("SELECT count(DISTINCT ga.assetid) FROM ga JOIN groups g ON g.rowid = ga.groupid WHERE g.category = ?", [.integer(Int64(SearchBackend.psi.ocrCode))]) ?? 0
        return stats
    }

    // MARK: Terms of one category

    /// Terms of `category`, most assets first (or by the requested sort), paged.
    static func terms(_ lib: PhotosLibrary, backend: SearchBackend, category: Int, synonyms: Bool = true, request: PageRequest) async throws -> [SearchTermRow] {
        switch backend {
        case .psi:
            let db = try await psi(lib)
            let hasLookup = await db.hasColumns("groups", ["lookup_identifier"])
            var order = "n DESC, g.rowid"
            if let sort = request.sort {
                switch sort.columnID {
                case "content": order = "g.content_string COLLATE NOCASE \(sort.sqlDirection)"
                case "assets": order = "n \(sort.sqlDirection), g.rowid"
                default: break
                }
            }
            var sql = "SELECT g.rowid, g.content_string, \(hasLookup ? "g.lookup_identifier" : "''"), (SELECT count(*) FROM ga WHERE ga.groupid = g.rowid) n FROM groups g WHERE g.category = ?"
            var params: [SQLValue] = [.integer(Int64(category))]
            if !request.search.isEmpty { sql += " AND g.content_string LIKE ?"; params.append(.text("%\(request.search)%")) }
            sql += " ORDER BY \(order) LIMIT ? OFFSET ?"
            params += [.integer(Int64(request.limit)), .integer(Int64(request.offset))]
            return try await db.rows(sql, params).map { row in
                SearchTermRow(id: row[0].int ?? 0, content: row[1].string ?? "", identifier: row[2].string ?? "", assets: Int(row[3].int ?? 0), isSynonym: false, lexeme: row[0].int ?? 0)
            }
        case .leo:
            let all = try await LeoTermCache.shared.terms(lib, category: category, synonyms: synonyms, search: request.search, sort: request.sort)
            guard request.offset < all.count else { return [] }
            return Array(all[request.offset..<min(all.count, request.offset + request.limit)])
        }
    }

    static func termCount(_ lib: PhotosLibrary, backend: SearchBackend, category: Int, synonyms: Bool = true, search: String) async throws -> Int? {
        switch backend {
        case .psi:
            let db = try await psi(lib)
            if search.isEmpty { return await db.count("SELECT count(*) FROM groups WHERE category = ?", [.integer(Int64(category))]) }
            return await db.count("SELECT count(*) FROM groups WHERE category = ? AND content_string LIKE ?", [.integer(Int64(category)), .text("%\(search)%")])
        case .leo:
            return try await LeoTermCache.shared.terms(lib, category: category, synonyms: synonyms, search: search, sort: nil).count
        }
    }

    fileprivate static func leoTerms(_ lib: PhotosLibrary, category: Int, synonyms: Bool, search: String) async throws -> [SearchTermRow] {
        let s = try await leoSchema(lib)
        let stats = try await stats(lib, backend: .leo)
        let hasIdentifier = await s.db.hasColumns(s.lexicon, [s.identifier])
        var sql = "SELECT \(s.lexPK), \(s.lexemeID), \(s.type), \(s.content), \(hasIdentifier ? s.identifier : "''") FROM \(s.lexicon) WHERE \(s.category) = ?"
        var params: [SQLValue] = [.integer(Int64(category))]
        if !search.isEmpty { sql += " AND \(s.content) LIKE ?"; params.append(.text("%\(search)%")) }
        if !synonyms { sql += " AND \(s.type) != 2" }
        let counts = stats.lexemeAssets
        return try await s.db.rows(sql, params, maxRows: 2_000_000).map { row in
            let lexeme = row[1].int ?? 0
            return SearchTermRow(id: row[0].int ?? 0, content: row[3].string ?? "", identifier: row[4].string ?? "", assets: Int(counts[lexeme] ?? 0), isSynonym: (row[2].int ?? 1) == 2, lexeme: lexeme)
        }
    }

    /// Top primary terms of a category (used for country / city / scene charts).
    static func topTerms(_ lib: PhotosLibrary, backend: SearchBackend, category: Int, limit: Int) async throws -> [NamedCount] {
        let rows = try await terms(lib, backend: backend, category: category, request: PageRequest(offset: 0, limit: limit * 4))
        var seen = Set<String>()
        var out: [NamedCount] = []
        for row in rows where !row.isSynonym && !row.content.trimmingCharacters(in: .whitespaces).isEmpty && row.assets > 0 {
            if seen.insert(row.content).inserted { out.append(NamedCount(name: row.content, count: row.assets)) }
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: OCR text per asset

    /// Assets with recognised text and the tokens the index stores for them, most text first.
    static func ocrAssets(_ lib: PhotosLibrary, backend: SearchBackend, request: PageRequest) async throws -> [OCRAssetRow] {
        switch backend {
        case .leo:
            let s = try await leoSchema(lib)
            let stats = try await stats(lib, backend: .leo)
            let content = try await LeoTermCache.shared.ocrContent(lib)
            guard request.search.isEmpty else {
                // Search: find matching tokens, then the items carrying them (bounded scan of the item blobs).
                let wanted = Set(content.filter { $0.value.localizedCaseInsensitiveContains(request.search) }.keys)
                guard !wanted.isEmpty else { return [] }
                var out: [OCRAssetRow] = []
                var skipped = 0
                for chunk in stride(from: 0, to: stats.ocrItems.count, by: 400) {
                    if Task.isCancelled || out.count >= request.limit { break }
                    let pks = stats.ocrItems[chunk..<min(chunk + 400, stats.ocrItems.count)].map(\.pk)
                    for row in try await itemRows(s, pks: pks, content: content) where row.matches(wanted) {
                        if skipped < request.offset { skipped += 1; continue }
                        out.append(row.row)
                        if out.count >= request.limit { break }
                    }
                }
                return out
            }
            guard request.offset < stats.ocrItems.count else { return [] }
            let page = stats.ocrItems[request.offset..<min(stats.ocrItems.count, request.offset + request.limit)]
            let rows = try await itemRows(s, pks: page.map(\.pk), content: content)
            let byPK = Dictionary(rows.map { ($0.row.id, $0.row) }, uniquingKeysWith: { a, _ in a })
            return page.compactMap { byPK[$0.pk] }
        case .psi:
            let db = try await psi(lib)
            let code = Int64(SearchBackend.psi.ocrCode)
            var sql = "SELECT ga.assetid, count(*) n, group_concat(g.content_string, ' ') FROM ga JOIN groups g ON g.rowid = ga.groupid WHERE g.category = ?"
            var params: [SQLValue] = [.integer(code)]
            if !request.search.isEmpty {
                sql += " AND ga.assetid IN (SELECT ga2.assetid FROM ga ga2 JOIN groups g2 ON g2.rowid = ga2.groupid WHERE g2.category = ? AND g2.content_string LIKE ?)"
                params += [.integer(code), .text("%\(request.search)%")]
            }
            sql += " GROUP BY ga.assetid ORDER BY n DESC, ga.assetid LIMIT ? OFFSET ?"
            params += [.integer(Int64(request.limit)), .integer(Int64(request.offset))]
            return try await db.rows(sql, params).map { row in
                OCRAssetRow(id: row[0].int ?? 0, asset: "index asset \(row[0].int ?? 0)", date: nil, tokens: Int(row[1].int ?? 0), text: row[2].string ?? "")
            }
        }
    }

    static func ocrAssetCount(_ lib: PhotosLibrary, backend: SearchBackend, search: String) async throws -> Int? {
        guard search.isEmpty else { return nil }
        return try await stats(lib, backend: backend).ocrAssets
    }

    private struct ItemRow {
        let row: OCRAssetRow
        let lexemes: [Int64]
        func matches(_ wanted: Set<Int64>) -> Bool { lexemes.contains { wanted.contains($0) } }
    }

    private static func itemRows(_ s: LeoSchema, pks: [Int64], content: [Int64: String]) async throws -> [ItemRow] {
        guard !pks.isEmpty else { return [] }
        let hasDate = await s.db.hasColumns(s.items, [s.itemDate])
        let list = pks.map(String.init).joined(separator: ",")
        return try await s.db.rows("SELECT \(s.itemPK), \(s.itemIdentifier), \(hasDate ? s.itemDate : "NULL"), \(s.itemLexemes) FROM \(s.items) WHERE \(s.itemPK) IN (\(list))").map { row in
            var tokens: [String] = []
            var ids: [Int64] = []
            if let blob = row[3].data {
                forEachLexeme(blob) { id in
                    if let text = content[id] { tokens.append(text); ids.append(id) }
                }
            }
            return ItemRow(row: OCRAssetRow(id: row[0].int ?? 0, asset: row[1].string ?? "", date: row[2].cocoaDate, tokens: tokens.count, text: tokens.joined(separator: " ")), lexemes: ids)
        }
    }

    fileprivate static func leoOCRContent(_ lib: PhotosLibrary) async throws -> [Int64: String] {
        let s = try await leoSchema(lib)
        return try await s.db.reduce("SELECT \(s.lexemeID), \(s.content) FROM \(s.lexicon) WHERE \(s.category) = \(SearchBackend.leo.ocrCode)", into: [Int64: String]()) { acc, row in
            if let id = row[0].int, let text = row[1].string { acc[id] = text }
        }
    }
}

/// Keeps the sorted term list of the most recently viewed Leo category (the lexicon has no asset counts to ORDER BY).
actor LeoTermCache {
    static let shared = LeoTermCache()
    private var key = ""
    private var base: [SearchTermRow] = []
    private var sortedKey = ""
    private var sorted: [SearchTermRow] = []
    private var ocrKey = ""
    private var ocr: [Int64: String] = [:]

    func terms(_ lib: PhotosLibrary, category: Int, synonyms: Bool, search: String, sort: PageSort?) async throws -> [SearchTermRow] {
        let k = "\(lib.id)|\(category)|\(synonyms)|\(search)"
        if k != key {
            base = try await SearchIndexStore.leoTerms(lib, category: category, synonyms: synonyms, search: search)
            key = k
            sortedKey = ""
        }
        let sk = k + "|" + (sort.map { "\($0.columnID)\($0.ascending)" } ?? "")
        if sk != sortedKey {
            switch sort?.columnID {
            case "content":
                let asc = sort?.ascending ?? true
                sorted = base.sorted { asc ? $0.content.localizedStandardCompare($1.content) == .orderedAscending : $0.content.localizedStandardCompare($1.content) == .orderedDescending }
            case "assets" where sort?.ascending == true:
                sorted = base.sorted { ($0.assets, $0.id) < ($1.assets, $1.id) }
            default:
                sorted = base.sorted { $0.assets > $1.assets || ($0.assets == $1.assets && $0.id < $1.id) }
            }
            sortedKey = sk
        }
        return sorted
    }

    func ocrContent(_ lib: PhotosLibrary) async throws -> [Int64: String] {
        if ocrKey != lib.id {
            ocr = try await SearchIndexStore.leoOCRContent(lib)
            ocrKey = lib.id
        }
        return ocr
    }

    func reset() { key = ""; sortedKey = ""; base = []; sorted = []; ocrKey = ""; ocr = [:] }
}
