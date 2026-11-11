import Foundation
import DossierCore

// Queries against Photos.sqlite (Core Data store; Cocoa-epoch timestamps).
// Every function probes the columns it needs and degrades when they are missing.

struct YearCount: Sendable, Identifiable, Hashable {
    var id: Int { year }
    let year: Int
    let photos: Int
    let videos: Int
}

struct NamedCount: Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let count: Int
    var detail: String = ""
}

struct Coverage: Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let detail: String
    let done: Int
    let total: Int
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

struct LibrarySummary: Sendable {
    var assets = 0
    var photos = 0
    var videos = 0
    var withLocation = 0
    var favorites = 0
    var hidden = 0
    var trashed = 0
    var screenshots = 0
    var range: ClosedRange<Date>?
    /// Face clusters that still stand for somebody: not merged away, at least one face.
    var persons = 0
    /// Named, not merged away, human detection class.
    var namedPersons = 0
    /// Named, not merged away, non-human detection class.
    var namedPets = 0
    var personRows = 0
    var mergedPersons = 0
    var facelessPersons = 0
    var faces = 0
    var moments = 0
    var memories = 0
    var highlights = 0
    var sceneClassifications = 0
    var years: [YearCount] = []
    var cameras: [NamedCount] = []
    var sources: [NamedCount] = []
    var subtypes: [NamedCount] = []
    var countries: [NamedCount] = []
    var coverage: [Coverage] = []
    var searchBackend: SearchBackend?
}

enum PhotosStore {
    // MARK: Summary

    static func summary(_ lib: PhotosLibrary) async throws -> LibrarySummary {
        let db = try await lib.photos()
        guard await db.hasColumns("ZASSET", ["Z_PK", "ZKIND", "ZDATECREATED"]) else {
            throw DossierError.missing("Photos.sqlite has no ZASSET table with the expected columns on this macOS version.")
        }
        var s = LibrarySummary()
        let a = await db.existing("ZASSET", ["ZLATITUDE", "ZFAVORITE", "ZHIDDEN", "ZTRASHEDSTATE", "ZISDETECTEDSCREENSHOT", "ZKINDSUBTYPE"])
        let live = a.contains("ZTRASHEDSTATE") ? "ZTRASHEDSTATE = 0" : "1"
        if let r = try await db.first("""
            SELECT count(*), sum(ZKIND = 0), sum(ZKIND = 1),
                   \(a.contains("ZLATITUDE") ? "sum(ZLATITUDE BETWEEN -90 AND 90 AND NOT (ZLATITUDE = 0 AND ZLONGITUDE = 0))" : "0"),
                   \(a.contains("ZFAVORITE") ? "sum(ZFAVORITE != 0)" : "0"), \(a.contains("ZHIDDEN") ? "sum(ZHIDDEN != 0)" : "0"),
                   \(a.contains("ZTRASHEDSTATE") ? "sum(ZTRASHEDSTATE != 0)" : "0"),
                   \(a.contains("ZISDETECTEDSCREENSHOT") ? "sum(ZISDETECTEDSCREENSHOT != 0)" : "0"),
                   min(ZDATECREATED), max(ZDATECREATED)
            FROM ZASSET
            """) {
            s.assets = Int(r[0].int ?? 0); s.photos = Int(r[1].int ?? 0); s.videos = Int(r[2].int ?? 0)
            s.withLocation = Int(r[3].int ?? 0); s.favorites = Int(r[4].int ?? 0); s.hidden = Int(r[5].int ?? 0)
            s.trashed = Int(r[6].int ?? 0); s.screenshots = Int(r[7].int ?? 0)
            if let lo = r[8].cocoaDate, let hi = r[9].cocoaDate, lo <= hi { s.range = lo...hi }
        }
        s.years = try await db.rows("""
            SELECT CAST(strftime('%Y', ZDATECREATED + 978307200, 'unixepoch', 'localtime') AS INTEGER) y, sum(ZKIND = 0), sum(ZKIND != 0)
            FROM ZASSET WHERE ZDATECREATED IS NOT NULL AND \(live) GROUP BY y ORDER BY y
            """).compactMap { row in
            guard let y = row[0].int else { return nil }
            return YearCount(year: Int(y), photos: Int(row[1].int ?? 0), videos: Int(row[2].int ?? 0))
        }
        if a.contains("ZKINDSUBTYPE") {
            s.subtypes = try await db.rows("SELECT ZKIND, ZKINDSUBTYPE, count(*) FROM ZASSET WHERE \(live) GROUP BY 1, 2 ORDER BY 3 DESC").map { row in
                let kind = Int(row[0].int ?? 0), sub = Int(row[1].int ?? 0)
                let name = sub == 0 ? PhotosCodes.assetKind.shortLabel(kind) : PhotosCodes.assetSubtype.shortLabel(sub)
                return NamedCount(name: name, count: Int(row[2].int ?? 0), detail: "kind \(kind) · subtype \(sub)")
            }
        }
        if await db.hasColumns("ZEXTENDEDATTRIBUTES", ["ZCAMERAMAKE", "ZCAMERAMODEL"]) {
            s.cameras = try await db.rows("""
                SELECT coalesce(ZCAMERAMAKE, ''), coalesce(ZCAMERAMODEL, ''), count(*) FROM ZEXTENDEDATTRIBUTES
                WHERE ZCAMERAMODEL IS NOT NULL GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 14
                """).map { row in
                let make = row[0].string ?? "", model = row[1].string ?? ""
                let name = model.lowercased().hasPrefix(make.lowercased()) || make.isEmpty ? model : "\(make) \(model)"
                return NamedCount(name: name, count: Int(row[2].int ?? 0))
            }
        }
        let add = await db.existing("ZADDITIONALASSETATTRIBUTES", ["ZIMPORTEDBYBUNDLEIDENTIFIER", "ZIMPORTEDBYDISPLAYNAME", "ZIMPORTEDBY", "ZFACEANALYSISVERSION", "ZSCENEANALYSISVERSION", "ZREVERSELOCATIONDATAISVALID", "ZASSET"])
        if add.contains("ZIMPORTEDBYBUNDLEIDENTIFIER") {
            let display = add.contains("ZIMPORTEDBYDISPLAYNAME") ? "max(ZIMPORTEDBYDISPLAYNAME)" : "NULL"
            s.sources = try await db.rows("""
                SELECT coalesce(ZIMPORTEDBYBUNDLEIDENTIFIER, ''), \(display), count(*) FROM ZADDITIONALASSETATTRIBUTES
                GROUP BY 1 ORDER BY 3 DESC LIMIT 14
                """).map { row in
                let bundle = row[0].string ?? ""
                let display = row[1].string ?? ""
                let name = bundle.isEmpty ? "No source app recorded" : (display.isEmpty ? bundle : display)
                return NamedCount(name: name, count: Int(row[2].int ?? 0), detail: bundle)
            }
        }
        let people = await personCounts(db)
        async let faces = db.count("SELECT count(*) FROM ZDETECTEDFACE")
        async let moments = db.count("SELECT count(*) FROM ZMOMENT")
        async let memories = db.count("SELECT count(*) FROM ZMEMORY")
        async let highlights = db.count("SELECT count(*) FROM ZPHOTOSHIGHLIGHT")
        async let scenes = db.count("SELECT count(*) FROM ZSCENECLASSIFICATION")
        s.persons = people.clusters; s.namedPersons = people.namedPeople; s.namedPets = people.namedPets
        s.personRows = people.rows; s.mergedPersons = people.merged; s.facelessPersons = people.withoutFaces
        s.faces = await faces ?? 0
        s.moments = await moments ?? 0; s.memories = await memories ?? 0; s.highlights = await highlights ?? 0
        s.sceneClassifications = await scenes ?? 0
        s.coverage = await coverage(db, total: s.assets, additional: add)
        return s
    }

    /// How many assets each on-device analysis pipeline has processed (version column > 0).
    private static func coverage(_ db: SQLiteDB, total: Int, additional add: Set<String>) async -> [Coverage] {
        var out: [Coverage] = []
        func addRow(_ name: String, _ detail: String, _ sql: String) async {
            if let n = await db.count(sql) { out.append(Coverage(name: name, detail: detail, done: n, total: total)) }
        }
        if add.contains("ZSCENEANALYSISVERSION") {
            await addRow("Scene classification", "Objects and scenes recognised in the image", "SELECT count(*) FROM ZADDITIONALASSETATTRIBUTES WHERE ZSCENEANALYSISVERSION > 0")
        }
        if add.contains("ZFACEANALYSISVERSION") {
            await addRow("Face analysis", "Face detection and clustering has run", "SELECT count(*) FROM ZADDITIONALASSETATTRIBUTES WHERE ZFACEANALYSISVERSION > 0")
        }
        if add.contains("ZREVERSELOCATIONDATAISVALID") {
            await addRow("Reverse geocoding", "Coordinates resolved to a postal address", "SELECT count(*) FROM ZADDITIONALASSETATTRIBUTES WHERE ZREVERSELOCATIONDATAISVALID != 0")
        }
        let m = await db.existing("ZMEDIAANALYSISASSETATTRIBUTES", ["ZMEDIAANALYSISVERSION", "ZCHARACTERRECOGNITIONVERSION", "ZIMAGECAPTIONVERSION", "ZIMAGEEMBEDDINGVERSION", "ZVISUALSEARCHVERSION", "ZVIDEOCAPTIONVERSION", "ZRICHIMAGECAPTIONVERSION"])
        let media: [(String, String, String)] = [
            ("ZMEDIAANALYSISVERSION", "Media analysis", "Quality, motion, audio and activity scores"),
            ("ZCHARACTERRECOGNITIONVERSION", "Text recognition (OCR)", "Scanned for text in the image"),
            ("ZIMAGECAPTIONVERSION", "Image caption", "A machine-written sentence describing the photo"),
            ("ZIMAGEEMBEDDINGVERSION", "Semantic embedding", "Vector used for natural-language search"),
            ("ZVISUALSEARCHVERSION", "Visual Look Up", "Plants, animals, landmarks, artworks"),
            ("ZVIDEOCAPTIONVERSION", "Video caption", "A machine-written sentence describing the video"),
        ]
        for (column, name, detail) in media where m.contains(column) {
            await addRow(name, detail, "SELECT count(*) FROM ZMEDIAANALYSISASSETATTRIBUTES WHERE \(column) > 0")
        }
        if await db.hasColumns("ZCHARACTERRECOGNITIONATTRIBUTES", ["ZCHARACTERRECOGNITIONDATA"]) {
            await addRow("Text found", "Assets where OCR actually found text", "SELECT count(*) FROM ZCHARACTERRECOGNITIONATTRIBUTES WHERE ZCHARACTERRECOGNITIONDATA IS NOT NULL")
        }
        if await db.tableExists("ZCOMPUTEDASSETATTRIBUTES") {
            await addRow("Aesthetic scoring", "Composition, lighting, focus and “interestingness” scores", "SELECT count(*) FROM ZCOMPUTEDASSETATTRIBUTES")
        }
        if await db.hasColumns("ZLEOITEM", ["ZITEMTYPE"]) {
            await addRow("Search index", "Assets present in the on-device search index", "SELECT count(*) FROM ZLEOITEM WHERE ZITEMTYPE = 1")
        }
        return out
    }

    // MARK: People

    struct PersonRow: Sendable, Identifiable, Hashable {
        let id: Int64
        let name: String
        let displayName: String
        /// Faces actually assigned to this person (rows of ZDETECTEDFACE).
        let faces: Int
        /// ZFACECOUNT as stored — a cache that is 0 for most unnamed clusters even when they have faces.
        let faceCount: Int
        let type: Int?
        let verified: Int?
        let detection: Int?
        let age: Int?
        let gender: Int?
        let hasContact: Bool
        let meConfidence: Double?
        let uuid: String
        let merged: Bool
        let shareParticipant: Bool

        var title: String { !name.isEmpty ? name : (!displayName.isEmpty ? displayName : "Unnamed #\(id)") }
        var isNamed: Bool { !name.isEmpty || !displayName.isEmpty }
    }

    enum PersonFilter: String, Sendable, CaseIterable, Identifiable {
        case named = "Named", pets = "Pets", all = "All Clusters"
        var id: String { rawValue }
    }

    private static let personSortable: Set<String> = ["ZFULLNAME", "ZFACECOUNT", "ZTYPE", "ZVERIFIEDTYPE", "ZDETECTIONTYPE", "ZAGETYPE", "ZGENDERTYPE", "ZISMECONFIDENCE", "Z_PK"]

    /// SQL predicate: this ZPERSON row was merged into another person and no longer stands for
    /// anybody. ZVERIFIEDTYPE = -2 occurs exactly on the rows that have a merge target.
    static func mergedClause(_ c: Set<String>) -> String {
        var parts: [String] = []
        if c.contains("ZMERGETARGETPERSON") { parts.append("ZMERGETARGETPERSON IS NOT NULL") }
        if c.contains("ZVERIFIEDTYPE") { parts.append("coalesce(ZVERIFIEDTYPE, 0) = -2") }
        return parts.isEmpty ? "0" : "(" + parts.joined(separator: " OR ") + ")"
    }

    private static func namedClause(_ c: Set<String>) -> String {
        let parts = ["ZFULLNAME", "ZDISPLAYNAME"].filter(c.contains).map { "coalesce(length(\($0)), 0) > 0" }
        return parts.isEmpty ? "0" : "(" + parts.joined(separator: " OR ") + ")"
    }

    /// The human detection class is 1; other classes are the pets the search index lists.
    private static func humanClause(_ c: Set<String>) -> String {
        c.contains("ZDETECTIONTYPE") ? "coalesce(ZDETECTIONTYPE, 1) = 1" : "1"
    }

    /// Column of ZDETECTEDFACE that points at the person (renamed between schema versions).
    static func facePersonColumn(_ db: SQLiteDB) async -> String? {
        let f = await db.existing("ZDETECTEDFACE", ["ZPERSONFORFACE", "ZPERSON"])
        return f.contains("ZPERSONFORFACE") ? "ZPERSONFORFACE" : (f.contains("ZPERSON") ? "ZPERSON" : nil)
    }

    /// Number of faces assigned to the ZPERSON row of the enclosing query (covered by the index
    /// Core Data keeps on the relationship). ZFACECOUNT is not used: it is a cache that stays 0
    /// for most unnamed clusters.
    private static func facesExpr(_ faceColumn: String?, _ c: Set<String>) -> String {
        if let faceColumn { return "(SELECT count(*) FROM ZDETECTEDFACE f WHERE f.\(faceColumn) = ZPERSON.Z_PK)" }
        return sqlColumn(c, "ZFACECOUNT", fallback: "0")
    }

    private static func hasFaceExpr(_ faceColumn: String?, _ c: Set<String>) -> String {
        if let faceColumn { return "EXISTS(SELECT 1 FROM ZDETECTEDFACE f WHERE f.\(faceColumn) = ZPERSON.Z_PK)" }
        return c.contains("ZFACECOUNT") ? "coalesce(ZFACECOUNT, 0) > 0" : "1"
    }

    struct PersonCounts: Sendable {
        /// All ZPERSON rows, including merged-away duplicates and clusters without faces.
        var rows = 0
        /// Named, not merged away, human class.
        var namedPeople = 0
        /// Named, not merged away, non-human class.
        var namedPets = 0
        /// Not merged away and holding at least one face.
        var clusters = 0
        /// Clusters of a non-human class.
        var petClusters = 0
        var merged = 0
        /// Not merged away, but no face points at them.
        var withoutFaces = 0
        var verified = 0
        var withContact = 0

        /// "12 named people, 2 named pets"
        var namedText: String {
            var parts = ["\(Format.count(namedPeople)) named \(namedPeople == 1 ? "person" : "people")"]
            if namedPets > 0 { parts.append("\(Format.count(namedPets)) named pet\(namedPets == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        }
    }

    /// One pass over ZPERSON. A person merged into another one keeps its row (and its name), so
    /// counting rows overstates how many people the library knows; merged rows are left out, and
    /// a cluster only counts when a face is assigned to it.
    static func personCounts(_ db: SQLiteDB) async -> PersonCounts {
        var out = PersonCounts()
        guard await db.tableExists("ZPERSON") else { return out }
        let c = await db.existing("ZPERSON", personColumns)
        let face = await facePersonColumn(db)
        let sql = """
            SELECT count(*), sum(named AND live AND human), sum(named AND live AND NOT human), sum(live AND hasFace), sum(live AND hasFace AND NOT human),
                   sum(NOT live), sum(live AND NOT hasFace), sum(live AND verified), sum(live AND contact)
            FROM (SELECT \(namedClause(c)) named, NOT \(mergedClause(c)) live, \(humanClause(c)) human, \(hasFaceExpr(face, c)) hasFace,
                         \(c.contains("ZVERIFIEDTYPE") ? "coalesce(ZVERIFIEDTYPE, 0) = 1" : "0") verified,
                         \(c.contains("ZPERSONURI") ? "coalesce(length(ZPERSONURI), 0) > 0" : "0") contact
                  FROM ZPERSON)
            """
        if let r = try? await db.first(sql) {
            func n(_ i: Int) -> Int { Int(r[i].int ?? 0) }
            out = PersonCounts(rows: n(0), namedPeople: n(1), namedPets: n(2), clusters: n(3), petClusters: n(4), merged: n(5), withoutFaces: n(6), verified: n(7), withContact: n(8))
        }
        return out
    }

    private static func personWhere(_ filter: PersonFilter, search: String, cols: Set<String>, merged: Bool?) -> (String, [SQLValue]) {
        var clauses: [String] = []
        var params: [SQLValue] = []
        switch filter {
        case .named: clauses.append(namedClause(cols))
        case .pets: clauses.append(cols.contains("ZDETECTIONTYPE") ? "NOT \(humanClause(cols))" : "0")
        case .all: break
        }
        // nil = every row, false = only persons that were not merged away, true = only the merged ones.
        if let merged { clauses.append(merged ? mergedClause(cols) : "NOT \(mergedClause(cols))") }
        if !search.isEmpty {
            clauses.append("(\(sqlColumn(cols, "ZFULLNAME", fallback: "''")) LIKE ? OR \(sqlColumn(cols, "ZDISPLAYNAME", fallback: "''")) LIKE ?)")
            params += [.text("%\(search)%"), .text("%\(search)%")]
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), params)
    }

    private static let personColumns = ["ZFULLNAME", "ZDISPLAYNAME", "ZFACECOUNT", "ZTYPE", "ZVERIFIEDTYPE", "ZDETECTIONTYPE", "ZAGETYPE", "ZGENDERTYPE", "ZPERSONURI", "ZISMECONFIDENCE", "ZPERSONUUID", "ZMERGETARGETPERSON", "ZSHAREPARTICIPANT"]

    private static func personSelect(_ c: Set<String>, face: String?) -> String {
        """
        SELECT Z_PK, \(sqlColumn(c, "ZFULLNAME", fallback: "''")), \(sqlColumn(c, "ZDISPLAYNAME", fallback: "''")), \(sqlColumn(c, "ZFACECOUNT", fallback: "0")),
               \(sqlColumn(c, "ZTYPE")), \(sqlColumn(c, "ZVERIFIEDTYPE")), \(sqlColumn(c, "ZDETECTIONTYPE")), \(sqlColumn(c, "ZAGETYPE")), \(sqlColumn(c, "ZGENDERTYPE")),
               \(c.contains("ZPERSONURI") ? "length(ZPERSONURI) > 0" : "0"), \(sqlColumn(c, "ZISMECONFIDENCE")), \(sqlColumn(c, "ZPERSONUUID", fallback: "''")),
               \(mergedClause(c)), \(c.contains("ZSHAREPARTICIPANT") ? "ZSHAREPARTICIPANT IS NOT NULL" : "0"),
               \(facesExpr(face, c)) faces
        FROM ZPERSON
        """
    }

    private static func personRow(_ row: SQLRow) -> PersonRow {
        PersonRow(id: row[0].int ?? 0, name: row[1].string ?? "", displayName: row[2].string ?? "", faces: Int(row[14].int ?? 0), faceCount: Int(row[3].int ?? 0),
                  type: row[4].int.map(Int.init), verified: row[5].int.map(Int.init), detection: row[6].int.map(Int.init),
                  age: row[7].int.map(Int.init), gender: row[8].int.map(Int.init), hasContact: row[9].bool ?? false,
                  meConfidence: row[10].double, uuid: row[11].string ?? "", merged: row[12].bool ?? false, shareParticipant: row[13].bool ?? false)
    }

    /// Persons, by default without the rows that were merged into another person.
    static func persons(_ lib: PhotosLibrary, filter: PersonFilter, includeMerged: Bool = false, request: PageRequest) async throws -> [PersonRow] {
        let db = try await lib.photos()
        guard await db.tableExists("ZPERSON") else { throw DossierError.missing("Photos.sqlite has no ZPERSON table.") }
        let c = await db.existing("ZPERSON", personColumns)
        let face = await facePersonColumn(db)
        let (whereSQL, params) = personWhere(filter, search: request.search, cols: c, merged: includeMerged ? nil : false)
        var order = "faces DESC, Z_PK"
        if let sort = request.sort {
            if sort.columnID == "faces" {
                order = "faces \(sort.sqlDirection), Z_PK"
            } else if personSortable.contains(sort.columnID), sort.columnID == "Z_PK" || c.contains(sort.columnID) {
                order = "\(sort.columnID) \(sort.sqlDirection), Z_PK"
            }
        }
        let rows = try await db.rows("\(personSelect(c, face: face)) \(whereSQL) ORDER BY \(order) LIMIT ? OFFSET ?", params + [.integer(Int64(request.limit)), .integer(Int64(request.offset))])
        return rows.map(personRow)
    }

    static func personCount(_ lib: PhotosLibrary, filter: PersonFilter, includeMerged: Bool = false, search: String) async throws -> Int? {
        let db = try await lib.photos()
        let c = await db.existing("ZPERSON", personColumns)
        let (whereSQL, params) = personWhere(filter, search: search, cols: c, merged: includeMerged ? nil : false)
        return await db.count("SELECT count(*) FROM ZPERSON \(whereSQL)", params)
    }

    /// How many rows of this filter are merged-away duplicates (hidden unless asked for).
    static func mergedPersonCount(_ lib: PhotosLibrary, filter: PersonFilter) async -> Int {
        guard let db = try? await lib.photos(), await db.tableExists("ZPERSON") else { return 0 }
        let c = await db.existing("ZPERSON", personColumns)
        let (whereSQL, params) = personWhere(filter, search: "", cols: c, merged: true)
        return await db.count("SELECT count(*) FROM ZPERSON \(whereSQL)", params) ?? 0
    }

    static func person(_ lib: PhotosLibrary, pk: Int64) async throws -> PersonRow? {
        let db = try await lib.photos()
        let c = await db.existing("ZPERSON", personColumns)
        let face = await facePersonColumn(db)
        return try await db.first("\(personSelect(c, face: face)) WHERE Z_PK = ?", [.integer(pk)]).map(personRow)
    }

    /// Display names of persons by ZPERSONUUID (memory recipes refer to people that way).
    static func personNames(_ lib: PhotosLibrary, uuids: [String]) async -> [String: String] {
        let wanted = Array(Set(uuids)).prefix(40)
        guard !wanted.isEmpty, let db = try? await lib.photos(), await db.hasColumns("ZPERSON", ["ZPERSONUUID"]) else { return [:] }
        let c = await db.existing("ZPERSON", personColumns)
        let name = "coalesce(nullif(\(sqlColumn(c, "ZFULLNAME", fallback: "''")), ''), \(sqlColumn(c, "ZDISPLAYNAME", fallback: "''")), '')"
        let marks = Array(repeating: "?", count: wanted.count).joined(separator: ",")
        var out: [String: String] = [:]
        for row in (try? await db.rows("SELECT ZPERSONUUID, \(name) FROM ZPERSON WHERE ZPERSONUUID IN (\(marks))", wanted.map { .text($0) })) ?? [] {
            if let uuid = row[0].string, let n = row[1].string, !n.isEmpty { out[uuid] = n }
        }
        return out
    }

    struct AttributeDistribution: Sendable, Identifiable {
        var id: String { attribute.column }
        let attribute: FaceAttribute
        let counts: [(code: Int, count: Int)]
        var analysed: Int { counts.filter { $0.code != 0 }.reduce(0) { $0 + $1.count } }
        var distinctAnalysed: Int { counts.filter { $0.code != 0 }.count }
    }

    struct FaceProfile: Sendable {
        var faces = 0
        var assets = 0
        var range: ClosedRange<Date>?
        var years: [YearCount] = []
        var distributions: [AttributeDistribution] = []
        var quality: Double?
        var detectionTypes: [(code: Int, count: Int)] = []
        var nameSources: [(code: Int, count: Int)] = []
        var mergeCandidates = 0
    }

    /// Aggregate of the coded face attributes, for one person (`pk`) or for every face in the library.
    static func faceProfile(_ lib: PhotosLibrary, person pk: Int64?) async throws -> FaceProfile {
        let db = try await lib.photos()
        guard await db.tableExists("ZDETECTEDFACE") else { throw DossierError.missing("Photos.sqlite has no ZDETECTEDFACE table.") }
        let all = await db.columnNames(of: "ZDETECTEDFACE")
        let upper = Set(all.map { $0.uppercased() })
        let personColumn = upper.contains("ZPERSONFORFACE") ? "ZPERSONFORFACE" : (upper.contains("ZPERSON") ? "ZPERSON" : nil)
        let assetColumn = upper.contains("ZASSETFORFACE") ? "ZASSETFORFACE" : (upper.contains("ZASSET") ? "ZASSET" : nil)
        var filter = ""
        var params: [SQLValue] = []
        if let pk {
            guard let personColumn else { throw DossierError.missing("ZDETECTEDFACE has no person column on this macOS version.") }
            filter = "WHERE \(personColumn) = ?"
            params = [.integer(pk)]
        }
        var profile = FaceProfile()
        let attributes = PhotosCodes.faceAttributes.filter { upper.contains($0.column) }
        if !attributes.isEmpty {
            // One pass per attribute, glued into a single statement.
            let sql = attributes.enumerated().map { i, attr in
                "SELECT \(i) a, \(attr.column) c, count(*) n FROM ZDETECTEDFACE \(filter) GROUP BY c"
            }.joined(separator: " UNION ALL ")
            var grouped: [Int: [(Int, Int)]] = [:]
            for row in try await db.rows(sql, Array(repeating: params, count: attributes.count).flatMap { $0 }) {
                grouped[Int(row[0].int ?? 0), default: []].append((Int(row[1].int ?? 0), Int(row[2].int ?? 0)))
            }
            profile.distributions = attributes.enumerated().map { i, attr in
                AttributeDistribution(attribute: attr, counts: (grouped[i] ?? []).sorted { $0.0 < $1.0 }.map { (code: $0.0, count: $0.1) })
            }
        }
        if let assetColumn {
            let quality = upper.contains("ZQUALITY") ? "avg(CASE WHEN f.ZQUALITY > 0 THEN f.ZQUALITY END)" : "NULL"
            let f = filter.replacingOccurrences(of: "WHERE ", with: "WHERE f.")
            if let r = try await db.first("""
                SELECT count(*), count(DISTINCT f.\(assetColumn)), min(a.ZDATECREATED), max(a.ZDATECREATED), \(quality)
                FROM ZDETECTEDFACE f LEFT JOIN ZASSET a ON a.Z_PK = f.\(assetColumn) \(f)
                """, params) {
                profile.faces = Int(r[0].int ?? 0); profile.assets = Int(r[1].int ?? 0)
                if let lo = r[2].cocoaDate, let hi = r[3].cocoaDate, lo <= hi { profile.range = lo...hi }
                profile.quality = r[4].double
            }
            profile.years = try await db.rows("""
                SELECT CAST(strftime('%Y', a.ZDATECREATED + 978307200, 'unixepoch', 'localtime') AS INTEGER) y, count(DISTINCT a.Z_PK), 0
                FROM ZDETECTEDFACE f JOIN ZASSET a ON a.Z_PK = f.\(assetColumn) \(f) GROUP BY y ORDER BY y
                """, params).compactMap { row in
                guard let y = row[0].int else { return nil }
                return YearCount(year: Int(y), photos: Int(row[1].int ?? 0), videos: 0)
            }
        }
        if upper.contains("ZDETECTIONTYPE") {
            profile.detectionTypes = try await db.rows("SELECT ZDETECTIONTYPE, count(*) FROM ZDETECTEDFACE \(filter) GROUP BY 1 ORDER BY 2 DESC", params).map { (Int($0[0].int ?? 0), Int($0[1].int ?? 0)) }
        }
        if upper.contains("ZNAMESOURCE") {
            profile.nameSources = try await db.rows("SELECT ZNAMESOURCE, count(*) FROM ZDETECTEDFACE \(filter) GROUP BY 1 ORDER BY 2 DESC", params).map { (Int($0[0].int ?? 0), Int($0[1].int ?? 0)) }
        }
        return profile
    }

    struct PeopleStats: Sendable {
        var people = PersonCounts()
        var faces = 0
        var facesAssigned = 0
        var facesAnalysed = 0
    }

    static func peopleStats(_ lib: PhotosLibrary) async throws -> PeopleStats {
        let db = try await lib.photos()
        guard await db.tableExists("ZPERSON") else { throw DossierError.missing("Photos.sqlite has no ZPERSON table.") }
        var s = PeopleStats()
        s.people = await personCounts(db)
        let f = await db.existing("ZDETECTEDFACE", ["ZPERSONFORFACE", "ZAGETYPE"])
        if let r = try? await db.first("SELECT count(*), \(f.contains("ZPERSONFORFACE") ? "count(ZPERSONFORFACE)" : "0"), \(f.contains("ZAGETYPE") ? "sum(ZAGETYPE != 0)" : "0") FROM ZDETECTEDFACE") {
            s.faces = Int(r[0].int ?? 0); s.facesAssigned = Int(r[1].int ?? 0); s.facesAnalysed = Int(r[2].int ?? 0)
        }
        return s
    }

    // MARK: Places

    struct GridCell: Sendable {
        let latitude: Double
        let longitude: Double
        let count: Int
    }

    /// Asset coordinates aggregated in SQL into grid cells of 1/`cellsPerDegree` degrees.
    static func locationGrid(_ lib: PhotosLibrary, cellsPerDegree: Int = 50) async throws -> [GridCell] {
        let db = try await lib.photos()
        guard await db.hasColumns("ZASSET", ["ZLATITUDE", "ZLONGITUDE"]) else { throw DossierError.missing("ZASSET has no coordinate columns.") }
        let k = Double(cellsPerDegree)
        let trashed = await db.hasColumns("ZASSET", ["ZTRASHEDSTATE"]) ? "AND ZTRASHEDSTATE = 0" : ""
        return try await db.rows("""
            SELECT round(ZLATITUDE * \(k)) / \(k), round(ZLONGITUDE * \(k)) / \(k), count(*)
            FROM ZASSET
            WHERE ZLATITUDE BETWEEN -90 AND 90 AND ZLONGITUDE BETWEEN -180 AND 180 AND NOT (ZLATITUDE = 0 AND ZLONGITUDE = 0) \(trashed)
            GROUP BY 1, 2
            """, maxRows: 250_000).compactMap { row in
            guard let lat = row[0].double, let lon = row[1].double else { return nil }
            return GridCell(latitude: lat, longitude: lon, count: Int(row[2].int ?? 0))
        }
    }

    struct Trip: Sendable, Identifiable, Hashable {
        let id: Int64
        let title: String
        let subtitle: String
        let type: String
        let typeCode: Int
        let start: Date
        let end: Date
        let assets: Int
        let days: Int
        var duration: Double { max(1, end.timeIntervalSince(start) / 86_400) }
    }

    /// Day-group highlights (ZKIND = 3): what Photos presents as trips.
    static func trips(_ lib: PhotosLibrary) async throws -> [Trip] {
        let db = try await lib.photos()
        guard await db.hasColumns("ZPHOTOSHIGHLIGHT", ["ZKIND", "ZTYPE", "ZSTARTDATE", "ZENDDATE"]) else { return [] }
        let c = await db.existing("ZPHOTOSHIGHLIGHT", ["ZTITLE", "ZSUBTITLE", "ZPARENTDAYGROUPPHOTOSHIGHLIGHT", "ZASSETSCOUNT"])
        let children = c.contains("ZPARENTDAYGROUPPHOTOSHIGHLIGHT") && c.contains("ZASSETSCOUNT")
        return try await db.rows("""
            SELECT h.Z_PK, \(sqlColumn(c, "ZTITLE", prefix: "h.", fallback: "''")), \(sqlColumn(c, "ZSUBTITLE", prefix: "h.", fallback: "''")), h.ZTYPE, h.ZSTARTDATE, h.ZENDDATE,
                   \(children ? "(SELECT sum(d.ZASSETSCOUNT) FROM ZPHOTOSHIGHLIGHT d WHERE d.ZPARENTDAYGROUPPHOTOSHIGHLIGHT = h.Z_PK)" : "0"),
                   \(children ? "(SELECT count(*) FROM ZPHOTOSHIGHLIGHT d WHERE d.ZPARENTDAYGROUPPHOTOSHIGHLIGHT = h.Z_PK)" : "0")
            FROM ZPHOTOSHIGHLIGHT h WHERE h.ZKIND = 3 ORDER BY h.ZSTARTDATE DESC LIMIT 2000
            """).compactMap { row in
            guard let pk = row[0].int, let start = row[4].cocoaDate, let end = row[5].cocoaDate else { return nil }
            let type = Int(row[3].int ?? 0)
            return Trip(id: pk, title: clean(row[1].string ?? ""), subtitle: clean(row[2].string ?? ""), type: PhotosCodes.highlightType(kind: 3, type: type), typeCode: type,
                        start: start, end: end, assets: Int(row[6].int ?? 0), days: Int(row[7].int ?? 0))
        }
    }

    // MARK: Memories, highlights, suggestions

    struct MemoryRow: Sendable, Identifiable, Hashable {
        let id: Int64
        let title: String
        let subtitle: String
        let kind: String
        let category: Int?
        let subcategory: Int?
        let created: Date?
        let start: Date?
        let end: Date?
        let score: Double?
        let views: Int
        let plays: Int
        let shares: Int
        let favorite: Bool
        let rejected: Bool
        let featured: Int?
        let pending: Int?
        let userCreated: Bool
        let lastViewed: Date?
        let graphIdentifier: String
    }

    private static let memoryColumns = ["ZTITLE", "ZSUBTITLE", "ZCATEGORY", "ZSUBCATEGORY", "ZCREATIONDATE", "ZSTARTDATE", "ZENDDATE", "ZSCORE", "ZVIEWCOUNT", "ZPLAYCOUNT", "ZSHARECOUNT", "ZFAVORITE", "ZREJECTED", "ZFEATUREDSTATE", "ZPENDINGSTATE", "ZCREATIONTYPE", "ZLASTVIEWEDDATE", "ZGRAPHMEMORYIDENTIFIER"]
    private static let memorySortable: Set<String> = ["ZTITLE", "ZCATEGORY", "ZCREATIONDATE", "ZSTARTDATE", "ZSCORE", "ZVIEWCOUNT", "ZPLAYCOUNT", "ZSHARECOUNT", "ZFAVORITE", "ZREJECTED", "ZGRAPHMEMORYIDENTIFIER", "ZPENDINGSTATE"]

    /// The memory type is the first component of ZGRAPHMEMORYIDENTIFIER ("Trip|PGGraph…"), the
    /// same string the PhotosGraph uses as the label of its memory nodes.
    static func memoryKind(_ identifier: String, userCreated: Bool) -> String {
        if let first = identifier.split(separator: "|").first, !first.isEmpty { return GraphInferences.spaced(String(first)) }
        return userCreated ? "User created" : "Unclassified"
    }

    static func memories(_ lib: PhotosLibrary, request: PageRequest) async throws -> [MemoryRow] {
        let db = try await lib.photos()
        guard await db.tableExists("ZMEMORY") else { throw DossierError.missing("Photos.sqlite has no ZMEMORY table.") }
        let c = await db.existing("ZMEMORY", memoryColumns)
        var order = "\(sqlColumn(c, "ZCREATIONDATE", fallback: "Z_PK")) DESC"
        if let sort = request.sort, memorySortable.contains(sort.columnID), c.contains(sort.columnID) { order = "\(sort.columnID) \(sort.sqlDirection), Z_PK" }
        var whereSQL = ""
        var params: [SQLValue] = []
        if !request.search.isEmpty {
            whereSQL = "WHERE (\(sqlColumn(c, "ZTITLE", fallback: "''")) LIKE ? OR \(sqlColumn(c, "ZSUBTITLE", fallback: "''")) LIKE ? OR \(sqlColumn(c, "ZGRAPHMEMORYIDENTIFIER", fallback: "''")) LIKE ?)"
            params = Array(repeating: .text("%\(request.search)%"), count: 3)
        }
        let sql = """
            SELECT Z_PK, \(sqlColumn(c, "ZTITLE", fallback: "''")), \(sqlColumn(c, "ZSUBTITLE", fallback: "''")), \(sqlColumn(c, "ZCATEGORY")), \(sqlColumn(c, "ZSUBCATEGORY")),
                   \(sqlColumn(c, "ZCREATIONDATE")), \(sqlColumn(c, "ZSTARTDATE")), \(sqlColumn(c, "ZENDDATE")), \(sqlColumn(c, "ZSCORE")),
                   \(sqlColumn(c, "ZVIEWCOUNT", fallback: "0")), \(sqlColumn(c, "ZPLAYCOUNT", fallback: "0")), \(sqlColumn(c, "ZSHARECOUNT", fallback: "0")),
                   \(sqlColumn(c, "ZFAVORITE", fallback: "0")), \(sqlColumn(c, "ZREJECTED", fallback: "0")), \(sqlColumn(c, "ZFEATUREDSTATE")), \(sqlColumn(c, "ZPENDINGSTATE")),
                   \(sqlColumn(c, "ZCREATIONTYPE", fallback: "0")), \(sqlColumn(c, "ZLASTVIEWEDDATE")), \(sqlColumn(c, "ZGRAPHMEMORYIDENTIFIER", fallback: "''"))
            FROM ZMEMORY \(whereSQL) ORDER BY \(order) LIMIT ? OFFSET ?
            """
        return try await db.rows(sql, params + [.integer(Int64(request.limit)), .integer(Int64(request.offset))]).map { row in
            let ident = row[18].string ?? ""
            let userCreated = (row[16].int ?? 0) != 0
            return MemoryRow(id: row[0].int ?? 0, title: clean(row[1].string ?? ""), subtitle: clean(row[2].string ?? ""), kind: memoryKind(ident, userCreated: userCreated),
                             category: row[3].int.map(Int.init), subcategory: row[4].int.map(Int.init), created: row[5].cocoaDate, start: row[6].cocoaDate, end: row[7].cocoaDate,
                             score: row[8].double, views: Int(row[9].int ?? 0), plays: Int(row[10].int ?? 0), shares: Int(row[11].int ?? 0),
                             favorite: (row[12].int ?? 0) != 0, rejected: (row[13].int ?? 0) != 0, featured: row[14].int.map(Int.init), pending: row[15].int.map(Int.init),
                             userCreated: userCreated, lastViewed: row[17].cocoaDate, graphIdentifier: ident)
        }
    }

    static func memoryCount(_ lib: PhotosLibrary, search: String) async throws -> Int? {
        let db = try await lib.photos()
        if search.isEmpty { return await db.rowCount(of: "ZMEMORY") }
        let c = await db.existing("ZMEMORY", memoryColumns)
        return await db.count("SELECT count(*) FROM ZMEMORY WHERE (\(sqlColumn(c, "ZTITLE", fallback: "''")) LIKE ? OR \(sqlColumn(c, "ZSUBTITLE", fallback: "''")) LIKE ? OR \(sqlColumn(c, "ZGRAPHMEMORYIDENTIFIER", fallback: "''")) LIKE ?)", Array(repeating: .text("%\(search)%"), count: 3))
    }

    struct MemoryStats: Sendable {
        var total = 0
        var viewed = 0
        var played = 0
        var shared = 0
        var favorites = 0
        var rejected = 0
        var pending = 0
        var userCreated = 0
        var range: ClosedRange<Date>?
        var kinds: [NamedCount] = []
        var perYear: [YearCount] = []
    }

    static func memoryStats(_ lib: PhotosLibrary) async throws -> MemoryStats {
        let db = try await lib.photos()
        guard await db.tableExists("ZMEMORY") else { throw DossierError.missing("Photos.sqlite has no ZMEMORY table.") }
        let c = await db.existing("ZMEMORY", memoryColumns)
        var s = MemoryStats()
        func sum(_ col: String, _ expr: String) -> String { c.contains(col) ? "sum(\(expr))" : "0" }
        if let r = try await db.first("""
            SELECT count(*), \(sum("ZVIEWCOUNT", "ZVIEWCOUNT > 0")), \(sum("ZPLAYCOUNT", "ZPLAYCOUNT > 0")), \(sum("ZSHARECOUNT", "ZSHARECOUNT > 0")),
                   \(sum("ZFAVORITE", "ZFAVORITE != 0")), \(sum("ZREJECTED", "ZREJECTED != 0")), \(sum("ZPENDINGSTATE", "ZPENDINGSTATE != 0")), \(sum("ZCREATIONTYPE", "ZCREATIONTYPE != 0")),
                   \(c.contains("ZCREATIONDATE") ? "min(ZCREATIONDATE), max(ZCREATIONDATE)" : "NULL, NULL")
            FROM ZMEMORY
            """) {
            s.total = Int(r[0].int ?? 0); s.viewed = Int(r[1].int ?? 0); s.played = Int(r[2].int ?? 0); s.shared = Int(r[3].int ?? 0)
            s.favorites = Int(r[4].int ?? 0); s.rejected = Int(r[5].int ?? 0); s.pending = Int(r[6].int ?? 0); s.userCreated = Int(r[7].int ?? 0)
            if let lo = r[8].cocoaDate, let hi = r[9].cocoaDate, lo <= hi { s.range = lo...hi }
        }
        if c.contains("ZGRAPHMEMORYIDENTIFIER") {
            let userCreated = c.contains("ZCREATIONTYPE") ? "ZCREATIONTYPE != 0" : "0"
            s.kinds = try await db.rows("""
                SELECT CASE WHEN instr(ZGRAPHMEMORYIDENTIFIER, '|') > 1 THEN substr(ZGRAPHMEMORYIDENTIFIER, 1, instr(ZGRAPHMEMORYIDENTIFIER, '|') - 1) ELSE '' END k,
                       max(\(userCreated)), count(*)
                FROM ZMEMORY GROUP BY k ORDER BY 3 DESC
                """).map { row in
                NamedCount(name: memoryKind((row[0].string ?? "") + "|", userCreated: (row[1].int ?? 0) != 0), count: Int(row[2].int ?? 0))
            }
        }
        if c.contains("ZCREATIONDATE") {
            s.perYear = try await db.rows("SELECT CAST(strftime('%Y', ZCREATIONDATE + 978307200, 'unixepoch', 'localtime') AS INTEGER) y, count(*), 0 FROM ZMEMORY WHERE ZCREATIONDATE IS NOT NULL GROUP BY y ORDER BY y").compactMap { row in
                row[0].int.map { YearCount(year: Int($0), photos: Int(row[1].int ?? 0), videos: 0) }
            }
        }
        return s
    }

    struct HighlightRow: Sendable, Identifiable, Hashable {
        let id: Int64
        let title: String
        let subtitle: String
        let kind: Int
        let type: Int
        let category: Int?
        let start: Date?
        let end: Date?
        let assets: Int
        let promotion: Double?
        let mood: Int?
        let enrichment: Int?
        let visibility: Int?
        let description: String
    }

    private static let highlightSortable: Set<String> = ["ZTITLE", "ZKIND", "ZTYPE", "ZSTARTDATE", "ZENDDATE", "ZASSETSCOUNT", "ZPROMOTIONSCORE"]
    private static let highlightColumns = ["ZTITLE", "ZSUBTITLE", "ZKIND", "ZTYPE", "ZCATEGORY", "ZSTARTDATE", "ZENDDATE", "ZASSETSCOUNT", "ZPROMOTIONSCORE", "ZMOOD", "ZENRICHMENTSTATE", "ZVISIBILITYSTATE", "ZVERBOSESMARTDESCRIPTION"]

    static func highlights(_ lib: PhotosLibrary, kind: Int?, request: PageRequest) async throws -> [HighlightRow] {
        let db = try await lib.photos()
        guard await db.tableExists("ZPHOTOSHIGHLIGHT") else { throw DossierError.missing("Photos.sqlite has no ZPHOTOSHIGHLIGHT table.") }
        let c = await db.existing("ZPHOTOSHIGHLIGHT", highlightColumns)
        var clauses: [String] = []
        var params: [SQLValue] = []
        if let kind, c.contains("ZKIND") { clauses.append("ZKIND = ?"); params.append(.integer(Int64(kind))) }
        if !request.search.isEmpty {
            clauses.append("(\(sqlColumn(c, "ZTITLE", fallback: "''")) LIKE ? OR \(sqlColumn(c, "ZSUBTITLE", fallback: "''")) LIKE ?)")
            params += [.text("%\(request.search)%"), .text("%\(request.search)%")]
        }
        var order = "\(sqlColumn(c, "ZSTARTDATE", fallback: "Z_PK")) DESC"
        if let sort = request.sort, highlightSortable.contains(sort.columnID), c.contains(sort.columnID) { order = "\(sort.columnID) \(sort.sqlDirection), Z_PK" }
        let sql = """
            SELECT Z_PK, \(sqlColumn(c, "ZTITLE", fallback: "''")), \(sqlColumn(c, "ZSUBTITLE", fallback: "''")), \(sqlColumn(c, "ZKIND", fallback: "0")), \(sqlColumn(c, "ZTYPE", fallback: "0")),
                   \(sqlColumn(c, "ZCATEGORY")), \(sqlColumn(c, "ZSTARTDATE")), \(sqlColumn(c, "ZENDDATE")), \(sqlColumn(c, "ZASSETSCOUNT", fallback: "0")), \(sqlColumn(c, "ZPROMOTIONSCORE")),
                   \(sqlColumn(c, "ZMOOD")), \(sqlColumn(c, "ZENRICHMENTSTATE")), \(sqlColumn(c, "ZVISIBILITYSTATE")), \(sqlColumn(c, "ZVERBOSESMARTDESCRIPTION", fallback: "''"))
            FROM ZPHOTOSHIGHLIGHT \(clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")) ORDER BY \(order) LIMIT ? OFFSET ?
            """
        return try await db.rows(sql, params + [.integer(Int64(request.limit)), .integer(Int64(request.offset))]).map { row in
            HighlightRow(id: row[0].int ?? 0, title: clean(row[1].string ?? ""), subtitle: clean(row[2].string ?? ""), kind: Int(row[3].int ?? 0), type: Int(row[4].int ?? 0),
                         category: row[5].int.map(Int.init), start: row[6].cocoaDate, end: row[7].cocoaDate, assets: Int(row[8].int ?? 0), promotion: row[9].double,
                         mood: row[10].int.map(Int.init), enrichment: row[11].int.map(Int.init), visibility: row[12].int.map(Int.init), description: row[13].string ?? "")
        }
    }

    static func highlightCount(_ lib: PhotosLibrary, kind: Int?, search: String) async throws -> Int? {
        let db = try await lib.photos()
        var clauses: [String] = []
        var params: [SQLValue] = []
        if let kind { clauses.append("ZKIND = ?"); params.append(.integer(Int64(kind))) }
        if !search.isEmpty { clauses.append("(ZTITLE LIKE ? OR ZSUBTITLE LIKE ?)"); params += [.text("%\(search)%"), .text("%\(search)%")] }
        return await db.count("SELECT count(*) FROM ZPHOTOSHIGHLIGHT \(clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "))", params)
    }

    static func highlightKinds(_ lib: PhotosLibrary) async throws -> [NamedCount] {
        let db = try await lib.photos()
        guard await db.hasColumns("ZPHOTOSHIGHLIGHT", ["ZKIND", "ZTYPE"]) else { return [] }
        return try await db.rows("SELECT ZKIND, ZTYPE, count(*) FROM ZPHOTOSHIGHLIGHT GROUP BY 1, 2 ORDER BY 1, 2").map { row in
            let kind = Int(row[0].int ?? 0), type = Int(row[1].int ?? 0)
            return NamedCount(name: "\(PhotosCodes.highlightKind.shortLabel(kind)) · \(PhotosCodes.highlightType(kind: kind, type: type)) (kind \(kind), type \(type))", count: Int(row[2].int ?? 0))
        }
    }

    struct SuggestionRow: Sendable, Identifiable, Hashable {
        let id: Int64
        let title: String
        let subtitle: String
        let type: Int?
        let subtype: Int?
        let state: Int?
        let featured: Int?
        let created: Date?
        let start: Date?
        let end: Date?
        let assets: Int
    }

    static func suggestions(_ lib: PhotosLibrary) async throws -> [SuggestionRow] {
        let db = try await lib.photos()
        guard await db.tableExists("ZSUGGESTION") else { return [] }
        let c = await db.existing("ZSUGGESTION", ["ZTITLE", "ZSUBTITLE", "ZTYPE", "ZSUBTYPE", "ZSTATE", "ZFEATUREDSTATE", "ZCREATIONDATE", "ZSTARTDATE", "ZENDDATE", "ZCACHEDCOUNT"])
        return try await db.rows("""
            SELECT Z_PK, \(sqlColumn(c, "ZTITLE", fallback: "''")), \(sqlColumn(c, "ZSUBTITLE", fallback: "''")), \(sqlColumn(c, "ZTYPE")), \(sqlColumn(c, "ZSUBTYPE")), \(sqlColumn(c, "ZSTATE")),
                   \(sqlColumn(c, "ZFEATUREDSTATE")), \(sqlColumn(c, "ZCREATIONDATE")), \(sqlColumn(c, "ZSTARTDATE")), \(sqlColumn(c, "ZENDDATE")), \(sqlColumn(c, "ZCACHEDCOUNT", fallback: "0"))
            FROM ZSUGGESTION ORDER BY \(sqlColumn(c, "ZCREATIONDATE", fallback: "Z_PK")) DESC LIMIT 5000
            """).map { row in
            SuggestionRow(id: row[0].int ?? 0, title: clean(row[1].string ?? ""), subtitle: clean(row[2].string ?? ""), type: row[3].int.map(Int.init), subtype: row[4].int.map(Int.init),
                          state: row[5].int.map(Int.init), featured: row[6].int.map(Int.init), created: row[7].cocoaDate, start: row[8].cocoaDate, end: row[9].cocoaDate, assets: Int(row[10].int ?? 0))
        }
    }

    // MARK: Sharing & engagement

    struct Participant: Sendable, Identifiable, Hashable {
        let id: Int64
        let name: String
        let isCurrentUser: Bool
        let role: Int?
        let contributed: Int
        let share: Int64?
        let linkedPerson: Bool
    }

    struct ShareRow: Sendable, Identifiable, Hashable {
        let id: Int64
        let title: String
        let kind: String
        let scopeType: Int?
        let status: Int?
        let assets: Int
        let created: Date?
        let participants: Int
    }

    struct SharingStats: Sendable {
        var totalViews = 0
        var totalPlays = 0
        var totalShares = 0
        var viewedAssets = 0
        var sharedAssets = 0
        var maxViews = 0
        var favorites = 0
        var lastViewed: Date?
        var sharedLibraryAssets = 0
        var comments = 0
        var likes = 0
        var myComments = 0
        var syndicated = 0
        var participants: [Participant] = []
        var shares: [ShareRow] = []
        var albums: [NamedCount] = []
        var viewHistogram: [NamedCount] = []
    }

    /// Best-effort display name of a share participant: archived name components, else e-mail / phone.
    private static func participantName(components: Data?, email: String?, phone: String?, isMe: Bool, pk: Int64) -> String {
        if let components, let value = PlistDecoder.decodeAny(components) {
            let inner = value["NS.nameComponentsPrivate"] ?? value
            let given = inner["NS.givenName"]?.string ?? inner["givenName"]?.string
            let family = inner["NS.familyName"]?.string ?? inner["familyName"]?.string
            let joined = [given, family].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            if !joined.isEmpty { return joined }
        }
        if let email, !email.isEmpty { return email }
        if let phone, !phone.isEmpty { return phone }
        return isMe ? "Me" : "Participant \(pk)"
    }

    static func sharing(_ lib: PhotosLibrary) async throws -> SharingStats {
        let db = try await lib.photos()
        var s = SharingStats()
        let add = await db.existing("ZADDITIONALASSETATTRIBUTES", ["ZVIEWCOUNT", "ZPLAYCOUNT", "ZSHARECOUNT", "ZLASTVIEWEDDATE"])
        if add.contains("ZVIEWCOUNT") {
            if let r = try await db.first("""
                SELECT sum(ZVIEWCOUNT), \(add.contains("ZPLAYCOUNT") ? "sum(ZPLAYCOUNT)" : "0"), \(add.contains("ZSHARECOUNT") ? "sum(ZSHARECOUNT)" : "0"),
                       sum(ZVIEWCOUNT > 0), \(add.contains("ZSHARECOUNT") ? "sum(ZSHARECOUNT > 0)" : "0"), max(ZVIEWCOUNT), \(add.contains("ZLASTVIEWEDDATE") ? "max(ZLASTVIEWEDDATE)" : "NULL")
                FROM ZADDITIONALASSETATTRIBUTES
                """) {
                s.totalViews = Int(r[0].int ?? 0); s.totalPlays = Int(r[1].int ?? 0); s.totalShares = Int(r[2].int ?? 0)
                s.viewedAssets = Int(r[3].int ?? 0); s.sharedAssets = Int(r[4].int ?? 0); s.maxViews = Int(r[5].int ?? 0); s.lastViewed = r[6].cocoaDate
            }
            s.viewHistogram = try await db.rows("""
                SELECT CASE WHEN ZVIEWCOUNT = 0 THEN 0 WHEN ZVIEWCOUNT = 1 THEN 1 WHEN ZVIEWCOUNT <= 3 THEN 2 WHEN ZVIEWCOUNT <= 10 THEN 3 WHEN ZVIEWCOUNT <= 30 THEN 4 ELSE 5 END b, count(*)
                FROM ZADDITIONALASSETATTRIBUTES GROUP BY b ORDER BY b
                """).map { row in
                let names = ["Never opened", "1 view", "2–3 views", "4–10 views", "11–30 views", "More than 30"]
                return NamedCount(name: names[min(5, Int(row[0].int ?? 0))], count: Int(row[1].int ?? 0))
            }
        }
        let a = await db.existing("ZASSET", ["ZFAVORITE", "ZLIBRARYSCOPESHARESTATE", "ZSYNDICATIONSTATE", "ZLIBRARYSCOPE"])
        if let r = try? await db.first("""
            SELECT \(a.contains("ZFAVORITE") ? "sum(ZFAVORITE != 0)" : "0"), \(a.contains("ZLIBRARYSCOPE") ? "count(ZLIBRARYSCOPE)" : (a.contains("ZLIBRARYSCOPESHARESTATE") ? "sum(ZLIBRARYSCOPESHARESTATE != 0)" : "0")),
                   \(a.contains("ZSYNDICATIONSTATE") ? "sum(ZSYNDICATIONSTATE != 0)" : "0")
            FROM ZASSET
            """) {
            s.favorites = Int(r[0].int ?? 0); s.sharedLibraryAssets = Int(r[1].int ?? 0); s.syndicated = Int(r[2].int ?? 0)
        }
        if await db.hasColumns("ZCLOUDSHAREDCOMMENT", ["ZISLIKE", "ZISMYCOMMENT"]) {
            if let r = try? await db.first("SELECT sum(ZISLIKE = 0), sum(ZISLIKE != 0), sum(ZISMYCOMMENT != 0) FROM ZCLOUDSHAREDCOMMENT") {
                s.comments = Int(r[0].int ?? 0); s.likes = Int(r[1].int ?? 0); s.myComments = Int(r[2].int ?? 0)
            }
        }
        // Participants and their contributions (shared library + shared albums).
        if await db.tableExists("ZSHAREPARTICIPANT") {
            let p = await db.existing("ZSHAREPARTICIPANT", ["ZISCURRENTUSER", "ZPARTICIPANTROLE", "ZCONTRIBUTEDASSETSCOUNT", "ZSHARE", "ZPERSON", "ZEMAILADDRESS", "ZPHONENUMBER", "ZNAMECOMPONENTS"])
            let rows = try await db.rows("""
                SELECT Z_PK, \(sqlColumn(p, "ZISCURRENTUSER", fallback: "0")), \(sqlColumn(p, "ZPARTICIPANTROLE")), \(sqlColumn(p, "ZCONTRIBUTEDASSETSCOUNT", fallback: "0")), \(sqlColumn(p, "ZSHARE")),
                       \(p.contains("ZPERSON") ? "ZPERSON IS NOT NULL" : "0"), \(sqlColumn(p, "ZEMAILADDRESS")), \(sqlColumn(p, "ZPHONENUMBER")), \(sqlColumn(p, "ZNAMECOMPONENTS"))
                FROM ZSHAREPARTICIPANT ORDER BY \(sqlColumn(p, "ZCONTRIBUTEDASSETSCOUNT", fallback: "Z_PK")) DESC LIMIT 2000
                """)
            s.participants = rows.map { row in
                let me = (row[1].int ?? 0) != 0
                let pk = row[0].int ?? 0
                return Participant(id: pk, name: participantName(components: row[8].data, email: row[6].string, phone: row[7].string, isMe: me, pk: pk),
                                   isCurrentUser: me, role: row[2].int.map(Int.init), contributed: Int(row[3].int ?? 0), share: row[4].int, linkedPerson: (row[5].int ?? 0) != 0)
            }
        }
        if await db.tableExists("ZSHARE") {
            let c = await db.existing("ZSHARE", ["ZTITLE", "ZSCOPETYPE", "ZSTATUS", "ZASSETCOUNT", "ZCREATIONDATE", "ZSCOPEIDENTIFIER", "ZCOLLECTIONSHAREKIND"])
            let entity = await entityNames(db)
            var perShare: [Int64: Int] = [:]
            for p in s.participants { if let sh = p.share { perShare[sh, default: 0] += 1 } }
            s.shares = try await db.rows("""
                SELECT Z_PK, \(sqlColumn(c, "ZTITLE", fallback: "''")), Z_ENT, \(sqlColumn(c, "ZSCOPETYPE")), \(sqlColumn(c, "ZSTATUS")), \(sqlColumn(c, "ZASSETCOUNT", fallback: "0")), \(sqlColumn(c, "ZCREATIONDATE"))
                FROM ZSHARE ORDER BY \(sqlColumn(c, "ZCREATIONDATE", fallback: "Z_PK")) DESC LIMIT 2000
                """).map { row in
                let pk = row[0].int ?? 0
                let kind = entity[Int(row[2].int ?? -1)].map(GraphInferences.spaced) ?? "Share"
                return ShareRow(id: pk, title: row[1].string ?? "", kind: kind, scopeType: row[3].int.map(Int.init), status: row[4].int.map(Int.init),
                                assets: Int(row[5].int ?? 0), created: row[6].cocoaDate, participants: perShare[pk] ?? 0)
            }
        }
        if await db.hasColumns("ZGENERICALBUM", ["ZKIND", "ZCACHEDCOUNT"]) {
            let entity = await entityNames(db)
            s.albums = try await db.rows("SELECT Z_ENT, count(*), sum(ZCACHEDCOUNT) FROM ZGENERICALBUM GROUP BY 1 ORDER BY 2 DESC").map { row in
                NamedCount(name: entity[Int(row[0].int ?? -1)].map(GraphInferences.spaced) ?? "Entity \(row[0].int ?? 0)", count: Int(row[1].int ?? 0), detail: "\(Format.count(Int(row[2].int ?? 0))) items")
            }
        }
        return s
    }

    /// Generated titles use U+F8FF as markup: a single one separates the full title from a short
    /// variant (keep the full one), a pair brackets an emphasised word (drop the markers).
    /// Line breaks inside titles become spaces.
    static func clean(_ text: String) -> String {
        var out = text
        if out.unicodeScalars.contains(where: { $0.properties.generalCategory == .privateUse }) {
            let parts = out.unicodeScalars.split(omittingEmptySubsequences: false) { $0.properties.generalCategory == .privateUse }.map { String(String.UnicodeScalarView($0)) }
            out = parts.count == 2 ? parts[0] : parts.joined()
        }
        if out.contains(where: \.isNewline) { out = out.split(whereSeparator: \.isNewline).joined(separator: " ") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Core Data entity number → entity name (Z_PRIMARYKEY).
    static func entityNames(_ db: SQLiteDB) async -> [Int: String] {
        guard await db.hasColumns("Z_PRIMARYKEY", ["Z_ENT", "Z_NAME"]) else { return [:] }
        var out: [Int: String] = [:]
        for row in (try? await db.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY")) ?? [] {
            if let e = row[0].int, let n = row[1].string { out[Int(e)] = n }
        }
        return out
    }
}
