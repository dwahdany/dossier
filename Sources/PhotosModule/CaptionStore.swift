import Foundation
import DossierCore

// Machine-written descriptions of the owner's photos and videos.
//
//  • MediaAnalysis.sqlite (mediaanalysisd): ZIMAGECAPTIONRESULT / ZVIDEOCAPTIONRESULT /
//    ZVIDEOSEGMENTCAPTIONRESULT (ZCAPTION, ZCONFIDENCE, ZISUNSAFE) joined to ZASSET(ZLOCALIDENTIFIER).
//  • Photos.sqlite embedded graph: ZGRAPHNODE rows with primary label code 1300 are caption nodes
//    (ZGRAPHNODEVALUE name codes 1000 = caption type, 1001 = text, 1002 = model version), linked from
//    the asset by a ZGRAPHEDGE whose label has the same code.
//  • Photos.sqlite ZASSETDESCRIPTION.ZLONGDESCRIPTION: descriptions stored with the asset (user / EXIF).
//  • Recognised text (OCR): the per-asset tokens kept by the search index (see SearchIndexStore). The raw
//    ZCHARACTERRECOGNITIONDATA archives hold compressed layout documents and are only counted.

enum CaptionSource: String, Sendable, CaseIterable, Identifiable, Hashable {
    case image, video, videoSegment, graph, description, ocr
    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Image Captions"
        case .video: return "Video Captions"
        case .videoSegment: return "Video Segments"
        case .graph: return "Graph Captions"
        case .description: return "Descriptions"
        case .ocr: return "Recognised Text"
        }
    }

    var explanation: String {
        switch self {
        case .image: return "One sentence per photo written by the on-device captioning model (mediaanalysisd), with its confidence."
        case .video: return "One sentence per video written by the on-device video captioning model."
        case .videoSegment: return "Captions for individual time ranges inside videos."
        case .graph: return "Caption nodes of the graph embedded in Photos.sqlite: a short and a detailed sentence per asset, used for natural-language search."
        case .description: return "Descriptions stored with the asset itself (typed by you or imported from file metadata)."
        case .ocr: return "Words the text recogniser found inside your photos, as kept by the search index."
        }
    }
}

struct CaptionRow: Sendable, Identifiable, Hashable {
    let id: String
    let date: Date?
    let text: String
    let confidence: Double?
    let flag: String
    let asset: String
    let detail: String
    let count: Int
}

struct CaptionStats: Sendable {
    var counts: [CaptionSource: Int] = [:]
    var unsafeImages = 0
    var averageConfidence: Double?
    var ocrBlobs = 0
    var searchBackend: SearchBackend?
    var mediaAnalysisURL: URL?
    var audio: [NamedCount] = []
    var safety: [NamedCount] = []
}

enum CaptionStore {
    private static func media(_ lib: PhotosLibrary) async throws -> SQLiteDB {
        try await lib.open(lib.mediaAnalysisDB ?? lib.expectedMediaAnalysisDB, "MediaAnalysis.sqlite")
    }

    static func stats(_ lib: PhotosLibrary) async -> CaptionStats {
        var s = CaptionStats()
        s.mediaAnalysisURL = lib.mediaAnalysisDB
        if let db = try? await media(lib) {
            if await db.hasColumns("ZIMAGECAPTIONRESULT", ["ZCAPTION"]) {
                s.counts[.image] = await db.count("SELECT count(*) FROM ZIMAGECAPTIONRESULT WHERE length(ZCAPTION) > 0")
                if await db.hasColumns("ZIMAGECAPTIONRESULT", ["ZISUNSAFE", "ZCONFIDENCE"]),
                   let r = try? await db.first("SELECT sum(ZISUNSAFE != 0), avg(ZCONFIDENCE) FROM ZIMAGECAPTIONRESULT") {
                    s.unsafeImages = Int(r[0].int ?? 0); s.averageConfidence = r[1].double
                }
            }
            if await db.hasColumns("ZVIDEOCAPTIONRESULT", ["ZCAPTION"]) { s.counts[.video] = await db.count("SELECT count(*) FROM ZVIDEOCAPTIONRESULT WHERE length(ZCAPTION) > 0") }
            if await db.hasColumns("ZVIDEOSEGMENTCAPTIONRESULT", ["ZCAPTION"]) { s.counts[.videoSegment] = await db.count("SELECT count(*) FROM ZVIDEOSEGMENTCAPTIONRESULT WHERE length(ZCAPTION) > 0") }
            // What the audio / action classifiers heard and saw (row counts of the result tables).
            let audioTables: [(String, String)] = [
                ("ZVOICERESULT", "Speech"), ("ZMUSICRESULT", "Music"), ("ZLAUGHTERRESULT", "Laughter"), ("ZAPPLAUSERESULT", "Applause"),
                ("ZCHEERINGRESULT", "Cheering"), ("ZBABBLERESULT", "Babble"), ("ZPETSRESULT", "Pets"), ("ZHUMANACTIONRESULT", "Human actions"),
                ("ZHUMANPOSERESULT", "Human poses"), ("ZFACERESULT", "Faces in video"),
            ]
            for (table, name) in audioTables where await db.tableExists(table) {
                if let n = await db.rowCount(of: table), n > 0 { s.audio.append(NamedCount(name: name, count: n, detail: table)) }
            }
            s.audio.sort { $0.count > $1.count }
            if await db.hasColumns("ZSAFETYRESULT", ["ZSENSITIVITY"]) {
                s.safety = ((try? await db.rows("SELECT ZSENSITIVITY, count(*) FROM ZSAFETYRESULT GROUP BY 1 ORDER BY 1")) ?? []).map {
                    NamedCount(name: "sensitivity code \($0[0].int ?? 0)", count: Int($0[1].int ?? 0))
                }
            }
        }
        if let db = try? await lib.photos() {
            if await db.hasColumns("ZGRAPHNODEVALUE", ["ZNAMECODE", "ZSTRINGVALUE"]) {
                s.counts[.graph] = await db.count("SELECT count(*) FROM ZGRAPHNODEVALUE WHERE ZNAMECODE = 1001 AND length(trim(ZSTRINGVALUE)) > 0")
            }
            if await db.hasColumns("ZASSETDESCRIPTION", ["ZLONGDESCRIPTION"]) {
                s.counts[.description] = await db.count("SELECT count(*) FROM ZASSETDESCRIPTION WHERE length(ZLONGDESCRIPTION) > 0")
            }
            if await db.hasColumns("ZCHARACTERRECOGNITIONATTRIBUTES", ["ZCHARACTERRECOGNITIONDATA"]) {
                s.ocrBlobs = await db.count("SELECT count(*) FROM ZCHARACTERRECOGNITIONATTRIBUTES WHERE ZCHARACTERRECOGNITIONDATA IS NOT NULL") ?? 0
            }
        }
        if let backend = await SearchIndexStore.preferredBackend(lib), let stats = try? await SearchIndexStore.stats(lib, backend: backend) {
            s.searchBackend = backend
            s.counts[.ocr] = stats.ocrAssets
        }
        return s
    }

    static func rows(_ lib: PhotosLibrary, source: CaptionSource, request: PageRequest) async throws -> [CaptionRow] {
        let like = "%\(request.search)%"
        let page: [SQLValue] = [.integer(Int64(request.limit)), .integer(Int64(request.offset))]
        switch source {
        case .image, .video, .videoSegment:
            let db = try await media(lib)
            let table = source == .image ? "ZIMAGECAPTIONRESULT" : (source == .video ? "ZVIDEOCAPTIONRESULT" : "ZVIDEOSEGMENTCAPTIONRESULT")
            guard await db.hasColumns(table, ["ZCAPTION", "ZASSET"]) else { throw DossierError.missing("MediaAnalysis.sqlite has no \(table) table on this macOS version.") }
            let c = await db.existing(table, ["ZCONFIDENCE", "ZISUNSAFE", "ZSTARTTIMEVALUE", "ZSTARTTIMESCALE", "ZDURATIONTIMEVALUE", "ZDURATIONTIMESCALE"])
            let a = await db.existing("ZASSET", ["ZLOCALIDENTIFIER", "ZDATEMODIFIED"])
            var order = a.contains("ZDATEMODIFIED") ? "a.ZDATEMODIFIED DESC, c.Z_PK DESC" : "c.Z_PK DESC"
            if let sort = request.sort {
                switch sort.columnID {
                case "date" where a.contains("ZDATEMODIFIED"): order = "a.ZDATEMODIFIED \(sort.sqlDirection), c.Z_PK"
                case "confidence" where c.contains("ZCONFIDENCE"): order = "c.ZCONFIDENCE \(sort.sqlDirection), c.Z_PK"
                case "length": order = "length(c.ZCAPTION) \(sort.sqlDirection), c.Z_PK"
                default: break
                }
            }
            let segment = c.contains("ZSTARTTIMEVALUE") && c.contains("ZSTARTTIMESCALE")
            var sql = """
                SELECT c.Z_PK, c.ZCAPTION, \(sqlColumn(c, "ZCONFIDENCE", prefix: "c.")), \(sqlColumn(c, "ZISUNSAFE", prefix: "c.", fallback: "0")),
                       \(sqlColumn(a, "ZLOCALIDENTIFIER", prefix: "a.", fallback: "''")), \(sqlColumn(a, "ZDATEMODIFIED", prefix: "a.")),
                       \(segment ? "CAST(c.ZSTARTTIMEVALUE AS REAL) / max(c.ZSTARTTIMESCALE, 1)" : "NULL"),
                       \(segment && c.contains("ZDURATIONTIMEVALUE") && c.contains("ZDURATIONTIMESCALE") ? "CAST(c.ZDURATIONTIMEVALUE AS REAL) / max(c.ZDURATIONTIMESCALE, 1)" : "NULL")
                FROM \(table) c LEFT JOIN ZASSET a ON a.Z_PK = c.ZASSET WHERE length(c.ZCAPTION) > 0
                """
            var params: [SQLValue] = []
            if !request.search.isEmpty { sql += " AND c.ZCAPTION LIKE ?"; params.append(.text(like)) }
            sql += " ORDER BY \(order) LIMIT ? OFFSET ?"
            return try await db.rows(sql, params + page).map { row in
                var detail = ""
                if let start = row[6].double { detail = "at \(Format.duration(start))" + (row[7].double.map { " for \(Format.duration($0))" } ?? "") }
                let text = row[1].string ?? ""
                return CaptionRow(id: "\(source.rawValue)-\(row[0].int ?? 0)", date: row[5].cocoaDate, text: text, confidence: row[2].double,
                                  flag: (row[3].int ?? 0) != 0 ? "unsafe" : "", asset: (row[4].string ?? "").split(separator: "/").first.map(String.init) ?? "", detail: detail, count: text.count)
            }
        case .graph:
            let db = try await lib.photos()
            guard await db.hasColumns("ZGRAPHNODEVALUE", ["ZNODE", "ZNAMECODE", "ZSTRINGVALUE", "ZINTEGERVALUE"]), await db.hasColumns("ZGRAPHEDGE", ["ZTARGETNODE", "ZSOURCEASSET"]) else {
                throw DossierError.missing("Photos.sqlite has no embedded graph tables (ZGRAPHNODE / ZGRAPHNODEVALUE) on this macOS version.")
            }
            // `+ZNAMECODE` keeps SQLite on the per-node index; the name-code indexes would turn the lookups into scans.
            var order = "s.ZNODE DESC"
            if let sort = request.sort {
                switch sort.columnID {
                case "length": order = "length(s.ZSTRINGVALUE) \(sort.sqlDirection), s.ZNODE"
                case "date": order = "s.ZNODE \(sort.sqlDirection)"
                default: break
                }
            }
            var sql = """
                SELECT s.ZNODE, s.ZSTRINGVALUE,
                       (SELECT t.ZINTEGERVALUE FROM ZGRAPHNODEVALUE t WHERE t.ZNODE = s.ZNODE AND +t.ZNAMECODE = 1000),
                       (SELECT v.ZINTEGERVALUE FROM ZGRAPHNODEVALUE v WHERE v.ZNODE = s.ZNODE AND +v.ZNAMECODE = 1002),
                       (SELECT a.ZDATECREATED FROM ZGRAPHEDGE e JOIN ZASSET a ON a.Z_PK = e.ZSOURCEASSET WHERE e.ZTARGETNODE = s.ZNODE LIMIT 1),
                       (SELECT a.ZUUID FROM ZGRAPHEDGE e JOIN ZASSET a ON a.Z_PK = e.ZSOURCEASSET WHERE e.ZTARGETNODE = s.ZNODE LIMIT 1)
                FROM ZGRAPHNODEVALUE s WHERE s.ZNAMECODE = 1001 AND length(trim(s.ZSTRINGVALUE)) > 0
                """
            var params: [SQLValue] = []
            if !request.search.isEmpty { sql += " AND s.ZSTRINGVALUE LIKE ?"; params.append(.text(like)) }
            sql += " ORDER BY \(order) LIMIT ? OFFSET ?"
            return try await db.rows(sql, params + page).map { row in
                let text = row[1].string ?? ""
                let type = row[2].int.map { "type \($0)" } ?? ""
                let version = row[3].int.map { "model v\($0)" } ?? ""
                return CaptionRow(id: "graph-\(row[0].int ?? 0)", date: row[4].cocoaDate, text: text, confidence: nil, flag: type, asset: row[5].string ?? "", detail: version, count: text.count)
            }
        case .description:
            let db = try await lib.photos()
            guard await db.hasColumns("ZASSETDESCRIPTION", ["ZLONGDESCRIPTION", "ZASSETATTRIBUTES"]) else { throw DossierError.missing("Photos.sqlite has no ZASSETDESCRIPTION table.") }
            var sql = """
                SELECT d.Z_PK, d.ZLONGDESCRIPTION, a.ZDATECREATED, a.ZUUID
                FROM ZASSETDESCRIPTION d LEFT JOIN ZADDITIONALASSETATTRIBUTES x ON x.Z_PK = d.ZASSETATTRIBUTES LEFT JOIN ZASSET a ON a.Z_PK = x.ZASSET
                WHERE length(d.ZLONGDESCRIPTION) > 0
                """
            var params: [SQLValue] = []
            if !request.search.isEmpty { sql += " AND d.ZLONGDESCRIPTION LIKE ?"; params.append(.text(like)) }
            let direction = request.sort?.columnID == "date" ? (request.sort?.sqlDirection ?? "DESC") : "DESC"
            sql += " ORDER BY \(request.sort?.columnID == "length" ? "length(d.ZLONGDESCRIPTION) \(request.sort?.sqlDirection ?? "DESC")" : "a.ZDATECREATED \(direction)"), d.Z_PK LIMIT ? OFFSET ?"
            return try await db.rows(sql, params + page).map { row in
                let text = row[1].string ?? ""
                return CaptionRow(id: "desc-\(row[0].int ?? 0)", date: row[2].cocoaDate, text: text, confidence: nil, flag: "", asset: row[3].string ?? "", detail: "", count: text.count)
            }
        case .ocr:
            guard let backend = await SearchIndexStore.preferredBackend(lib) else {
                throw DossierError.missing("No search index was found in this library, so recognised text cannot be listed.")
            }
            return try await SearchIndexStore.ocrAssets(lib, backend: backend, request: request).map { row in
                CaptionRow(id: "ocr-\(row.id)", date: row.date, text: row.text, confidence: nil, flag: "", asset: row.asset, detail: "", count: row.tokens)
            }
        }
    }

    static func count(_ lib: PhotosLibrary, source: CaptionSource, search: String) async throws -> Int? {
        let like: [SQLValue] = [.text("%\(search)%")]
        switch source {
        case .image, .video, .videoSegment:
            let db = try await media(lib)
            let table = source == .image ? "ZIMAGECAPTIONRESULT" : (source == .video ? "ZVIDEOCAPTIONRESULT" : "ZVIDEOSEGMENTCAPTIONRESULT")
            return search.isEmpty ? await db.count("SELECT count(*) FROM \(table) WHERE length(ZCAPTION) > 0")
                                  : await db.count("SELECT count(*) FROM \(table) WHERE length(ZCAPTION) > 0 AND ZCAPTION LIKE ?", like)
        case .graph:
            let db = try await lib.photos()
            return search.isEmpty ? await db.count("SELECT count(*) FROM ZGRAPHNODEVALUE WHERE ZNAMECODE = 1001 AND length(trim(ZSTRINGVALUE)) > 0")
                                  : await db.count("SELECT count(*) FROM ZGRAPHNODEVALUE WHERE ZNAMECODE = 1001 AND length(trim(ZSTRINGVALUE)) > 0 AND ZSTRINGVALUE LIKE ?", like)
        case .description:
            let db = try await lib.photos()
            return search.isEmpty ? await db.count("SELECT count(*) FROM ZASSETDESCRIPTION WHERE length(ZLONGDESCRIPTION) > 0")
                                  : await db.count("SELECT count(*) FROM ZASSETDESCRIPTION WHERE length(ZLONGDESCRIPTION) > 0 AND ZLONGDESCRIPTION LIKE ?", like)
        case .ocr:
            guard let backend = await SearchIndexStore.preferredBackend(lib) else { return nil }
            return try await SearchIndexStore.ocrAssetCount(lib, backend: backend, search: search)
        }
    }

    /// Embedded graph of Photos.sqlite: node / edge counts per label code (shown raw; only the caption label is understood).
    static func embeddedGraphLabels(_ lib: PhotosLibrary) async throws -> [NamedCount] {
        let db = try await lib.photos()
        guard await db.hasColumns("ZGRAPHNODE", ["ZPRIMARYLABELCODE"]) else { return [] }
        let known: [Int: String] = [1100: "Search entity", 1300: "Caption", 2000: "Asset / moment / person proxy"]
        return try await db.rows("SELECT ZPRIMARYLABELCODE, count(*) FROM ZGRAPHNODE GROUP BY 1 ORDER BY 2 DESC").map { row in
            let code = Int(row[0].int ?? 0)
            return NamedCount(name: known[code].map { "\($0) (\(code))" } ?? "label \(code)", count: Int(row[1].int ?? 0))
        }
    }
}
