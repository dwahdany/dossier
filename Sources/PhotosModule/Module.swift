import SwiftUI
import DossierCore

/// Photos Intelligence — what the Photos library has inferred about its owner: recognised people and
/// their face attributes, the PhotosGraph knowledge graph (home, work, relationships, trips), places,
/// the search index, machine captions, recognised text, memories and sharing statistics.
///
/// Stores (all read-only, inside the `*.photoslibrary` bundle):
///   database/Photos.sqlite                                       assets, people, faces, moments, memories, search lexicon
///   database/search/psi.sqlite                                   legacy search index
///   private/com.apple.photoanalysisd/**/photosgraph.kgdb         PhotosGraph knowledge graph
///   private/com.apple.mediaanalysisd/**/MediaAnalysis.sqlite     captions and media analysis results
///
/// No image data is ever decoded or shown: counts, labels and text only.
public final class PhotosModule: DossierModule {
    public let id = "photos"
    public let title = "Photos Intelligence"
    public let symbol = "photo.on.rectangle.angled"
    public let group = SidebarGroup.media

    public init() {}

    public var sections: [ModuleSection] {
        [
            ModuleSection(id: "photos.summary", title: "Summary", symbol: "chart.bar.doc.horizontal") { SummarySection() },
            ModuleSection(id: "photos.people", title: "People & Faces", symbol: "person.crop.rectangle.stack") { PeopleSection() },
            ModuleSection(id: "photos.graph", title: "Graph Inferences", symbol: "point.3.connected.trianglepath.dotted") { GraphSection() },
            ModuleSection(id: "photos.places", title: "Places & Trips", symbol: "map") { PlacesSection() },
            ModuleSection(id: "photos.search", title: "Search Index", symbol: "text.magnifyingglass") { SearchIndexSection() },
            ModuleSection(id: "photos.captions", title: "Captions & OCR", symbol: "text.bubble") { CaptionsSection() },
            ModuleSection(id: "photos.memories", title: "Memories & Sharing", symbol: "photo.stack") { MemoriesSection() },
        ]
    }

    // MARK: Summary

    public func summary() async -> ModuleSummary {
        guard let lib = PhotosLibraryLocator.current() else {
            return ModuleSummary(stores: [StoreInfo.file("Photos Library", nil, note: "No Photos library found in ~/Pictures")], facts: [])
        }
        var photos = StoreInfo.file("Photos.sqlite", lib.photosDB, note: "Assets, people, faces, moments, memories, search lexicon")
        var psi = StoreInfo.file("psi.sqlite", lib.psiDB, note: "Legacy search index")
        var graph = StoreInfo.file("photosgraph.kgdb", lib.graphDB ?? lib.expectedGraphDB, note: "PhotosGraph knowledge graph")
        var media = StoreInfo.file("MediaAnalysis.sqlite", lib.mediaAnalysisDB ?? lib.expectedMediaAnalysisDB, note: "Captions and media analysis")
        var facts: [Fact] = []

        if photos.availability.isAvailable, let db = await SQLiteDB.sharedIfAvailable(lib.photosDB), await db.tableExists("ZASSET") {
            photos.rowCount = await db.rowCount(of: "ZASSET")
            if let r = try? await db.first("SELECT min(ZDATECREATED), max(ZDATECREATED) FROM ZASSET"), let lo = r[0].cocoaDate, let hi = r[1].cocoaDate, lo <= hi {
                photos.timeRange = lo...hi
            }
            if let assets = photos.rowCount {
                let located = await db.count("SELECT count(*) FROM ZASSET WHERE ZLATITUDE BETWEEN -90 AND 90 AND NOT (ZLATITUDE = 0 AND ZLONGITUDE = 0)") ?? 0
                facts.append(Fact("Photos and videos analysed", "\(Format.count(assets)) assets, \(Format.count(located)) with a location", sensitivity: .personal, symbol: "photo.stack", sectionID: "photos.summary"))
            }
            if await db.tableExists("ZPERSON"), await db.tableExists("ZDETECTEDFACE") {
                // Merged-away duplicates keep their row and name; they and clusters without a face are not counted.
                let people = await PhotosStore.personCounts(db)
                let faces = await db.rowCount(of: "ZDETECTEDFACE") ?? 0
                facts.append(Fact("People recognised", "\(people.namedText), \(Format.count(people.clusters)) face clusters, \(Format.count(faces)) faces", sensitivity: .sensitive, symbol: "person.crop.rectangle.stack", sectionID: "photos.people"))
                if await db.hasColumns("ZDETECTEDFACE", ["ZAGETYPE", "ZGENDERTYPE", "ZETHNICITYTYPE"]) {
                    let analysed = await db.count("SELECT count(*) FROM ZDETECTEDFACE WHERE ZAGETYPE != 0") ?? 0
                    facts.append(Fact("Faces with inferred attributes", "\(Format.count(analysed)) faces carry age, gender, ethnicity and skin-tone classes", sensitivity: .sensitive, symbol: "faceid", sectionID: "photos.people"))
                }
            }
            // Photos' own per-photo "taken at home" judgement, read from the reverse-geocode archives
            // (flag only — a fraction of a second, cached).
            if let flags = try? await ReverseGeoCache.shared.homeFlags(lib), flags.total > 0 {
                facts.append(Fact("Photos flagged as taken at home", "\(Format.count(flags.home.count)) of \(Format.count(flags.total)) reverse-geocoded photos carry Photos’ “at home” flag, each with a postal address", sensitivity: .sensitive, symbol: "house.lodge", sectionID: "photos.places"))
            }
            if await db.tableExists("ZMEMORY") {
                let memories = await db.rowCount(of: "ZMEMORY") ?? 0
                let trips = await db.hasColumns("ZPHOTOSHIGHLIGHT", ["ZKIND"]) ? (await db.count("SELECT count(*) FROM ZPHOTOSHIGHLIGHT WHERE ZKIND = 3") ?? 0) : 0
                facts.append(Fact("Memories and trips", "\(Format.count(memories)) generated memories, \(Format.count(trips)) trips detected", sensitivity: .personal, symbol: "sparkles.rectangle.stack", sectionID: "photos.memories"))
            }
            if await db.hasColumns("ZLEOLEXEME", ["ZCATEGORY"]) {
                let ocr = await db.count("SELECT count(*) FROM ZLEOLEXEME WHERE ZCATEGORY = ?", [.integer(Int64(SearchBackend.leo.ocrCode))]) ?? 0
                if ocr > 0 {
                    facts.append(Fact("Text read from your photos", "\(Format.count(ocr)) distinct words recognised and indexed for search", sensitivity: .sensitive, symbol: "text.viewfinder", sectionID: "photos.captions"))
                }
            }
        }
        if psi.availability.isAvailable, let db = await SQLiteDB.sharedIfAvailable(lib.psiDB), await db.tableExists("groups") {
            psi.rowCount = await db.rowCount(of: "groups")
        }
        if media.availability.isAvailable, let url = lib.mediaAnalysisDB, let db = await SQLiteDB.sharedIfAvailable(url), await db.tableExists("ZIMAGECAPTIONRESULT") {
            let captions = await db.rowCount(of: "ZIMAGECAPTIONRESULT") ?? 0
            let video = await db.tableExists("ZVIDEOCAPTIONRESULT") ? (await db.rowCount(of: "ZVIDEOCAPTIONRESULT") ?? 0) : 0
            media.rowCount = captions + video
            facts.append(Fact("Machine-written captions", "\(Format.count(captions)) photo and \(Format.count(video)) video descriptions", sensitivity: .sensitive, symbol: "text.bubble", sectionID: "photos.captions"))
        }
        if graph.availability.isAvailable, let (_, inf) = try? await PhotosCaches.shared.graph(for: lib) {
            graph.rowCount = inf.nodeCount
            graph.timeRange = inf.momentRange
            let home = inf.places.filter { $0.kind == "Home" && $0.latitude != nil }.count
            let work = inf.places.filter { $0.kind == "Work" && $0.latitude != nil }.count
            if home + work > 0 {
                facts.append(Fact("Home and work inferred", "\(home) home and \(work) work address\(home + work == 1 ? "" : "es") in the PhotosGraph", sensitivity: .sensitive, symbol: "house", sectionID: "photos.graph"))
            }
            if !inf.relationships.isEmpty {
                let kinds = Dictionary(grouping: inf.relationships, by: \.type).map { "\($0.value.count) \($0.key.lowercased())" }.sorted().joined(separator: ", ")
                facts.append(Fact("Relationships inferred", kinds, sensitivity: .sensitive, symbol: "person.2", sectionID: "photos.graph"))
            }
            if !inf.taboo.isEmpty {
                let moments = inf.taboo.reduce(0) { $0 + $1.moments }
                if moments > 0 {
                    facts.append(Fact("Sensitive content flagged", "\(moments) moments tagged with taboo classes (\(inf.taboo.filter { $0.moments > 0 }.map(\.name).joined(separator: ", ")))", sensitivity: .sensitive, symbol: "exclamationmark.shield", sectionID: "photos.graph"))
                }
            }
        }
        // Most telling inferences first; the Overview shows at most eight.
        let priority = ["Photos and videos analysed", "People recognised", "Faces with inferred attributes", "Home and work inferred", "Photos flagged as taken at home", "Relationships inferred",
                        "Machine-written captions", "Text read from your photos", "Sensitive content flagged", "Memories and trips"]
        facts.sort { (priority.firstIndex(of: $0.label) ?? 99) < (priority.firstIndex(of: $1.label) ?? 99) }
        return ModuleSummary(stores: [photos, graph, media, psi], facts: Array(facts.prefix(8)))
    }

    // MARK: Search

    public func search(_ query: String, limit: Int) async -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, let lib = PhotosLibraryLocator.current() else { return [] }
        var hits: [SearchHit] = []
        let like: SQLValue = .text("%\(q)%")
        let each = max(3, limit / 4)

        if let db = await SQLiteDB.sharedIfAvailable(lib.photosDB) {
            if await db.hasColumns("ZPERSON", ["ZFULLNAME"]) {
                // Merged-away duplicates repeat the name of the person they were merged into: skip them.
                let request = PageRequest(offset: 0, limit: each, search: q)
                let rows = (try? await PhotosStore.persons(lib, filter: .named, request: request)) ?? []
                for row in rows {
                    hits.append(SearchHit(id: "photos.person.\(row.id)", title: row.title, subtitle: "\(row.detection ?? 1 == 1 ? "Person" : "Pet") in Photos · \(Format.count(row.faces)) faces",
                                          moduleID: id, sectionID: "photos.people", payload: "person:\(row.id)", symbol: "person.crop.circle", sensitivity: .sensitive))
                }
            }
            if Task.isCancelled { return hits }
            if await db.hasColumns("ZMEMORY", ["ZTITLE", "ZSUBTITLE"]) {
                let rows = (try? await db.rows("SELECT Z_PK, ZTITLE, ZSUBTITLE FROM ZMEMORY WHERE ZTITLE LIKE ? OR ZSUBTITLE LIKE ? ORDER BY Z_PK DESC LIMIT ?", [like, like, .integer(Int64(each))])) ?? []
                for row in rows {
                    hits.append(SearchHit(id: "photos.memory.\(row[0].int ?? 0)", title: row[1].string ?? "Memory", subtitle: "Photos memory · \(row[2].string ?? "")",
                                          moduleID: id, sectionID: "photos.memories", payload: row[1].string ?? q, symbol: "sparkles.rectangle.stack", sensitivity: .personal))
                }
            }
            if Task.isCancelled { return hits }
            if await db.hasColumns("ZLEOLEXEME", ["ZCATEGORY", "ZCONTENT", "ZLEXEMETYPE"]) {
                // Index terms, excluding free text taken from the photos themselves (OCR, file names, descriptions).
                let hidden = SearchCategories.leo.filter { $0.value.reveal }.keys.map(String.init).joined(separator: ",")
                let rows = (try? await db.rows("SELECT Z_PK, ZCATEGORY, ZCONTENT FROM ZLEOLEXEME WHERE ZCONTENT LIKE ? AND ZLEXEMETYPE = 1 AND ZCATEGORY NOT IN (\(hidden.isEmpty ? "-1" : hidden)) AND ZCATEGORY NOT IN (8110, 1000) ORDER BY length(ZCONTENT) LIMIT ?", [like, .integer(Int64(each))])) ?? []
                for row in rows {
                    let code = Int(row[1].int ?? 0)
                    let info = SearchCategories.info(code, backend: .leo)
                    hits.append(SearchHit(id: "photos.term.\(row[0].int ?? 0)", title: row[2].string ?? "", subtitle: "Photos search index · \(info.name)",
                                          moduleID: id, sectionID: "photos.search", payload: "term:\(code):\(row[2].string ?? "")", symbol: "text.magnifyingglass", sensitivity: info.sensitivity))
                }
            }
        }
        if Task.isCancelled { return hits }
        if let url = lib.mediaAnalysisDB, let db = await SQLiteDB.sharedIfAvailable(url), await db.hasColumns("ZIMAGECAPTIONRESULT", ["ZCAPTION"]) {
            let n = await db.count("SELECT count(*) FROM ZIMAGECAPTIONRESULT WHERE ZCAPTION LIKE ?", [like]) ?? 0
            if n > 0 {
                hits.append(SearchHit(id: "photos.captions.\(q)", title: "\(Format.count(n)) photo captions mention “\(q)”", subtitle: "Machine-written captions · MediaAnalysis.sqlite",
                                      moduleID: id, sectionID: "photos.captions", payload: q, symbol: "text.bubble", sensitivity: .sensitive))
            }
        }
        if Task.isCancelled { return hits }
        if let (_, inf) = try? await PhotosCaches.shared.graph(for: lib) {
            for b in inf.businesses where b.name.localizedCaseInsensitiveContains(q) {
                hits.append(SearchHit(id: "photos.business.\(b.id)", title: b.name, subtitle: "Business visited (PhotosGraph) · \(b.categories.prefix(2).joined(separator: ", "))",
                                      moduleID: id, sectionID: "photos.graph", payload: "tab:events", symbol: "building.2", sensitivity: .sensitive))
                if hits.count >= limit { break }
            }
        }
        return Array(hits.prefix(limit))
    }

    // MARK: Self-test

    public func selfTest() async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        func timed<T>(_ label: String, _ work: () async throws -> T) async -> T? {
            let start = Date()
            do {
                let value = try await work()
                lines.append(.info("timing: \(label)", String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)))
                return value
            } catch {
                lines.append(.warn(label, (error as? LocalizedError)?.errorDescription ?? "\(error)"))
                return nil
            }
        }
        /// A store that is simply absent is a warning (nothing to show), not a failure of the module.
        func presence(_ label: String, _ present: Bool, _ detail: String) -> SelfTestLine {
            present ? .pass(label, detail) : .warn(label, detail)
        }
        guard let lib = PhotosLibraryLocator.current() else {
            return [.warn("Photos library", "no *.photoslibrary bundle found in ~/Pictures")]
        }
        lines.append(.info("library", "\(lib.root.lastPathComponent) (\(PhotosLibraryLocator.candidates().count) candidate(s))"))

        // Photos.sqlite
        let photosAvail = Paths.probe(lib.photosDB)
        lines.append(presence("Photos.sqlite readable", photosAvail.isAvailable, photosAvail.label))
        if photosAvail.isAvailable {
            if let s = await timed("summary", { try await PhotosStore.summary(lib) }) {
                lines.append(.check("ZASSET rows", s.assets > 0, "\(s.assets) assets (\(s.photos) photos, \(s.videos) videos), \(s.withLocation) with location, \(s.favorites) favourites, \(s.trashed) trashed, range \(DossierDate.range(s.range))"))
                lines.append(.pass("people", "\(s.personRows) ZPERSON rows = \(s.persons) clusters with faces + \(s.mergedPersons) merged away + \(s.facelessPersons) without faces; \(s.namedPersons) named people, \(s.namedPets) named pets; \(s.faces) faces, \(s.moments) moments, \(s.memories) memories, \(s.highlights) highlights, \(s.sceneClassifications) scene classifications"))
                lines.append(.pass("years", s.years.map { "\($0.year)=\($0.photos + $0.videos)" }.joined(separator: " ")))
                lines.append(.pass("coverage", s.coverage.map { "\($0.name)=\($0.done)" }.joined(separator: ", ")))
            }
            if let p = await timed("face profile (all faces)", { try await PhotosStore.faceProfile(lib, person: nil) }) {
                let age = p.distributions.first { $0.attribute.column == "ZAGETYPE" }?.counts.map { "\($0.code)=\($0.count)" }.joined(separator: " ") ?? "—"
                lines.append(.check("face attributes", !p.distributions.isEmpty, "\(p.faces) faces on \(p.assets) assets, \(p.distributions.count) coded attributes; ZAGETYPE \(age)"))
            }
            if let cells = await timed("location grid", { try await PhotosStore.locationGrid(lib) }) {
                lines.append(.pass("location grid", "\(cells.count) cells covering \(cells.reduce(0) { $0 + $1.count }) assets"))
            }
            if let trips = await timed("trips", { try await PhotosStore.trips(lib) }) {
                lines.append(.pass("trips", "\(trips.count) day-group highlights (\(trips.filter { $0.typeCode == 1 }.count) long, \(trips.filter { $0.typeCode == 2 }.count) short)"))
            }
            if let n = await ReverseGeoStore.archiveCount(lib), n > 0 {
                if let page = await timed("reverse-geocode page (200 archives decoded)", { try await ReverseGeoStore.rows(lib, only: nil, request: PageRequest(offset: 0, limit: 200)) }) {
                    lines.append(.check("reverse-geocode page", page.count == min(200, n) && page.allSatisfy(\.decoded), "\(page.count) rows, \(page.filter { !$0.address.isEmpty }.count) with an address, \(page.filter(\.isHome).count) at home"))
                    if let last = page.last, let next = try? await ReverseGeoStore.rows(lib, only: nil, request: PageRequest(offset: page.count, limit: 200, cursor: AnyHashable(last.id))) {
                        let overlap = Set(page.map(\.id)).intersection(next.map(\.id)).count
                        let ordered = (page + next).compactMap(\.date) == (page + next).compactMap(\.date).sorted(by: >)
                        lines.append(.check("reverse-geocode keyset paging", overlap == 0 && ordered, "second page \(next.count) rows, \(overlap) overlapping, newest first: \(ordered)"))
                    }
                }
                let flags = await timed("reverse-geocode at-home flags (all archives, flag only)", { try await ReverseGeoCache.shared.homeFlags(lib) })
                if let flags {
                    lines.append(.check("reverse-geocode at-home flags", flags.checked == flags.total && flags.total == n, "\(flags.total) archives, \(flags.checked) flags read, \(flags.home.count) flagged at home"))
                }
                if let index = await timed("reverse-geocode index (all archives)", { try await ReverseGeoCache.shared.index(lib) }) {
                    lines.append(.check("reverse-geocode archives", index.decoded == index.total && index.total == n, "\(index.total) archives, \(index.decoded) decoded, \(index.withStreet) with a street, \(index.addresses.count) with an address line, \(index.home.count) flagged at home"))
                    if let flags {
                        lines.append(.check("at-home flags agree with full decode", Set(flags.home) == Set(index.home), "quick pass \(flags.home.count), full decode \(index.home.count)"))
                    }
                }
            } else {
                lines.append(.warn("reverse-geocode archives", "no ZREVERSELOCATIONDATA in this library"))
            }
            if let m = await timed("memory stats", { try await PhotosStore.memoryStats(lib) }) {
                lines.append(.pass("memories", "\(m.total) memories, \(m.played) played, \(m.favorites) favourite, \(m.rejected) rejected, \(m.pending) pending, created \(DossierDate.range(m.range)); kinds \(m.kinds.prefix(5).map { "\($0.name)=\($0.count)" }.joined(separator: ", "))"))
            }
            if let sh = await timed("sharing stats", { try await PhotosStore.sharing(lib) }) {
                lines.append(.pass("sharing", "\(sh.totalViews) views, \(sh.totalPlays) plays, \(sh.totalShares) shares, \(sh.viewedAssets) viewed assets, \(sh.sharedLibraryAssets) shared-library assets, \(sh.participants.count) participants, \(sh.shares.count) shares, \(sh.comments) comments, \(sh.likes) likes"))
            }
        }

        // Search index
        let backends = await SearchIndexStore.availableBackends(lib)
        lines.append(presence("search index present", !backends.isEmpty, backends.isEmpty ? "none" : backends.map(\.rawValue).joined(separator: ", ")))
        for backend in backends {
            if let s = await timed("search index (\(backend.rawValue))", { try await SearchIndexStore.stats(lib, backend: backend) }) {
                lines.append(.check("search index \(backend.rawValue)", s.terms > 0, "\(s.items) items, \(s.categories.count) categories, \(s.terms) terms, \(s.links) term–asset links, OCR: \(s.ocrAssets) assets / \(s.ocrTokens) tokens, range \(DossierDate.range(s.range))"))
                if let countries = try? await SearchIndexStore.topTerms(lib, backend: backend, category: backend.countryCode, limit: 3) {
                    lines.append(.pass("search index \(backend.rawValue) countries", "top counts \(countries.map { String($0.count) }.joined(separator: ", "))"))
                }
            }
        }

        // PhotosGraph
        let graphURL = lib.graphDB
        lines.append(presence("photosgraph.kgdb found", graphURL != nil, graphURL.map { Format.tildePath($0) } ?? "not present"))
        if graphURL != nil, let (g, inf) = await timed("graph load + inferences", { try await PhotosCaches.shared.graph(for: lib) }) {
            lines.append(.check("graph bitmaps decode", g.bitmapsValid, "\(g.labelNames.count) labels"))
            lines.append(.check("graph", inf.nodeCount > 0, "\(inf.nodeCount) nodes, \(inf.edgeCount) edges (\(inf.sceneEdges) scene), \(inf.momentCount) moments \(DossierDate.range(inf.momentRange))"))
            lines.append(.pass("graph inferences", "\(inf.people.count) people, \(inf.relationships.count) relationships, \(inf.places.count) home/work addresses, \(inf.frequent.count) frequent locations, \(inf.groups.count) social groups, \(inf.pets.count) pets, \(inf.businesses.count) businesses, \(inf.events.count) public events, \(inf.meanings.reduce(0) { $0 + $1.count }) meaning edges, \(inf.taboo.reduce(0) { $0 + $1.moments }) taboo edges, \(inf.languages.count) languages, trips \(inf.longTrips) long / \(inf.shortTrips) short"))
        }

        // MediaAnalysis
        let mediaURL = lib.mediaAnalysisDB
        lines.append(presence("MediaAnalysis.sqlite found", mediaURL != nil, mediaURL.map { Format.tildePath($0) } ?? "not present"))
        let caps = await CaptionStore.stats(lib)
        lines.append(.pass("captions", CaptionSource.allCases.map { "\($0.rawValue)=\(caps.counts[$0] ?? 0)" }.joined(separator: ", ") + ", unsafe=\(caps.unsafeImages), OCR archives=\(caps.ocrBlobs)"))
        for source in CaptionSource.allCases where (caps.counts[source] ?? 0) > 0 {
            if let rows = await timed("captions page (\(source.rawValue))", { try await CaptionStore.rows(lib, source: source, request: PageRequest(offset: 0, limit: 200)) }) {
                lines.append(.check("captions page \(source.rawValue)", !rows.isEmpty, "\(rows.count) rows"))
            }
        }
        return lines
    }
}
