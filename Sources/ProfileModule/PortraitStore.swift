import Foundation
import DossierCore

// MARK: - Models

struct TopicRow: Identifiable, Sendable, Hashable {
    var id: String { qid }
    let qid: String
    var name: String?
    var nameOrigin: String?
    let records: Int
    let score: Double
    let cachedScore: Double?
    let decay: Double
    let documents: Int
    let apps: String
    let algorithms: String
    let first: Date?
    let last: Date?
    let sentiment: Double
    /// For topics without a local name: the named entities most often found in the same
    /// source documents ("seen with …"), so the row is not just a bare id.
    var context: String?

    var title: String { name ?? qid }
}

struct EntityRow: Identifiable, Sendable, Hashable {
    let id: Int64
    let name: String
    let key: String
    let category: Int
    let mentions: Int
    let occurrences: Int
    let score: Double
    let sentiment: Double
    let documents: Int
    let apps: String
    let algorithms: String
    let last: Date?
}

struct PortraitDocument: Identifiable, Sendable, Hashable {
    let id: Int64
    let date: Date?
    let bundle: String
    let group: String
    let docID: String
    let language: String
    let algorithm: Int
    let score: Double
    let sentiment: Double
    let occurrences: Int
}

struct PlaceRow: Identifiable, Sendable, Hashable {
    let id: Int64
    let name: String
    let key: String
    let category: Int
    let algorithm: Int
    let latitude: Double?
    let longitude: Double?
    let records: Int
    let score: Double
    let last: Date?
    let bundle: String
    let group: String
    let locality: String
    let country: String

    var origin: String { PortraitLabels.origin(bundle: bundle, group: group) }
    var hasCoordinate: Bool { latitude != nil && longitude != nil }
}

struct PlaceDetail: Sendable {
    var fields: [(String, String)] = []
    var areasOfInterest: [String] = []
    var contextualEntities: [String] = []
    var documents: [PortraitDocument] = []
}

enum PlaceOrigin: String, CaseIterable, Identifiable, Sendable {
    case all = "All Origins"
    case photos = "Photos"
    case collections = "Maps Guides"
    case pinned = "Pinned Places"
    case viewed = "Viewed / Searched"
    case other = "Mail & Other"
    var id: String { rawValue }

    var predicate: String? {
        switch self {
        case .all: return nil
        case .photos: return "s.group_id LIKE '%PhotosGraphDonation%'"
        case .collections: return "s.group_id LIKE '%Maps.Collections'"
        case .pinned: return "s.group_id LIKE '%Maps.PinnedPlaces'"
        case .viewed: return "s.group_id LIKE '%HVSearchableUserActivity%'"
        case .other:
            return "(s.group_id IS NULL OR (s.group_id NOT LIKE '%PhotosGraphDonation%' AND s.group_id NOT LIKE '%Maps.Collections' AND s.group_id NOT LIKE '%Maps.PinnedPlaces' AND s.group_id NOT LIKE '%HVSearchableUserActivity%'))"
        }
    }
}

struct HandleRow: Identifiable, Sendable, Hashable {
    let id: Int64
    let value: String
    let documents: Int
    let apps: String
    let first: Date?
    let last: Date?
    let significant: Bool

    var kind: String { value.contains("@") ? "E-mail" : (value.first == "+" || value.first?.isNumber == true ? "Phone" : "Handle") }
}

struct SignificantRow: Identifiable, Sendable, Hashable {
    let id: Int64
    let handle: String
    let documents: Int
    var kind: String { handle.contains("@") ? "E-mail" : (handle.first == "+" || handle.first?.isNumber == true ? "Phone" : "Handle") }
}

struct HandleDetail: Sendable {
    var documents: [PortraitDocument] = []
    var entities: [(name: String, category: Int, count: Int)] = []
}

struct SourceAppRow: Identifiable, Sendable, Hashable {
    var id: String { bundle }
    let bundle: String
    let documents: Int
    var topics = 0
    var entities = 0
    var places = 0
    let first: Date?
    let last: Date?
}

struct SocialHighlight: Identifiable, Sendable, Hashable {
    let id: String
    let date: Date
    let contentDate: Date?
    let url: String
    let sender: String
    let app: String
    let kind: String
    let title: String
    let score: Double?
    let appearances: Int
}

struct PortraitOverview: Sendable {
    var sources = 0
    var topicRecords = 0
    var topics = 0
    var entityRecords = 0
    var entities = 0
    var placeRecords = 0
    var handles = 0
    var significant = 0
    var timeRange: ClosedRange<Date>?
    var topTopics: [TopicRow] = []
    var entityGroups: [(category: Int, distinct: Int, top: [(name: String, mentions: Int)])] = []
    var topPlaces: [PlaceRow] = []
    var apps: [SourceAppRow] = []
    var monthly: [ChartPoint] = []
    /// How many of the owner's topics have a locally derived name.
    var topicsNamed = 0
    /// Top topics among the named ones only (filled when `topTopics` contains unnamed ids).
    var topTopicsNamed: [TopicRow] = []
    /// The most mentioned entity the system classified as a person. `matchesContact` says
    /// whether the name also occurs among the names the system learned from Contacts and
    /// message headers — the tagger files pronouns and capitalised words under "Person" too.
    var topPerson: (name: String, mentions: Int, matchesContact: Bool)?
}

/// Names for Wikidata topic ids, derived without any lookup: from files on this Mac
/// (Photos scene map, document languages, the system's name gazetteer) and from the
/// compiled-in label table of the fixed high-level topic vocabulary.
struct TopicCatalog: Sendable {
    var names: [String: (label: String, origin: String)] = [:]
    var cached: [String: Double] = [:]

    func matching(_ search: String) -> [String] {
        let needle = search.lowercased()
        guard !needle.isEmpty else { return [] }
        return names.filter { $0.value.label.lowercased().contains(needle) }.map(\.key)
    }
}

// MARK: - Store

/// Read-only access to `~/Library/PersonalizationPortrait`.
///
/// `PPSQLDatabase.db` holds one row per *extraction*: a topic (`tp_records`, Wikidata QID),
/// named entity (`ne_records`) or location (`loc_records`) found in one source document
/// (`sources`: app bundle, group, document id, time). The views aggregate these rows per
/// topic / entity / place.
enum PortraitStore {
    static func database() async throws -> SQLiteDB {
        switch Paths.probe(ProfilePaths.portraitDB) {
        case .missing: throw DossierError.missing("PersonalizationPortrait has no PPSQLDatabase.db on this Mac.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        do { return try await SQLiteDB.shared(ProfilePaths.portraitDB) } catch let error as SQLiteError {
            if error.isAccessProblem { throw DossierError.inaccessible(error.localizedDescription) }
            throw DossierError.message(error.localizedDescription)
        }
    }

    private static func require(_ db: SQLiteDB, _ table: String, _ columns: [String]) async throws {
        guard await db.hasColumns(table, columns) else {
            throw DossierError.missing("Table \(table) is missing or has a different layout on this macOS version.")
        }
    }

    // MARK: Topic catalog (names + cached scores)

    private actor CatalogCache {
        var value: TopicCatalog?
        var loaded = Date.distantPast
        func get() async -> TopicCatalog {
            if let value, Date().timeIntervalSince(loaded) < 20 { return value }
            let fresh = await PortraitStore.loadCatalog()
            value = fresh; loaded = Date()
            return fresh
        }
        func reset() { value = nil }
    }
    private static let catalogCache = CatalogCache()

    static func catalog() async -> TopicCatalog { await catalogCache.get() }
    static func resetCaches() async { await catalogCache.reset() }

    private static func loadCatalog() async -> TopicCatalog {
        var catalog = TopicCatalog()
        catalog.cached = ScoreCacheFile.read(ProfilePaths.topicScoreCache) ?? [:]
        // (1) Photos scene → QID map shipped with the OS (inverted).
        for (qid, names) in photosTopicMap() {
            catalog.names[qid] = (names.sorted().joined(separator: " / "), "Photos topic map")
        }
        // (2) Language-tagger topics: the QID stands for the language of the tagged documents.
        if let db = await SQLiteDB.sharedIfAvailable(ProfilePaths.portraitDB),
           await db.hasColumns("tp_records", ["topic_id", "algorithm", "source_id"]),
           await db.hasColumns("sources", ["id", "language"]),
           let rows = try? await db.rows("""
               SELECT t.topic_id, s.language, count(*) c FROM tp_records t JOIN sources s ON s.id = t.source_id
               WHERE t.algorithm = 12 AND s.language IS NOT NULL AND s.language != ''
               GROUP BY t.topic_id, s.language ORDER BY c DESC LIMIT 2000
               """) {
            for row in rows {
                guard let qid = row[0].string, let code = row[1].string, catalog.names[qid] == nil else { continue }
                catalog.names[qid] = ("Language: " + ProfileFormat.language(code), "document language")
            }
        }
        // (3) High-level topic model: a fixed vocabulary of generic concepts whose labels are
        // compiled in (the system file holds ids only).
        for (qid, label) in TopicVocabulary.labels where catalog.names[qid] == nil {
            catalog.names[qid] = (label, TopicVocabulary.origin)
        }
        // (4) Augmented Gazetteer: the OS ships the name list its matcher uses (name → id).
        // Only the owner's still unnamed topics are looked up.
        if let db = await SQLiteDB.sharedIfAvailable(ProfilePaths.portraitDB),
           await db.hasColumns("tp_records", ["topic_id"]),
           let rows = try? await db.rows("SELECT DISTINCT topic_id FROM tp_records LIMIT 5000") {
            let unnamed = rows.compactMap { $0[0].string }.filter { catalog.names[$0] == nil }
            for (qid, entry) in await gazetteerNames(unnamed) { catalog.names[qid] = entry }
        }
        return catalog
    }

    /// Category codes of `AugmentedGazetteerMetadata.db` (generic constants, spelled out in
    /// that database's own schema).
    private static let gazetteerCategories: [Int: String] = [
        1: "actor", 2: "musician", 3: "politician", 4: "professional athlete", 5: "sports team",
        6: "tourist attraction", 7: "TV show",
    ]

    /// Looks up topic ids in the name gazetteer shipped with the OS
    /// (`AugmentedGazetteerMetadata.db › metadata`: lower-cased `name`, numeric `qid` without
    /// the "Q", `alias` = canonical spelling when `name` is a normalised variant, `threshold`,
    /// `category_id`). The table is keyed by name, so this is one scan of ~80k generic rows
    /// per 300 ids — done once per catalog load.
    static func gazetteerNames(_ qids: [String]) async -> [String: (label: String, origin: String)] {
        let wanted = qids.filter { $0.range(of: "^Q[0-9]+$", options: .regularExpression) != nil }
        guard !wanted.isEmpty, let url = ProfilePaths.gazetteerDB, let db = await SQLiteDB.sharedIfAvailable(url),
              await db.hasColumns("metadata", ["name", "qid", "category_id", "alias", "threshold"]) else { return [:] }
        struct Entry { var aliases: [String: Int] = [:]; var names: [(name: String, threshold: Int)] = []; var categories: Set<Int> = [] }
        var entries: [String: Entry] = [:]
        var index = 0
        while index < wanted.count {
            let chunk = Array(wanted[index..<min(index + 300, wanted.count)])
            index += 300
            let rows = (try? await db.rows(
                "SELECT qid, name, alias, threshold, category_id FROM metadata WHERE qid IN (" + chunk.map { _ in "?" }.joined(separator: ",") + ") LIMIT 20000",
                chunk.map { .text(String($0.dropFirst())) })) ?? []
            for row in rows {
                guard let number = row[0].string else { continue }
                var entry = entries["Q" + number] ?? Entry()
                if let alias = row[2].string, !alias.isEmpty { entry.aliases[alias, default: 0] += 1 }
                if let name = row[1].string, !name.isEmpty { entry.names.append((name, Int(row[3].int ?? 0))) }
                if let category = row[4].int { entry.categories.insert(Int(category)) }
                entries["Q" + number] = entry
            }
        }
        var out: [String: (label: String, origin: String)] = [:]
        for (qid, entry) in entries {
            // Canonical spelling: the alias most rows point to; without one, the longest of
            // the stored (lower-cased) names, capitalised.
            let label = entry.aliases.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
                ?? entry.names.max { ($0.name.count, $1.name) < ($1.name.count, $0.name) }?.name.capitalized
            guard let label else { continue }
            let kinds = entry.categories.sorted().compactMap { gazetteerCategories[$0] }
            out[qid] = (label, "system name gazetteer" + (kinds.isEmpty ? "" : " · " + kinds.joined(separator: ", ")))
        }
        return out
    }

    /// QID → scene names from `PhotosTopicMap.plist` (newest asset folder that has one).
    static func photosTopicMap() -> [String: [String]] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: ProfilePaths.portraitAssets.path) else { return [:] }
        for folder in folders.filter({ $0.hasPrefix("assets") }).sorted(by: >) {
            let url = ProfilePaths.portraitAssets.appendingPathComponent(folder).appendingPathComponent("PhotosTopicMap.plist")
            guard let data = try? Data(contentsOf: url), let plist = PlistDecoder.decodePlist(data), let pairs = plist.dict else { continue }
            var out: [String: [String]] = [:]
            for pair in pairs {
                if let qid = pair.value.string { out[qid, default: []].append(pair.key) }
            }
            if !out.isEmpty { return out }
        }
        return [:]
    }

    // MARK: Topics

    private static let topicSorts: [String: String] = [
        "topic_id": "t.topic_id", "records": "records", "score": "score", "cached": "cached", "decay": "decay",
        "documents": "documents", "last": "last", "first": "first", "sentiment": "sentiment",
    ]

    private static func topicFilter(search: String, namedOnly: Bool, catalog: TopicCatalog) -> (sql: String, params: [SQLValue]) {
        var conditions: [String] = []
        var params: [SQLValue] = []
        let text = search.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            var clauses = ["t.topic_id LIKE ? ESCAPE '\\'"]
            params.append(.text(ProfileFormat.like(text)))
            let named = Array(catalog.matching(text).prefix(400))
            if !named.isEmpty {
                clauses.append("t.topic_id IN (" + named.map { _ in "?" }.joined(separator: ",") + ")")
                params += named.map { .text($0) }
            }
            conditions.append("(" + clauses.joined(separator: " OR ") + ")")
        }
        if namedOnly {
            let named = Array(catalog.names.keys.sorted().prefix(6_000))
            conditions.append(named.isEmpty ? "0" : "t.topic_id IN (" + named.map { _ in "?" }.joined(separator: ",") + ")")
            params += named.map { .text($0) }
        }
        return (conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "), params)
    }

    static func topics(offset: Int, limit: Int, sort: PageSort?, search: String, namedOnly: Bool = false) async throws -> [TopicRow] {
        let db = try await database()
        try await require(db, "tp_records", ["topic_id", "algorithm", "initial_score", "decay_rate", "source_id"])
        let catalog = await catalog()
        let hasSentiment = await db.hasColumns("tp_records", ["sentiment_score"])
        // The system's own cached ranking is joined in through a VALUES list so that the
        // table can be sorted by it in SQL.
        let cacheEntries = Array(catalog.cached.sorted { $0.key < $1.key }.prefix(4_000))
        var params: [SQLValue] = []
        var cte = "WITH cache(qid, cached) AS (SELECT NULL, NULL WHERE 0)"
        if !cacheEntries.isEmpty {
            cte = "WITH cache(qid, cached) AS (VALUES " + cacheEntries.map { _ in "(?,?)" }.joined(separator: ",") + ")"
            for entry in cacheEntries { params.append(.text(entry.key)); params.append(.real(entry.value)) }
        }
        let filter = topicFilter(search: search, namedOnly: namedOnly, catalog: catalog)
        params += filter.params
        let column = sort.flatMap { topicSorts[$0.columnID] } ?? "cached"
        let direction = sort?.sqlDirection ?? "DESC"
        let sql = """
            \(cte)
            SELECT t.topic_id, count(*) AS records, sum(t.initial_score) AS score, avg(t.decay_rate) AS decay,
                   count(DISTINCT t.source_id) AS documents, group_concat(DISTINCT s.bundle_id) AS apps,
                   group_concat(DISTINCT t.algorithm) AS algos, min(s.seconds_from_1970) AS first,
                   max(s.seconds_from_1970) AS last, \(hasSentiment ? "avg(t.sentiment_score)" : "0") AS sentiment,
                   max(c.cached) AS cached
            FROM tp_records t LEFT JOIN sources s ON s.id = t.source_id LEFT JOIN cache c ON c.qid = t.topic_id
            \(filter.sql)
            GROUP BY t.topic_id
            ORDER BY \(column) \(direction) NULLS LAST, records DESC, t.topic_id
            LIMIT ? OFFSET ?
            """
        params += [.integer(Int64(limit)), .integer(Int64(offset))]
        var topics = try await db.rows(sql, params).map { row in
            let qid = row[0].string ?? "?"
            return TopicRow(
                qid: qid, name: catalog.names[qid]?.label, nameOrigin: catalog.names[qid]?.origin,
                records: Int(row[1].int ?? 0), score: row[2].double ?? 0, cachedScore: row[10].double,
                decay: row[3].double ?? 0, documents: Int(row[4].int ?? 0), apps: row[5].string ?? "",
                algorithms: row[6].string ?? "", first: row[7].unixDate, last: row[8].unixDate, sentiment: row[9].double ?? 0)
        }
        // Topics that no local source can name get the evidence that *is* local instead:
        // the entities found in the same documents. Bounded: at most 60 lookups per page.
        var lookups = 0
        for index in topics.indices where topics[index].name == nil && lookups < 60 {
            lookups += 1
            let seen = await topicEntities(topics[index].qid, limit: 2).map(\.name)
            if !seen.isEmpty { topics[index].context = seen.joined(separator: ", ") }
        }
        return topics
    }

    static func topicCount(search: String, namedOnly: Bool = false) async throws -> Int {
        let db = try await database()
        let filter = topicFilter(search: search, namedOnly: namedOnly, catalog: await catalog())
        return await db.count("SELECT count(DISTINCT t.topic_id) FROM tp_records t \(filter.sql)", filter.params) ?? 0
    }

    /// Named entities extracted from the same source documents as a topic, most shared
    /// documents first (both tables are indexed on `source_id`).
    static func topicEntities(_ qid: String, limit: Int = 20) async -> [(name: String, category: Int, documents: Int)] {
        guard let db = try? await database(),
              await db.hasColumns("ne_records", ["name", "lc_name", "category", "source_id"]),
              await db.hasColumns("tp_records", ["topic_id", "source_id"]) else { return [] }
        let rows = (try? await db.rows("""
            SELECT min(n.name), n.category, count(DISTINCT n.source_id) c FROM ne_records n
            WHERE n.source_id IN (SELECT source_id FROM tp_records WHERE topic_id = ? LIMIT 5000)
            GROUP BY n.lc_name, n.category ORDER BY c DESC, n.lc_name LIMIT ?
            """, [.text(qid), .integer(Int64(limit))])) ?? []
        return rows.map { ($0[0].string ?? "", Int($0[1].int ?? 0), Int($0[2].int ?? 0)) }
    }

    static func topic(_ qid: String) async throws -> TopicRow? {
        try await topics(offset: 0, limit: 50, sort: nil, search: qid).first { $0.qid == qid }
    }

    static func topicDocuments(_ qid: String, limit: Int = 200) async throws -> [PortraitDocument] {
        let db = try await database()
        let occurrences = await db.hasColumns("tp_records", ["occurrences_in_source"]) ? "t.occurrences_in_source" : "1"
        let sentiment = await db.hasColumns("tp_records", ["sentiment_score"]) ? "t.sentiment_score" : "0"
        return try await documents(db, """
            SELECT t.id, s.seconds_from_1970, s.bundle_id, s.group_id, s.doc_id, s.language, t.algorithm, t.initial_score, \(sentiment), \(occurrences)
            FROM tp_records t LEFT JOIN sources s ON s.id = t.source_id WHERE t.topic_id = ?
            ORDER BY s.seconds_from_1970 DESC LIMIT ?
            """, [.text(qid), .integer(Int64(limit))])
    }

    private static func documents(_ db: SQLiteDB, _ sql: String, _ params: [SQLValue]) async throws -> [PortraitDocument] {
        try await db.rows(sql, params).map { row in
            PortraitDocument(
                id: row[0].int ?? 0, date: row[1].unixDate, bundle: row[2].string ?? "", group: row[3].string ?? "",
                docID: row[4].string ?? "", language: row[5].string ?? "", algorithm: Int(row[6].int ?? 0),
                score: row[7].double ?? 0, sentiment: row[8].double ?? 0, occurrences: Int(row[9].int ?? 1))
        }
    }

    // MARK: Named entities

    private static let entitySorts: [String: String] = [
        "name": "n.lc_name", "category": "n.category", "mentions": "mentions", "occurrences": "occurrences",
        "score": "score", "sentiment": "sentiment", "documents": "documents", "last": "last",
    ]

    private static func entityFilter(search: String, category: Int?, bundle: String?) -> (sql: String, params: [SQLValue]) {
        var clauses: [String] = []
        var params: [SQLValue] = []
        if let category { clauses.append("n.category = ?"); params.append(.integer(Int64(category))) }
        let text = search.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { clauses.append("n.lc_name LIKE ? ESCAPE '\\'"); params.append(.text(ProfileFormat.like(text.lowercased()))) }
        if let bundle, !bundle.isEmpty { clauses.append("s.bundle_id = ?"); params.append(.text(bundle)) }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), params)
    }

    static func entities(offset: Int, limit: Int, sort: PageSort?, search: String, category: Int?, bundle: String?) async throws -> [EntityRow] {
        let db = try await database()
        try await require(db, "ne_records", ["id", "name", "lc_name", "category", "algorithm", "initial_score", "source_id"])
        let cols = await db.columnNames(of: "ne_records")
        let sentiment = cols.contains("sentiment_score") ? "avg(n.sentiment_score)" : "0"
        let occurrences = cols.contains("occurrences_in_source") ? "sum(n.occurrences_in_source)" : "count(*)"
        let filter = entityFilter(search: search, category: category, bundle: bundle)
        let column = sort.flatMap { entitySorts[$0.columnID] } ?? "mentions"
        let direction = sort?.sqlDirection ?? "DESC"
        let sql = """
            SELECT min(n.id) AS id, min(n.name) AS name, n.lc_name, n.category, count(*) AS mentions, \(occurrences) AS occurrences,
                   sum(n.initial_score) AS score, \(sentiment) AS sentiment, count(DISTINCT n.source_id) AS documents,
                   group_concat(DISTINCT s.bundle_id) AS apps, group_concat(DISTINCT n.algorithm) AS algos,
                   max(s.seconds_from_1970) AS last
            FROM ne_records n LEFT JOIN sources s ON s.id = n.source_id
            \(filter.sql)
            GROUP BY n.lc_name, n.category
            ORDER BY \(column) \(direction), mentions DESC, n.lc_name
            LIMIT ? OFFSET ?
            """
        return try await db.rows(sql, filter.params + [.integer(Int64(limit)), .integer(Int64(offset))]).map(entityRow)
    }

    private static func entityRow(_ row: SQLRow) -> EntityRow {
        EntityRow(
            id: row[0].int ?? 0, name: row[1].string ?? "", key: row[2].string ?? "", category: Int(row[3].int ?? 0),
            mentions: Int(row[4].int ?? 0), occurrences: Int(row[5].int ?? 0), score: row[6].double ?? 0,
            sentiment: row[7].double ?? 0, documents: Int(row[8].int ?? 0), apps: row[9].string ?? "",
            algorithms: row[10].string ?? "", last: row[11].unixDate)
    }

    static func entityCount(search: String, category: Int?, bundle: String?) async throws -> Int {
        let db = try await database()
        let filter = entityFilter(search: search, category: category, bundle: bundle)
        let join = bundle == nil ? "" : "LEFT JOIN sources s ON s.id = n.source_id"
        return await db.count("SELECT count(*) FROM (SELECT 1 FROM ne_records n \(join) \(filter.sql) GROUP BY n.lc_name, n.category)", filter.params) ?? 0
    }

    /// One aggregated entity by its lower-cased name and category (deep links).
    static func entity(key: String, category: Int?) async throws -> EntityRow? {
        let rows = try await entities(offset: 0, limit: 200, sort: nil, search: key, category: category, bundle: nil)
        return rows.first { $0.key == key.lowercased() } ?? rows.first
    }

    static func entityDocuments(key: String, category: Int, limit: Int = 200) async throws -> [PortraitDocument] {
        let db = try await database()
        let cols = await db.columnNames(of: "ne_records")
        let sentiment = cols.contains("sentiment_score") ? "n.sentiment_score" : "0"
        let occurrences = cols.contains("occurrences_in_source") ? "n.occurrences_in_source" : "1"
        return try await documents(db, """
            SELECT n.id, s.seconds_from_1970, s.bundle_id, s.group_id, s.doc_id, coalesce(s.language, n.language), n.algorithm, n.initial_score, \(sentiment), \(occurrences)
            FROM ne_records n LEFT JOIN sources s ON s.id = n.source_id WHERE n.lc_name = ? AND n.category = ?
            ORDER BY s.seconds_from_1970 DESC LIMIT ?
            """, [.text(key), .integer(Int64(category)), .integer(Int64(limit))])
    }

    static func entityCategories() async throws -> [(category: Int, distinct: Int)] {
        let db = try await database()
        try await require(db, "ne_records", ["lc_name", "category"])
        return try await db.rows("SELECT category, count(DISTINCT lc_name) FROM ne_records GROUP BY category ORDER BY 2 DESC")
            .map { (Int($0[0].int ?? 0), Int($0[1].int ?? 0)) }
    }

    /// Bundle ids of apps that contributed at least one named entity.
    static func entityApps() async -> [String] {
        guard let db = try? await database(), await db.hasColumns("ne_records", ["source_id"]) else { return [] }
        let rows = (try? await db.rows("SELECT s.bundle_id, count(*) c FROM ne_records n JOIN sources s ON s.id = n.source_id GROUP BY s.bundle_id ORDER BY c DESC LIMIT 200")) ?? []
        return rows.compactMap { $0[0].string }
    }

    // MARK: Places

    private static let placeName = """
        coalesce(nullif(max(l.clp_name), ''), nullif(trim(coalesce(max(l.clp_thoroughfare), '') || ' ' || coalesce(max(l.clp_subThoroughfare), '')), ''), nullif(max(l.clp_locality), ''), l.lc_description)
        """
    private static let placeSorts: [String: String] = [
        "name": "name COLLATE NOCASE", "records": "records", "score": "score", "last": "last", "category": "l.category",
        "algorithm": "l.algorithm", "locality": "locality COLLATE NOCASE", "country": "country COLLATE NOCASE",
    ]

    private static func placeFilter(search: String, origin: PlaceOrigin) -> (sql: String, params: [SQLValue]) {
        var clauses: [String] = []
        var params: [SQLValue] = []
        if let predicate = origin.predicate { clauses.append(predicate) }
        let text = search.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let pattern = SQLValue.text(ProfileFormat.like(text))
            clauses.append("(l.lc_description LIKE ? ESCAPE '\\' OR l.clp_name LIKE ? ESCAPE '\\' OR l.clp_locality LIKE ? ESCAPE '\\' OR l.clp_country LIKE ? ESCAPE '\\')")
            params += [pattern, pattern, pattern, pattern]
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), params)
    }

    private static let placeColumns = [
        "id", "lc_description", "category", "algorithm", "initial_score", "source_id", "cll_latitude_degrees",
        "cll_longitude_degrees", "clp_name", "clp_thoroughfare", "clp_subThoroughfare", "clp_locality", "clp_country",
    ]

    static func places(offset: Int, limit: Int, sort: PageSort?, search: String, origin: PlaceOrigin, coordinatesOnly: Bool = false) async throws -> [PlaceRow] {
        let db = try await database()
        try await require(db, "loc_records", placeColumns)
        let filter = placeFilter(search: search, origin: origin)
        let column = sort.flatMap { placeSorts[$0.columnID] } ?? "records"
        let direction = sort?.sqlDirection ?? "DESC"
        let sql = """
            SELECT min(l.id) AS id, \(placeName) AS name, l.lc_description, l.category, l.algorithm,
                   avg(l.cll_latitude_degrees) AS lat, avg(l.cll_longitude_degrees) AS lon, count(*) AS records,
                   sum(l.initial_score) AS score, max(s.seconds_from_1970) AS last, min(s.bundle_id) AS bundle,
                   min(s.group_id) AS grp, coalesce(max(l.clp_locality), '') AS locality, coalesce(max(l.clp_country), '') AS country
            FROM loc_records l LEFT JOIN sources s ON s.id = l.source_id
            \(filter.sql)
            GROUP BY l.lc_description, l.algorithm, l.category
            \(coordinatesOnly ? "HAVING lat IS NOT NULL AND lon IS NOT NULL" : "")
            ORDER BY \(column) \(direction), name COLLATE NOCASE, id
            LIMIT ? OFFSET ?
            """
        return try await db.rows(sql, filter.params + [.integer(Int64(limit)), .integer(Int64(offset))]).map { row in
            PlaceRow(
                id: row[0].int ?? 0, name: row[1].string ?? "", key: row[2].string ?? "", category: Int(row[3].int ?? 0),
                algorithm: Int(row[4].int ?? 0), latitude: row[5].double, longitude: row[6].double,
                records: Int(row[7].int ?? 0), score: row[8].double ?? 0, last: row[9].unixDate,
                bundle: row[10].string ?? "", group: row[11].string ?? "", locality: row[12].string ?? "", country: row[13].string ?? "")
        }
    }

    static func placeCount(search: String, origin: PlaceOrigin) async throws -> Int {
        let db = try await database()
        let filter = placeFilter(search: search, origin: origin)
        return await db.count("""
            SELECT count(*) FROM (SELECT 1 FROM loc_records l LEFT JOIN sources s ON s.id = l.source_id \(filter.sql)
            GROUP BY l.lc_description, l.algorithm, l.category)
            """, filter.params) ?? 0
    }

    /// Location records per origin (for the chart next to the map).
    static func placeOriginCounts() async throws -> [(origin: PlaceOrigin, records: Int)] {
        let db = try await database()
        try await require(db, "loc_records", ["source_id"])
        let row = try await db.first("""
            SELECT count(*),
                   sum(s.group_id LIKE '%PhotosGraphDonation%'), sum(s.group_id LIKE '%Maps.Collections'),
                   sum(s.group_id LIKE '%Maps.PinnedPlaces'), sum(s.group_id LIKE '%HVSearchableUserActivity%')
            FROM loc_records l LEFT JOIN sources s ON s.id = l.source_id
            """)
        let total = Int(row?[0].int ?? 0)
        let parts = (1...4).map { Int(row?[$0].int ?? 0) }
        return [(.photos, parts[0]), (.collections, parts[1]), (.pinned, parts[2]), (.viewed, parts[3]), (.other, max(0, total - parts.reduce(0, +)))]
    }

    static func placeDetail(_ place: PlaceRow) async throws -> PlaceDetail {
        let db = try await database()
        var detail = PlaceDetail()
        let wanted = [
            ("Name", "clp_name"), ("Street", "clp_thoroughfare"), ("Number", "clp_subThoroughfare"), ("City", "clp_locality"),
            ("District", "clp_subLocality"), ("State", "clp_administrativeArea"), ("County", "clp_subAdministrativeArea"),
            ("Postal code", "clp_postalCode"), ("Country", "clp_country"), ("Country code", "clp_ISOcountryCode"),
            ("Inland water", "clp_inlandWater"), ("Ocean", "clp_ocean"), ("Extracted on build", "extraction_os_build"),
        ]
        let cols = await db.columnNames(of: "loc_records")
        let present = wanted.filter { cols.contains($0.1) || cols.contains($0.1.lowercased()) }
        if !present.isEmpty,
           let row = try await db.first("SELECT " + present.map { SQLiteDB.quote($0.1) }.joined(separator: ", ") + " FROM loc_records WHERE id = ?", [.integer(place.id)]) {
            for (index, field) in present.enumerated() {
                if let value = row[index].string, !value.isEmpty { detail.fields.append((field.0, value)) }
            }
        }
        let ids = "SELECT id FROM loc_records WHERE lc_description = ? AND algorithm = ? AND category = ?"
        let key: [SQLValue] = [.text(place.key), .integer(Int64(place.algorithm)), .integer(Int64(place.category))]
        if await db.hasColumns("loc_records_clp_areasOfInterest", ["loc_id", "name"]) {
            detail.areasOfInterest = (try? await db.rows("SELECT DISTINCT name FROM loc_records_clp_areasOfInterest WHERE loc_id IN (\(ids)) LIMIT 50", key))?.compactMap { $0[0].string } ?? []
        }
        if await db.hasColumns("loc_records_contextual_ne", ["loc_id", "name"]) {
            detail.contextualEntities = (try? await db.rows("SELECT DISTINCT name FROM loc_records_contextual_ne WHERE loc_id IN (\(ids)) LIMIT 50", key))?.compactMap { $0[0].string } ?? []
        }
        detail.documents = try await documents(db, """
            SELECT l.id, s.seconds_from_1970, s.bundle_id, s.group_id, s.doc_id, s.language, l.algorithm, l.initial_score, 0, 1
            FROM loc_records l LEFT JOIN sources s ON s.id = l.source_id
            WHERE l.lc_description = ? AND l.algorithm = ? AND l.category = ? ORDER BY s.seconds_from_1970 DESC LIMIT 100
            """, key)
        return detail
    }

    // MARK: Contact handles

    private static let handleSorts: [String: String] = [
        "value": "h.value COLLATE NOCASE", "documents": "documents", "last": "last", "first": "first", "significant": "significant",
    ]

    static func handles(offset: Int, limit: Int, sort: PageSort?, search: String) async throws -> [HandleRow] {
        let db = try await database()
        try await require(db, "cn_handles", ["id", "value"])
        try await require(db, "cn_handles_sources", ["cn_handle_id", "source_id"])
        let hasSignificant = await db.hasColumns("significant_contacts", ["handle"])
        let text = search.trimmingCharacters(in: .whitespaces)
        let column = sort.flatMap { handleSorts[$0.columnID] } ?? "documents"
        let direction = sort?.sqlDirection ?? "DESC"
        let sql = """
            SELECT h.id, h.value, count(hs.source_id) AS documents, group_concat(DISTINCT s.bundle_id) AS apps,
                   min(s.seconds_from_1970) AS first, max(s.seconds_from_1970) AS last,
                   \(hasSignificant ? "EXISTS(SELECT 1 FROM significant_contacts sc WHERE sc.handle = h.value)" : "0") AS significant
            FROM cn_handles h LEFT JOIN cn_handles_sources hs ON hs.cn_handle_id = h.id LEFT JOIN sources s ON s.id = hs.source_id
            \(text.isEmpty ? "" : "WHERE h.value LIKE ? ESCAPE '\\'")
            GROUP BY h.id
            ORDER BY \(column) \(direction), h.value COLLATE NOCASE
            LIMIT ? OFFSET ?
            """
        let params: [SQLValue] = (text.isEmpty ? [] : [.text(ProfileFormat.like(text))]) + [.integer(Int64(limit)), .integer(Int64(offset))]
        return try await db.rows(sql, params).map { row in
            HandleRow(id: row[0].int ?? 0, value: row[1].string ?? "", documents: Int(row[2].int ?? 0), apps: row[3].string ?? "",
                      first: row[4].unixDate, last: row[5].unixDate, significant: row[6].bool ?? false)
        }
    }

    static func handleCount(search: String) async throws -> Int {
        let db = try await database()
        let text = search.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return await db.rowCount(of: "cn_handles") ?? 0 }
        return await db.count("SELECT count(*) FROM cn_handles h WHERE h.value LIKE ? ESCAPE '\\'", [.text(ProfileFormat.like(text))]) ?? 0
    }

    static func significantContacts() async throws -> [SignificantRow] {
        let db = try await database()
        try await require(db, "significant_contacts", ["handle"])
        let hasHandles = await db.hasColumns("cn_handles", ["id", "value"])
        let hasLinks = await db.hasColumns("cn_handles_sources", ["cn_handle_id"])
        let linked = hasHandles && hasLinks
        let docs = linked
            ? "(SELECT count(*) FROM cn_handles h JOIN cn_handles_sources hs ON hs.cn_handle_id = h.id WHERE h.value = sc.handle)"
            : "0"
        return try await db.rows("SELECT sc.rowid, sc.handle, \(docs) FROM significant_contacts sc ORDER BY 3 DESC, 2 LIMIT 20000").map {
            SignificantRow(id: $0[0].int ?? 0, handle: $0[1].string ?? "", documents: Int($0[2].int ?? 0))
        }
    }

    static func handleDetail(_ handleID: Int64) async throws -> HandleDetail {
        let db = try await database()
        var detail = HandleDetail()
        detail.documents = try await documents(db, """
            SELECT s.id, s.seconds_from_1970, s.bundle_id, s.group_id, s.doc_id, s.language, 0, 0, 0, 1
            FROM cn_handles_sources hs JOIN sources s ON s.id = hs.source_id WHERE hs.cn_handle_id = ?
            ORDER BY s.seconds_from_1970 DESC LIMIT 100
            """, [.integer(handleID)])
        if await db.hasColumns("ne_records", ["lc_name", "name", "category", "source_id"]) {
            detail.entities = (try? await db.rows("""
                SELECT min(n.name), n.category, count(*) c FROM ne_records n
                WHERE n.source_id IN (SELECT source_id FROM cn_handles_sources WHERE cn_handle_id = ?)
                GROUP BY n.lc_name, n.category ORDER BY c DESC LIMIT 20
                """, [.integer(handleID)]))?.map { ($0[0].string ?? "", Int($0[1].int ?? 0), Int($0[2].int ?? 0)) } ?? []
        }
        return detail
    }

    // MARK: Overview

    static func overview() async throws -> PortraitOverview {
        let db = try await database()
        try await require(db, "sources", ["id", "bundle_id", "seconds_from_1970"])
        var overview = PortraitOverview()
        overview.sources = await db.rowCount(of: "sources") ?? 0
        overview.topicRecords = await db.rowCount(of: "tp_records") ?? 0
        overview.topics = await db.count("SELECT count(DISTINCT topic_id) FROM tp_records") ?? 0
        overview.entityRecords = await db.rowCount(of: "ne_records") ?? 0
        overview.entities = await db.count("SELECT count(*) FROM (SELECT 1 FROM ne_records GROUP BY lc_name, category)") ?? 0
        overview.placeRecords = await db.rowCount(of: "loc_records") ?? 0
        overview.handles = await db.rowCount(of: "cn_handles") ?? 0
        overview.significant = await db.rowCount(of: "significant_contacts") ?? 0
        if let row = try? await db.first("SELECT min(seconds_from_1970), max(seconds_from_1970) FROM sources WHERE seconds_from_1970 > 0"),
           let lo = row[0].unixDate, let hi = row[1].unixDate, lo <= hi {
            overview.timeRange = lo...hi
        }
        overview.topTopics = (try? await topics(offset: 0, limit: 12, sort: nil, search: "")) ?? []
        overview.topicsNamed = (try? await topicCount(search: "", namedOnly: true)) ?? 0
        if overview.topTopics.contains(where: { $0.name == nil }) {
            overview.topTopicsNamed = (try? await topics(offset: 0, limit: 12, sort: nil, search: "", namedOnly: true)) ?? []
        }
        overview.topPlaces = (try? await places(offset: 0, limit: 8, sort: nil, search: "", origin: .all)) ?? []

        // Top entities per category: one streamed pass over the grouped names.
        if await db.hasColumns("ne_records", ["lc_name", "name", "category"]) {
            struct Acc: Sendable { var groups: [Int: (distinct: Int, top: [(String, Int)])] = [:] }
            let acc = try await db.reduce("""
                SELECT category, min(name), count(*) c FROM ne_records GROUP BY category, lc_name ORDER BY category, c DESC
                """, into: Acc()) { acc, row in
                let category = Int(row[0].int ?? 0)
                var entry = acc.groups[category] ?? (0, [])
                entry.distinct += 1
                if entry.top.count < 6 { entry.top.append((row[1].string ?? "", Int(row[2].int ?? 0))) }
                acc.groups[category] = entry
            }
            overview.entityGroups = acc.groups
                .map { (category: $0.key, distinct: $0.value.distinct, top: $0.value.top.map { (name: $0.0, mentions: $0.1) }) }
                .sorted { $0.distinct > $1.distinct }
        }

        // Most mentioned "person": prefer one whose name the system also knows as a contact.
        if await db.hasColumns("ne_records", ["lc_name", "name", "category"]) {
            let people = (try? await db.rows("SELECT min(name), lc_name, count(*) c FROM ne_records WHERE category = 1 GROUP BY lc_name ORDER BY c DESC, lc_name LIMIT 150")) ?? []
            let known = await knownPersonNames()
            if let match = people.first(where: { known.matches($0[1].string ?? "") }) {
                overview.topPerson = (match[0].string ?? "", Int(match[2].int ?? 0), true)
            } else if let first = people.first {
                overview.topPerson = (first[0].string ?? "", Int(first[2].int ?? 0), false)
            }
        }

        // Per source app.
        var apps: [String: SourceAppRow] = [:]
        for row in try await db.rows("SELECT bundle_id, count(*), min(seconds_from_1970), max(seconds_from_1970) FROM sources GROUP BY bundle_id") {
            let bundle = row[0].string ?? ""
            apps[bundle] = SourceAppRow(bundle: bundle, documents: Int(row[1].int ?? 0), first: row[2].unixDate, last: row[3].unixDate)
        }
        for (table, path) in [("tp_records", \SourceAppRow.topics), ("ne_records", \SourceAppRow.entities), ("loc_records", \SourceAppRow.places)] {
            guard await db.hasColumns(table, ["source_id"]) else { continue }
            let rows = (try? await db.rows("SELECT s.bundle_id, count(*) FROM \(table) r JOIN sources s ON s.id = r.source_id GROUP BY s.bundle_id")) ?? []
            for row in rows {
                let bundle = row[0].string ?? ""
                apps[bundle]?[keyPath: path] = Int(row[1].int ?? 0)
            }
        }
        overview.apps = apps.values.sorted { $0.documents > $1.documents }

        // Documents per month and app (top 5 apps, rest folded).
        let top = Set(overview.apps.prefix(5).map(\.bundle))
        let monthly = (try? await db.rows("""
            SELECT strftime('%Y-%m', seconds_from_1970, 'unixepoch', 'localtime') m, bundle_id, count(*)
            FROM sources WHERE seconds_from_1970 > 0 GROUP BY m, bundle_id ORDER BY m LIMIT 5000
            """)) ?? []
        var calendar = Calendar.current
        calendar.timeZone = .current
        var buckets: [String: [Date: Double]] = [:]
        for row in monthly {
            guard let month = row[0].string, month.count == 7,
                  let year = Int(month.prefix(4)), let mon = Int(month.suffix(2)),
                  let date = calendar.date(from: DateComponents(year: year, month: mon, day: 1)) else { continue }
            let bundle = row[1].string ?? ""
            let series = top.contains(bundle) ? AppNames.name(bundle) : "Other"
            buckets[series, default: [:]][date, default: 0] += Double(row[2].int ?? 0)
        }
        overview.monthly = buckets.flatMap { series, values in values.map { ChartPoint($0.key, $0.value, series: series) } }
            .sorted { ($0.date, $0.series) < ($1.date, $1.series) }
        return overview
    }

    // MARK: Known person names

    /// Names the system itself attributes to real people: Contacts name records and the
    /// display names learned from message headers. Used only to tell real people apart from
    /// pronouns and other words the entity tagger filed under "Person".
    struct KnownNames: Sendable {
        var full: Set<String> = []
        var parts: Set<String> = []

        /// A lower-cased entity name matches when it is a known full name, or when every
        /// word of it is a known name part (given / family name from Contacts).
        func matches(_ name: String) -> Bool {
            let key = name.lowercased().trimmingCharacters(in: .whitespaces)
            guard key.count >= 2 else { return false }
            if full.contains(key) { return true }
            let words = key.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }).map(String.init)
            return !words.isEmpty && words.allSatisfy { $0.count >= 2 && parts.contains($0) }
        }
    }

    static func knownPersonNames() async -> KnownNames {
        await Task.detached(priority: .utility) {
            var known = KnownNames()
            for record in nameRecords() {
                let key = record.name.lowercased()
                known.full.insert(key)
                for word in key.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }) where word.count >= 2 { known.parts.insert(String(word)) }
            }
            for learned in SuggestionsStore.learnedNames() { known.full.insert(learned.name.lowercased().trimmingCharacters(in: .whitespaces)) }
            return known
        }.value
    }

    // MARK: Me card, name records, social highlights

    /// Non-empty strings of the cached "me" contact card (`Contacts/me_card.pb`).
    /// Field numbers observed: 1 = contact identifier, 2 = given name, 16 = display name,
    /// 18 = modification time (Cocoa seconds); other string fields are name parts.
    static func meCard() -> [(label: String, value: String)] {
        guard let data = try? Data(contentsOf: ProfilePaths.meCard), let message = ProtoMessage(data) else { return [] }
        let labels: [Int: String] = [1: "Contact identifier", 2: "Given name", 16: "Display name"]
        var out: [(String, String)] = []
        for field in message.fields {
            if field.number == 18, let seconds = field.int { out.append(("Updated", DossierDate.medium(DossierDate.cocoa(seconds)))); continue }
            guard let text = field.string, !text.isEmpty else { continue }
            out.append((labels[field.number] ?? "Name field \(field.number)", text))
        }
        return out
    }

    /// Name records (`Contacts/name_records/*.pb`): names the system learned for the owner
    /// and contacts, each with a score. Returns (name parts, score).
    static func nameRecords() -> [(name: String, score: Double?)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: ProfilePaths.nameRecords.path) else { return [] }
        var out: [(String, Double?)] = []
        for file in files.sorted() where file.hasSuffix(".pb") {
            guard let data = try? Data(contentsOf: ProfilePaths.nameRecords.appendingPathComponent(file)), data.count < 8 << 20,
                  let message = ProtoMessage(data) else { continue }
            for field in message.all(1) {
                guard let record = field.message else { continue }
                // 6… = name parts (given, phonetic, middle, family, …); 1 and 5 are identifiers.
                let parts = record.fields.filter { $0.number >= 6 }.compactMap { $0.string }.filter { !$0.isEmpty }
                if parts.isEmpty { continue }
                out.append((parts.joined(separator: " "), record[2]?.double))
                if out.count >= 5_000 { return out }
            }
        }
        return out
    }

    /// Ranked "Shared with You" highlights (`streams/rankedSocialHighlights`, SEGB).
    /// Fields used: 1 highlight id, 5 source app, 7 URL, 8.4 sender handle, 12 kind,
    /// 13 content date (Cocoa), 20 rank score, 32 group / display name.
    static func socialHighlights() throws -> [SocialHighlight] {
        switch Paths.probe(ProfilePaths.socialHighlights) {
        case .missing: return []
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        guard let stream = Biome.loadStream(ProfilePaths.socialHighlights) else { return [] }
        var byID: [String: SocialHighlight] = [:]
        var counts: [String: Int] = [:]
        var seen = 0
        BiomeStreamReader(stream).forEachMessage(device: nil, order: .newestFirst) { record, message in
            seen += 1
            let id = message[1]?.string ?? record.id
            counts[id, default: 0] += 1
            if let existing = byID[id], existing.date >= record.timestamp { return seen < 200_000 }
            byID[id] = SocialHighlight(
                id: id, date: record.timestamp, contentDate: message[13]?.cocoaDate, url: message[7]?.string ?? "",
                sender: message[8]?.message?[4]?.string ?? "", app: message[5]?.string ?? "",
                kind: message[12]?.string ?? "", title: message[32]?.string ?? "", score: message[20]?.double,
                appearances: 1)
            return seen < 200_000 && !Task.isCancelled
        }
        return byID.values.map { item in
            SocialHighlight(id: item.id, date: item.date, contentDate: item.contentDate, url: item.url, sender: item.sender,
                            app: item.app, kind: item.kind, title: item.title, score: item.score, appearances: counts[item.id] ?? 1)
        }.sorted { $0.date > $1.date }
    }
}

// MARK: - Topics/ScoreCache

/// Reader for `Topics/ScoreCache`, a "lazy plist" (`PLP\u{1}` magic) holding one dictionary
/// QID → score. Layout observed: 16-byte header (magic, three `u32` offsets), NUL-terminated
/// key strings, raw little-endian doubles, then a table of tagged `u32` references — the
/// last word of the file points at the root dictionary (`count`, `count` key references,
/// `count` value references). Tag (top 4 bits): 0xA string, 0x4 double, 0xC dictionary.
enum ScoreCacheFile {
    static func read(_ url: URL) -> [String: Double]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 24, data.count < 64 << 20 else { return nil }
        guard data[0] == 0x50, data[1] == 0x4c, data[2] == 0x50 else { return nil }
        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard let root = u32(data.count - 4), root >> 28 == 0xC else { return nil }
        let base = Int(root & 0x0FFF_FFFF)
        guard let count32 = u32(base) else { return nil }
        let count = Int(count32)
        guard count >= 0, base + 4 + count * 8 <= data.count else { return nil }
        var out: [String: Double] = [:]
        out.reserveCapacity(count)
        for i in 0..<count {
            guard let keyRef = u32(base + 4 + i * 4), let valueRef = u32(base + 4 + (count + i) * 4), keyRef >> 28 == 0xA else { continue }
            let keyOffset = Int(keyRef & 0x0FFF_FFFF)
            guard keyOffset < data.count else { continue }
            var end = keyOffset
            while end < data.count, data[end] != 0, end - keyOffset < 256 { end += 1 }
            let key = String(decoding: data[keyOffset..<end], as: UTF8.self)
            guard valueRef >> 28 == 0x4 else { continue }
            let valueOffset = Int(valueRef & 0x0FFF_FFFF)
            guard valueOffset + 8 <= data.count else { continue }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: valueOffset, as: Double.self) }
            if value.isFinite { out[key] = value }
        }
        return out
    }
}
