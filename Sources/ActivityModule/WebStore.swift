import DossierCore
import Foundation

/// One interval of web usage (a page in front in Safari).
struct WebVisit: Identifiable, Sendable {
    let id: Int
    let source: String
    let start: Date
    let end: Date?
    let domain: String
    let url: String
    let bundle: String
    let detail: String
    var duration: Double { end.map { max(0, $0.timeIntervalSince(start)) } ?? 0 }
}

struct WebDomain: Identifiable, Sendable {
    var id: String { domain }
    let domain: String
    var seconds: Double = 0
    var visits = 0
    var urls = Set<String>()
    var last: Date?
}

struct WebHistory: Sendable {
    /// knowledgeC `/app/webUsage` intervals (the Screen Time record).
    var knowledge: [WebVisit] = []
    /// Biome `App.WebUsage` events paired per tab session.
    var biome: [WebVisit] = []
    /// Biome `Safari.Navigations` records.
    var navigations: [WebVisit] = []
    var searchEngines: [String] = []
    var pageLoads = 0
    var domains: [WebDomain] = []
    var streamCounts: [String: Int] = [:]
    var timeRange: ClosedRange<Date>?
    var knowledgeAvailable = false

    var all: [WebVisit] { knowledge + biome + navigations }
    var totalSeconds: Double { (knowledge.isEmpty ? biome : knowledge).reduce(0) { $0 + $1.duration } }
}

extension ActivityStore {
    /// Loads the three web-usage records the system keeps. All of them cover **Safari
    /// only** (and web views that opt into Screen Time reporting): other browsers appear in
    /// app usage, but their pages are not recorded here.
    ///
    /// * `App.WebUsage` — 1 tab-session UUID, 2 timestamp (Cocoa), 3 usage state (2 and 3 =
    ///   in use, 1 = ended; verified by reproducing knowledgeC's intervals), 4 URL, 5 domain,
    ///   6 bundle id.
    /// * `Safari.Navigations` — 1 registrable domain, 2 timestamp (Unix, coarsened),
    ///   5 region code, 8 URL.
    /// * `Safari.SearchEngine` — 1 search provider identifier.
    func web() async -> WebHistory {
        if let webCache { return webCache }
        let t0 = Date()
        var history = WebHistory()
        var id = 0

        if let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC),
           await db.hasColumns("ZOBJECT", ["ZSTREAMNAME", "ZSTARTDATE", "ZENDDATE", "ZVALUESTRING", "ZSTRUCTUREDMETADATA"]) {
            history.knowledgeAvailable = true
            let meta = await db.columnNames(of: "ZSTRUCTUREDMETADATA")
            let domainCol = "Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN", urlCol = "Z_DKDIGITALHEALTHMETADATAKEY__WEBPAGEURL"
            let domainExpr = meta.contains(domainCol.lowercased()) ? "m.\(domainCol)" : "NULL"
            let urlExpr = meta.contains(urlCol.lowercased()) ? "m.\(urlCol)" : "NULL"
            if let rows = try? await db.rows("""
                SELECT o.ZSTARTDATE, o.ZENDDATE, o.ZVALUESTRING, \(domainExpr), \(urlExpr)
                FROM ZOBJECT o LEFT JOIN ZSTRUCTUREDMETADATA m ON m.Z_PK = o.ZSTRUCTUREDMETADATA
                WHERE o.ZSTREAMNAME = '/app/webUsage' ORDER BY o.ZSTARTDATE DESC LIMIT 100000
                """, maxRows: 100_000) {
                for r in rows {
                    guard let start = r[0].cocoaDate else { continue }
                    let url = r[4].string ?? ""
                    let domain = r[3].string ?? URL(string: url)?.host ?? ""
                    history.knowledge.append(WebVisit(id: id, source: "knowledgeC", start: start, end: r[1].cocoaDate, domain: domain, url: url, bundle: r[2].string ?? "", detail: "Screen Time interval"))
                    id += 1
                }
            }
        }

        if let stream = Biome.stream(named: "App.WebUsage") {
            var open: [String: (start: Date, url: String, domain: String, bundle: String, state: Int)] = [:]
            var count = 0
            BiomeStreamReader(stream).forEach(order: .oldestFirst) { record in
                var session = "", url = "", domain = "", bundle = ""
                var state = 0
                var time: Double?
                FastProto.scan(record.payload) { field, value in
                    switch (field, value) {
                    case (1, .bytes(let r)): session = FastProto.string(r)
                    case (2, .fixed64(let bits)): time = FastProto.double(bits)
                    case (3, .varint(let v)): state = Int(v)
                    case (4, .bytes(let r)): url = FastProto.string(r)
                    case (5, .bytes(let r)): domain = FastProto.string(r)
                    case (6, .bytes(let r)): bundle = FastProto.string(r)
                    default: break
                    }
                }
                guard !record.payload.isEmpty else { return true }
                count += 1
                let date = time.map(DossierDate.cocoa) ?? record.timestamp
                if let o = open.removeValue(forKey: session), date >= o.start {
                    let end = min(date, o.start.addingTimeInterval(FocusPairer.maxSession))
                    history.biome.append(WebVisit(id: id, source: "Biome", start: o.start, end: end, domain: o.domain, url: o.url, bundle: o.bundle, detail: "Usage state \(o.state)"))
                    id += 1
                }
                if state == 2 || state == 3 { open[session] = (date, url, domain, bundle, state) }
                return true
            }
            history.streamCounts["App.WebUsage"] = count
        }

        if let stream = Biome.stream(named: "Safari.Navigations") {
            var count = 0
            BiomeStreamReader(stream).forEach(order: .oldestFirst) { record in
                guard !record.payload.isEmpty else { return true }
                var url = "", domain = "", region = ""
                FastProto.scan(record.payload) { field, value in
                    switch (field, value) {
                    case (1, .bytes(let r)): domain = FastProto.string(r)
                    case (5, .bytes(let r)): region = FastProto.string(r)
                    case (8, .bytes(let r)): url = FastProto.string(r)
                    default: break
                    }
                }
                count += 1
                history.navigations.append(WebVisit(id: id, source: "Safari", start: record.timestamp, end: nil, domain: domain, url: url, bundle: "com.apple.Safari", detail: region.isEmpty ? "Navigation" : "Navigation · region \(region)"))
                id += 1
                return true
            }
            history.streamCounts["Safari.Navigations"] = count
        }
        if let stream = Biome.stream(named: "Safari.SearchEngine") {
            var count = 0
            BiomeStreamReader(stream).forEachMessage(order: .newestFirst) { _, msg in
                count += 1
                if let s = msg[1]?.string, !history.searchEngines.contains(s) { history.searchEngines.append(s) }
                return count < 500
            }
            history.streamCounts["Safari.SearchEngine"] = count
        }
        if let stream = Biome.stream(named: "Safari.PageLoad") {
            history.pageLoads = BiomeStreamReader(stream).stats().records
            history.streamCounts["Safari.PageLoad"] = history.pageLoads
        }

        // Domains: time from the interval source, visits from everything.
        var domains: [String: WebDomain] = [:]
        let timed = history.knowledge.isEmpty ? history.biome : history.knowledge
        for v in timed where !v.domain.isEmpty {
            var d = domains[v.domain] ?? WebDomain(domain: v.domain)
            d.seconds += v.duration; d.visits += 1
            if !v.url.isEmpty { d.urls.insert(v.url) }
            d.last = max(d.last ?? v.start, v.start)
            domains[v.domain] = d
        }
        for v in history.navigations where !v.domain.isEmpty && domains[v.domain] == nil {
            // Navigations carry the registrable domain; fold into a matching host if one exists.
            if let key = domains.keys.first(where: { $0 == v.domain || $0.hasSuffix("." + v.domain) }) {
                if !v.url.isEmpty { domains[key]!.urls.insert(v.url) }
            } else {
                var d = WebDomain(domain: v.domain)
                d.visits = 1; d.last = v.start
                if !v.url.isEmpty { d.urls.insert(v.url) }
                domains[v.domain] = d
            }
        }
        history.domains = domains.values.sorted { ($0.seconds, $0.visits) > ($1.seconds, $1.visits) }
        let dates = history.all.map(\.start)
        if let a = dates.min(), let b = dates.max() { history.timeRange = a...b }
        history.biome.reverse()
        history.navigations.reverse()
        webCache = history
        note("web.load", since: t0)
        return history
    }
}
