import Foundation
import DossierCore

// What the PhotosGraph has concluded, flattened into display models.
// Relation labels used (all observed in real graphs):
//   People:   Me -[FRIEND|FAMILY|PARTNER|COWORKER …]-> People (confidence + feature signals on the edge),
//             Me -[INFERRED_TO]-> People (which face cluster the owner is), People -[RELATIONSHIP_TAG]-> tag,
//             People -[PRESENT]-> Moment, People -[BELONGSTO]-> SocialGroup, People -[PRACTICES_ACTIVITY]-> activity
//   Places:   Address -[IS_HOME_WORK]-> Home|Work -[IS_OWNED_BY]-> person, FrequentLocation -[AT]-> Address,
//             Moment -[IN]-> FrequentLocation, Moment -[ADDRESS]-> Address, Moment -[BUSINESS]-> Business -[BUSINESSCATEGORY]-> category,
//             Moment -[PUBLIC_EVENT]-> PublicEvent -[PERFORMER|CATEGORY|LOCALIZED_SUBCATEGORY]-> …
//   Meaning:  Moment -[MEANING]-> meaning, Moment -[TABOO]-> taboo class, Moment -[MOBILITY|POI|ROI]-> …,
//             Moment -[CELEBRATING]-> Holiday, Country -[POPULAR_LANGUAGE]-> Language,
//             HighlightGroup -[HAS_TYPE]-> LongTrip|ShortTrip, Pet -[PET_IS_PRESENT]-> Moment, Me -[IS_OWNER_OF]-> Pet.

struct GKeyValue: Sendable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let value: String
}

struct GCount: Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let count: Int
    var detail: String = ""
    var extra: Double? = nil
}

struct GPerson: Sendable, Identifiable, Hashable {
    let id: Int32
    let name: String
    let uuid: String
    let isMe: Bool
    let favorite: Bool
    let userCreated: Bool
    let hasContact: Bool
    let sexCode: Int?
    let ageCategory: Int?
    let birthday: Date?
    let moments: Int
    let assets: Int
    let authored: Int
    let relationships: [String]
    let tags: [String]
    let activities: [String]
    let groups: Int
}

struct GRelationship: Sendable, Identifiable, Hashable {
    let id: Int32
    let person: String
    let personUUID: String
    let type: String
    /// Confidence of the scored edge (people domain), if the graph stored one.
    let confidence: Double?
    let signals: [GKeyValue]
    /// A second, attribute-less edge with the same label exists in the relationship domain:
    /// the graph adopted this relationship (it is what memories and titles use).
    let adopted: Bool
}

struct GPlace: Sendable, Identifiable, Hashable {
    let id: String
    let kind: String            // Home / Work
    let owner: String
    let address: String
    let latitude: Double?
    let longitude: Double?
    let moments: Int
}

struct GFrequentLocation: Sendable, Identifiable, Hashable {
    let id: Int32
    let address: String
    let latitude: Double?
    let longitude: Double?
    let start: Date?
    let end: Date?
    let moments: Int
}

struct GGroup: Sendable, Identifiable, Hashable {
    let id: Int32
    let members: [String]
    let memberImportance: [Double]
    let moments: Int
    let importance: Double?
    let userVerified: Bool
}

struct GPet: Sendable, Identifiable, Hashable {
    let id: Int32
    let name: String
    let speciesCode: Int?
    let moments: Int
    let owner: String
}

struct GBusiness: Sendable, Identifiable, Hashable {
    let id: Int32
    let name: String
    let categories: [String]
    let latitude: Double?
    let longitude: Double?
    let visits: Int
    let first: Date?
    let last: Date?
    let venueCapacity: Int?
}

struct GEvent: Sendable, Identifiable, Hashable {
    let id: Int32
    let name: String
    let performers: [String]
    let categories: [String]
    let venue: String
    let date: Date?
}

struct GTaboo: Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let typeCode: Int?
    let moments: Int
    let assets: Int
    let maxConfidence: Double?
}

struct GLanguage: Sendable, Identifiable, Hashable {
    var id: String { locale }
    let locale: String
    let countries: [String]
}

struct GDomain: Sendable, Identifiable, Hashable {
    var id: Int { code }
    let code: Int
    let name: String
    let nodes: Int
    let kinds: String
}

struct GraphInferences: Sendable {
    var url: URL
    var nodeCount = 0
    var edgeCount = 0
    var labelCount = 0
    var sceneEdges = 0
    var momentCount = 0
    var momentRange: ClosedRange<Date>?
    var domains: [GDomain] = []
    var edgeLabels: [GCount] = []
    var info: [GKeyValue] = []
    var meName: String?
    var meHasContact = false
    var meInferredPerson: String?
    var people: [GPerson] = []
    var relationships: [GRelationship] = []
    var places: [GPlace] = []
    var frequent: [GFrequentLocation] = []
    var groups: [GGroup] = []
    var pets: [GPet] = []
    var businesses: [GBusiness] = []
    var events: [GEvent] = []
    var meanings: [GCount] = []
    var activities: [GCount] = []
    var taboo: [GTaboo] = []
    var languages: [GLanguage] = []
    var mobility: [GCount] = []
    var pois: [GCount] = []
    var rois: [GCount] = []
    var holidays: [GCount] = []
    var scenes: [GCount] = []
    var memoryTypes: [GCount] = []
    var addresses: [GPlace] = []
    var longTrips = 0
    var shortTrips = 0
    var sceneNames: [Int: String] = [:]
    /// Coordinates of address nodes with the country / city the graph files them under (used to name map areas).
    var geo: [GeoName] = []
}

struct GeoName: Sendable, Hashable {
    let latitude: Double
    let longitude: Double
    let country: String
    let city: String
}

extension GraphInferences {
    static func build(from g: PhotosGraph) async -> GraphInferences {
        var r = GraphInferences(url: g.url)
        r.nodeCount = g.nodeCount
        r.edgeCount = g.edgeCount
        r.labelCount = g.labelNames.count
        r.sceneEdges = g.sceneMoments.values.reduce(0, +)

        // Domains
        var byDomain: [Int: (nodes: Int, kinds: [String: Int])] = [:]
        for (node, d) in g.nodeDomain {
            var entry = byDomain[d] ?? (0, [:])
            entry.nodes += 1
            if let k = g.nodeKinds[node]?.first { entry.kinds[k, default: 0] += 1 }
            byDomain[d] = entry
        }
        r.domains = byDomain.map { code, e in
            let top = e.kinds.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(5).map(\.key)
            let more = e.kinds.count > 5 ? " +\(e.kinds.count - 5)" : ""
            return GDomain(code: code, name: GraphDomains.name(code), nodes: e.nodes, kinds: top.joined(separator: ", ") + more)
        }.sorted { $0.code < $1.code }

        var perLabel: [Int32: Int] = [:]
        for e in g.edges { perLabel[e.label, default: 0] += 1 }
        r.edgeLabels = perLabel.map { GCount(name: g.labelNames[$0.key] ?? "?", count: $0.value) }
        if r.sceneEdges > 0 { r.edgeLabels.append(GCount(name: "SCENE", count: r.sceneEdges)) }
        r.edgeLabels.sort { $0.count > $1.count }

        // Moments
        let moments = g.nodes(domain: 100)
        r.momentCount = moments.count
        var lo: Date?, hi: Date?
        for m in moments {
            if let s = graphDate(g.attr(m, "utcs")?.double) { lo = lo.map { min($0, s) } ?? s }
            if let e = graphDate(g.attr(m, "utce")?.double) { hi = hi.map { max($0, e) } ?? e }
        }
        if let lo, let hi, lo <= hi { r.momentRange = lo...hi }
        func momentDate(_ m: Int32) -> Date? { graphDate(g.attr(m, "utcs")?.double) }

        // Info node
        if let info = g.nodes(domain: 21).first, let values = g.attrs[info] {
            r.info = values.keys.sorted().map { key in
                var text = values[key]!.display
                if key.lowercased().contains("date"), let d = graphDate(values[key]!.double) { text = DossierDate.medium(d) }
                return GKeyValue(key: key, value: text)
            }
        }

        // People
        let personNodes = g.nodes(domain: 300)
        let meNode = personNodes.first { (g.nodeKinds[$0] ?? []).contains("Me") }
        func personUUID(_ n: Int32) -> String {
            let raw = g.string(n, "id") ?? ""
            return raw.split(separator: "/").first.map(String.init) ?? raw
        }
        func personName(_ n: Int32) -> String {
            let name = g.string(n, "name") ?? ""
            if !name.isEmpty { return name }
            return n == meNode ? "Me" : "Unnamed person"
        }
        if let me = meNode {
            r.meName = g.string(me, "name")
            r.meHasContact = !(g.string(me, "cnid") ?? "").isEmpty
            r.meInferredPerson = g.out(me, "INFERRED_TO").first.map { personName($0.target) }
        }

        let relationLabels: Set<String> = Set(g.edges.compactMap { e -> String? in
            guard let me = meNode, e.source == me, g.nodeDomain[e.target] == 300 else { return nil }
            let l = g.label(e)
            return l == "INFERRED_TO" ? nil : l
        })
        var relationEdges: [KGEdge] = []
        if let me = meNode {
            relationEdges = (g.outgoing[me] ?? []).map { g.edges[Int($0)] }.filter { relationLabels.contains(g.label($0)) }
        }
        let tagEdges = g.edges(labelled: "RELATIONSHIP_TAG")
        let presentEdges = g.edges(labelled: "PRESENT")
        let relValues = await g.edgeValues(relationEdges.map(\.id) + tagEdges.map(\.id) + presentEdges.map(\.id))

        let signalNames: [String: String] = [
            "relsource": "Source code", "relstatus": "Status code", "gwnummmtshome": "Moments together at home",
            "ragediff": "Age difference signal", "rcal": "Calendar signal", "rchild": "Child signal", "rfamhol": "Family-holiday signal",
            "rfamnam": "Same family name", "rfrfamtrip": "Friends & family trip signal", "rfrndnghtout": "Night-out signal",
            "rhasanniv": "Has anniversary", "rlovexch": "Love-exchange signal", "rold": "Old-relationship signal",
            "rparnam": "Parent-name signal", "rprtnrtrip": "Partner-trip signal", "rtop": "Top person", "rtop2sg": "Top two-person group",
            "rwkend": "Weekend signal", "rwork": "Work signal",
        ]
        // The graph stores up to two edges per (person, type): a scored one in the people domain (300)
        // with confidence and signals, and an attribute-less one in a separate relationship domain.
        var merged: [String: (edge: KGEdge, scored: KGEdge?, adopted: Bool)] = [:]
        var order: [String] = []
        for e in relationEdges {
            let key = "\(e.target)|\(e.label)"
            var entry = merged[key] ?? (e, nil, false)
            if merged[key] == nil { order.append(key) }
            if relValues[e.id]?["confidence"] != nil || e.domain == 300 { entry.scored = e } else { entry.adopted = true }
            merged[key] = entry
        }
        r.relationships = order.compactMap { merged[$0] }.map { entry in
            let e = entry.scored ?? entry.edge
            let v = relValues[e.id] ?? [:]
            let signals = v.keys.filter { $0 != "confidence" }.sorted().map { key in
                GKeyValue(key: signalNames[key].map { "\($0) [\(key)]" } ?? key, value: v[key]!.display)
            }
            return GRelationship(id: e.id, person: personName(e.target), personUUID: personUUID(e.target), type: g.label(e).capitalized,
                                 confidence: v["confidence"]?.double, signals: signals, adopted: entry.adopted)
        }.sorted { a, b in
            if (a.confidence ?? -1) != (b.confidence ?? -1) { return (a.confidence ?? -1) > (b.confidence ?? -1) }
            return a.person < b.person
        }

        var relByPerson: [Int32: [String]] = [:]
        for e in relationEdges where !(relByPerson[e.target] ?? []).contains(g.label(e).capitalized) { relByPerson[e.target, default: []].append(g.label(e).capitalized) }
        var tagsByPerson: [Int32: [String]] = [:]
        for e in tagEdges {
            let conf = relValues[e.id]?["confidence"]?.double
            tagsByPerson[e.source, default: []].append(g.kind(e.target) + (conf.map { " (\(Format.percent($0, digits: 0)))" } ?? ""))
        }
        var presentByPerson: [Int32: (moments: Int, assets: Int)] = [:]
        for e in presentEdges {
            var entry = presentByPerson[e.source] ?? (0, 0)
            entry.moments += 1
            entry.assets += Int(relValues[e.id]?["numberOfAssets"]?.int ?? 0)
            presentByPerson[e.source] = entry
        }
        var authored: [Int32: Int] = [:]
        for e in g.edges(labelled: "AUTHOR") { authored[e.source, default: 0] += 1 }
        var groupsByPerson: [Int32: Int] = [:]
        for e in g.edges(labelled: "BELONGSTO") { groupsByPerson[e.source, default: 0] += 1 }
        var activitiesByPerson: [Int32: [String]] = [:]
        for e in g.edges(labelled: "PRACTICES_ACTIVITY") { activitiesByPerson[e.source, default: []].append(Self.spaced(g.kind(e.target))) }

        r.people = personNodes.map { n in
            GPerson(
                id: n, name: personName(n), uuid: personUUID(n), isMe: n == meNode,
                favorite: (g.attr(n, "fav")?.int ?? 0) != 0, userCreated: (g.attr(n, "usercreated")?.int ?? 0) != 0,
                hasContact: !(g.string(n, "cnid") ?? "").isEmpty,
                sexCode: g.attr(n, "sex")?.int.map(Int.init), ageCategory: g.attr(n, "agecategory")?.int.map(Int.init),
                birthday: graphDate(g.attr(n, "bday")?.double),
                moments: presentByPerson[n]?.moments ?? 0, assets: presentByPerson[n]?.assets ?? 0, authored: authored[n] ?? 0,
                relationships: relByPerson[n] ?? [], tags: tagsByPerson[n] ?? [], activities: activitiesByPerson[n] ?? [],
                groups: groupsByPerson[n] ?? 0)
        }.sorted { ($0.isMe ? 1 : 0, $0.moments) > ($1.isMe ? 1 : 0, $1.moments) }

        // Home / work
        var addressMoments: [Int32: Int] = [:]
        for e in g.edges(labelled: "ADDRESS") { addressMoments[e.target, default: 0] += 1 }
        for hw in g.nodes(domain: 202) {
            let kind = g.kind(hw)
            let owner = g.out(hw, "IS_OWNED_BY").first.map { personName($0.target) } ?? "Unknown owner"
            let addresses = g.into(hw, "IS_HOME_WORK").map(\.source)
            if addresses.isEmpty {
                r.places.append(GPlace(id: "\(hw)", kind: kind, owner: owner, address: "No address linked", latitude: nil, longitude: nil, moments: 0))
            }
            for a in addresses {
                let c = g.coordinate(a)
                r.places.append(GPlace(id: "\(hw)-\(a)", kind: kind, owner: owner, address: g.addressText(a), latitude: c?.lat, longitude: c?.lon, moments: addressMoments[a] ?? 0))
            }
        }
        r.places.sort { ($0.kind, $1.moments) < ($1.kind, $0.moments) }

        // Frequent locations
        for f in g.nodes(domain: 204) {
            let address = g.out(f, "AT").first?.target
            let c = address.flatMap { g.coordinate($0) }
            r.frequent.append(GFrequentLocation(
                id: f, address: address.map { g.addressText($0) } ?? "Unknown address", latitude: c?.lat, longitude: c?.lon,
                start: graphDate(g.attr(f, "universalStartDate")?.double), end: graphDate(g.attr(f, "universalEndDate")?.double),
                moments: g.into(f, "IN").count))
        }
        r.frequent.sort { $0.moments > $1.moments }

        // Top addresses by number of moments
        r.addresses = addressMoments.sorted { $0.value > $1.value }.prefix(60).map { node, count in
            let c = g.coordinate(node)
            return GPlace(id: "a\(node)", kind: "Address", owner: "", address: g.addressText(node), latitude: c?.lat, longitude: c?.lon, moments: count)
        }

        for a in g.nodes(domain: 200, kind: "Address") {
            guard let c = g.coordinate(a) else { continue }
            let parts = g.addressParts(a)
            if !parts.country.isEmpty || !parts.city.isEmpty { r.geo.append(GeoName(latitude: c.lat, longitude: c.lon, country: parts.country, city: parts.city)) }
        }

        // Social groups
        let belongs = g.edges(labelled: "BELONGSTO")
        let belongValues = await g.edgeValues(belongs.map(\.id))
        for sg in g.nodes(domain: 302) {
            let members = belongs.filter { $0.target == sg }
                .map { (personName($0.source), belongValues[$0.id]?["importance"]?.double ?? 0) }
                .sorted { $0.1 > $1.1 }
            r.groups.append(GGroup(id: sg, members: members.map(\.0), memberImportance: members.map(\.1), moments: g.into(sg, "SOCIALGROUP").count,
                                   importance: g.attr(sg, "importance")?.double, userVerified: (g.attr(sg, "isUserVerified")?.int ?? 0) != 0))
        }
        r.groups.sort { $0.moments > $1.moments }

        // Pets
        for p in g.nodes(domain: 304) {
            let owner = g.into(p, "IS_OWNER_OF").first.map { personName($0.source) } ?? ""
            r.pets.append(GPet(id: p, name: g.string(p, "name") ?? "Unnamed pet", speciesCode: g.attr(p, "anml")?.int.map(Int.init),
                               moments: g.out(p, "PET_IS_PRESENT").count, owner: owner))
        }

        // Businesses
        let businessEdges = g.edges(labelled: "BUSINESS")
        let businessValues = await g.edgeValues(businessEdges.map(\.id))
        for b in g.nodes(domain: 503) {
            let visits = businessEdges.filter { $0.target == b }
            var first: Date?, last: Date?
            for v in visits {
                let s = graphDate(businessValues[v.id]?["universalStartDate"]?.double) ?? momentDate(v.source)
                let e = graphDate(businessValues[v.id]?["universalEndDate"]?.double) ?? s
                if let s { first = first.map { min($0, s) } ?? s }
                if let e { last = last.map { max($0, e) } ?? e }
            }
            let c = g.coordinate(b)
            let capacity = g.attr(b, "venueCapacity")?.int.flatMap { $0 > 0 && $0 < 10_000_000 ? Int($0) : nil }
            r.businesses.append(GBusiness(id: b, name: g.name(b), categories: g.out(b, "BUSINESSCATEGORY").map { g.kind($0.target) }.sorted(),
                                          latitude: c?.lat, longitude: c?.lon, visits: visits.count, first: first, last: last, venueCapacity: capacity))
        }
        r.businesses.sort { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }

        // Public events
        for ev in g.nodes(domain: 900, kind: "PublicEvent") {
            let moment = g.into(ev, "PUBLIC_EVENT").first?.source
            r.events.append(GEvent(
                id: ev, name: g.name(ev), performers: g.out(ev, "PERFORMER").map { g.name($0.target) },
                categories: (g.out(ev, "CATEGORY").map { g.string($0.target, "lcln") ?? g.kind($0.target) } + g.out(ev, "LOCALIZED_SUBCATEGORY").map { g.kind($0.target) }),
                venue: g.out(ev, "PUBLIC_EVENT_BUSINESS").first.map { g.name($0.target) } ?? "",
                date: moment.flatMap(momentDate)))
        }
        r.events.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        // Meanings
        let meaningEdges = g.edges(labelled: "MEANING")
        let meaningValues = await g.edgeValues(meaningEdges.map(\.id))
        var meaning: [Int32: (n: Int, hp: Int, conf: Double)] = [:]
        for e in meaningEdges {
            var m = meaning[e.target] ?? (0, 0, 0)
            m.n += 1
            m.hp += (meaningValues[e.id]?["isHighPrecision"]?.int ?? 0) != 0 ? 1 : 0
            m.conf += meaningValues[e.id]?["confidence"]?.double ?? 0
            meaning[e.target] = m
        }
        r.meanings = meaning.map { node, m in
            let parent = g.out(node, "SUBMEANING_OF").first.map { Self.spaced(g.kind($0.target)) }
            return GCount(name: Self.spaced(g.kind(node)), count: m.n,
                          detail: "\(m.hp) high-precision" + (parent.map { " · part of \($0)" } ?? ""), extra: m.n > 0 ? m.conf / Double(m.n) : nil)
        }.sorted { $0.count > $1.count }

        var activity: [String: Int] = [:]
        for e in g.edges(labelled: "PERSON_ACTIVITY_MEANING") { activity[Self.spaced(g.kind(e.target)), default: 0] += 1 }
        r.activities = activity.map { GCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }

        // Taboo
        let tabooEdges = g.edges(labelled: "TABOO")
        let tabooValues = await g.edgeValues(tabooEdges.map(\.id))
        for t in g.nodes(domain: 1300) {
            let mine = tabooEdges.filter { $0.target == t }
            let assets = mine.reduce(0) { $0 + Int(tabooValues[$1.id]?["numberOfTabooAssets"]?.int ?? 0) }
            let conf = mine.compactMap { tabooValues[$0.id]?["confidence"]?.double }.max()
            r.taboo.append(GTaboo(name: Self.spaced(g.kind(t)), typeCode: g.attr(t, "tabooType")?.int.map(Int.init), moments: mine.count, assets: assets, maxConfidence: conf))
        }
        r.taboo.sort { $0.moments > $1.moments }

        // Languages
        for l in g.nodes(domain: 205) {
            let countries = g.into(l, "POPULAR_LANGUAGE").map { PhotosGraph.regionName(g.name($0.source)) }.sorted()
            r.languages.append(GLanguage(locale: g.string(l, "localeIdentifier") ?? g.name(l), countries: countries))
        }
        r.languages.sort { $0.countries.count > $1.countries.count }

        func countByTarget(_ label: String) -> [GCount] {
            var counts: [Int32: Int] = [:]
            for e in g.edges(labelled: label) { counts[e.target, default: 0] += 1 }
            return counts.map { GCount(name: Self.spaced(g.name($0.key)), count: $0.value) }.sorted { $0.count > $1.count }
        }
        r.mobility = countByTarget("MOBILITY")
        r.pois = countByTarget("POI")
        r.rois = countByTarget("ROI")
        r.holidays = countByTarget("CELEBRATING")

        // Scenes: number of moments per scene label
        var sceneNames: [Int: String] = [:]
        for d in [600, 603] {
            for n in g.nodes(domain: d) {
                if let sid = g.attr(n, "sceneIdentifier")?.int, let name = g.string(n, "localizedName") { sceneNames[Int(sid)] = name }
            }
        }
        r.sceneNames = sceneNames
        r.scenes = g.sceneMoments.sorted { $0.value > $1.value }.prefix(60).map { node, count in
            GCount(name: g.string(node, "localizedName") ?? g.kind(node), count: count, detail: "level \(g.attr(node, "level")?.int ?? 0)")
        }

        // Memories by type, trips
        var memory: [String: Int] = [:]
        for n in g.nodes(domain: 1100) { memory[Self.spaced(g.kind(n)), default: 0] += 1 }
        r.memoryTypes = memory.map { GCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        for e in g.edges(labelled: "HAS_TYPE") {
            switch g.kind(e.target) {
            case "LongTrip": r.longTrips += 1
            case "ShortTrip": r.shortTrips += 1
            default: break
            }
        }
        return r
    }

    /// "PersonActionHugging" → "Person Action Hugging"
    static func spaced(_ camel: String) -> String {
        guard !camel.contains(" "), camel.count > 3 else { return camel }
        var out = ""
        var previousLower = false
        for ch in camel {
            if ch.isUppercase && previousLower { out.append(" ") }
            out.append(ch == "_" ? " " : ch)
            previousLower = ch.isLowercase
        }
        return out
    }
}

/// Module-wide caches (graph skeleton, search-index statistics). Invalidated by Refresh and library changes.
actor PhotosCaches {
    static let shared = PhotosCaches()

    private var graphs: [String: (stamp: Date?, graph: PhotosGraph, inferences: GraphInferences)] = [:]
    private var loading: [String: Task<(PhotosGraph, GraphInferences), Error>] = [:]
    private var token = 0
    var searchStats: [String: SearchIndexStats] = [:]

    func reset() async {
        graphs.removeAll()
        loading.removeAll()
        searchStats.removeAll()
        PhotosLibraryLocator.resetDiscovery()
        await LeoTermCache.shared.reset()
        await ReverseGeoCache.shared.reset()
    }

    func sync(token newToken: Int) async {
        if newToken != token { token = newToken; await reset() }
    }

    func setSearchStats(_ stats: SearchIndexStats, key: String) { searchStats[key] = stats }
    func cachedSearchStats(_ key: String) -> SearchIndexStats? { searchStats[key] }

    func graph(for library: PhotosLibrary) async throws -> (PhotosGraph, GraphInferences) {
        guard let url = library.graphDB else {
            throw DossierError.missing("No photosgraph.kgdb was found under \(Format.tildePath(library.photoAnalysisDirectory)). Photos builds it after the library has been analysed.")
        }
        switch Paths.probe(url) {
        case .missing: throw DossierError.missing("photosgraph.kgdb does not exist in this library.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached = graphs[url.path], cached.stamp == stamp { return (cached.graph, cached.inferences) }
        if let running = loading[url.path] { return try await running.value }
        let task = Task<(PhotosGraph, GraphInferences), Error> {
            let graph = try await PhotosGraph.load(url)
            let inferences = await GraphInferences.build(from: graph)
            return (graph, inferences)
        }
        loading[url.path] = task
        defer { loading[url.path] = nil }
        let value = try await task.value
        graphs[url.path] = (stamp, value.0, value.1)
        return value
    }
}
