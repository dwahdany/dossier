import DossierCore
import Foundation

// MARK: - Models (DuetExpertCenter, "ATX" = the proactive app / action prediction engine)

struct ATXAppInfo: Sendable {
    let bundle: String
    var installDate: Date?
    var lastLaunch: Date?
    var lastSpotlightLaunch: Date?
    var averageGap: Double?
    var medianGap: Double?
    var genreID: Int?
    var isExtension = false
    /// `subsequentLaunchCounts`: time-decayed counts of the apps launched right after this one.
    var nextLaunches: [(bundle: String, score: Double)] = []
    /// `subsequentAppActionLaunchCounts`: decayed counts of actions ("bundle:ActionType") performed next.
    var nextActions: [(action: String, score: Double)] = []
}

struct ATXPrediction: Identifiable, Sendable {
    var id: String { consumer + "|" + bundle }
    let consumer: String
    let rank: Int
    let bundle: String
    let name: String
    let score: Double
    let confidence: Int?
    let reason: String
}

struct ATXDocumentPrediction: Identifiable, Sendable {
    let id: Int
    let url: String
    let score: Double
    let type: Int?
    var fileName: String { URL(string: url)?.lastPathComponent.removingPercentEncoding ?? (url as NSString).lastPathComponent }
    var folder: String {
        guard let u = URL(string: url), u.isFileURL else { return url }
        return Format.tildePath(u.deletingLastPathComponent())
    }
}

struct ATXMenuPrediction: Identifiable, Sendable {
    let id: Int
    let bundle: String
    let name: String
    let title: String
    let score: Double
}

struct ATXAnchor: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    var occurrences = 0
    var last: Date?
    var hours: [Int] = Array(repeating: 0, count: 24)
    var followUps: [ATXFollowUp] = []
    var livePredictions: [String] = []

    var title: String {
        var s = name
        if s.hasSuffix("Anchor") { s = String(s.dropLast(6)) }
        if s.hasPrefix("LOI") { s = "Location " + s.dropFirst(3) }
        // CamelCase → words
        var out = ""
        for ch in s {
            if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    var symbol: String {
        if name.contains("Charger") { return "bolt.fill" }
        if name.contains("BluetoothDisconnected") { return "headphones.circle" }
        if name.contains("Bluetooth") { return "headphones" }
        if name.contains("LOIEntrance") { return "figure.walk.arrival" }
        if name.contains("LOIExit") { return "figure.walk.departure" }
        if name.contains("Idle") { return "sunrise" }
        if name.contains("CarPlay") { return "car" }
        if name.contains("Wifi") || name.contains("WiFi") { return "wifi" }
        return "pin"
    }
}

struct ATXFollowUp: Identifiable, Sendable {
    var id: String { kind + "|" + candidate }
    let kind: String          // app / action / mode
    let candidate: String     // bundle id, "bundle:Action:hash", "modeUUID:n"
    let label: String
    let bundle: String?
    let observations: Int
    let performed: Int
    let engaged: Int
    let averageDelay: Double
}

struct ATXDose: Identifiable, Sendable {
    var id: String { bundle }
    let bundle: String
    let name: String
    var today: Double?
    var average: Double?
    var samples: Int?
    var error: Double?
}

struct ATXInferredMode: Identifiable, Sendable {
    let id: Int
    let start: Date
    let end: Date
    let mode: Int
    let source: String
    let confidence: Double
}

struct ATXMenuCommand: Identifiable, Sendable {
    let id: Int64
    let date: Date
    let bundle: String
    let name: String
    let actionType: String
    let title: String
    let sessionStart: Date?
    let sessionEnd: Date?
}

struct ATXLaunch: Identifiable, Sendable {
    var id: Double { date.timeIntervalSinceReferenceDate }
    let date: Date
    let bundle: String
}

struct DuetSnapshot: Sendable {
    var availability: Availability = .missing
    var appInfo: [String: ATXAppInfo] = [:]
    var launchSequence: [ATXLaunch] = []
    var predictions: [String: [ATXPrediction]] = [:]
    var consumers: [String] = []
    var predictionsUpdated: Date?
    var documents: [ATXDocumentPrediction] = []
    var menuItems: [ATXMenuPrediction] = []
    var anchors: [ATXAnchor] = []
    var currentDose: [String: Double] = [:]
    var doseExpires: Date?
    var historicalDose: [String: (average: Double, samples: Int, error: Double)] = [:]
    var doseHistoryDate: Date?
    var modes: [ATXInferredMode] = []
    var menuCommands: [ATXMenuCommand] = []
    var histogramCount = 0
    var tables: [String: Int] = [:]

    /// Consumers whose rankings are identical, grouped: [(title, predictions)].
    var predictionGroups: [(title: String, list: [ATXPrediction])] {
        var groups: [(key: [String], titles: [String], list: [ATXPrediction])] = []
        for consumer in consumers {
            let list = predictions[consumer] ?? []
            let key = list.map(\.bundle)
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].titles.append(consumer) } else { groups.append((key, [consumer], list)) }
        }
        return groups.map { ($0.titles.joined(separator: " · "), $0.list) }
    }

    /// Per-app doses without the lock screen and other system surfaces.
    var doses: [ATXDose] {
        var out: [String: ATXDose] = [:]
        for (b, v) in historicalDose where !AppNames.isSystemSurface(b) {
            out[b] = ATXDose(bundle: b, name: AppNames.name(b), today: nil, average: v.average, samples: v.samples, error: v.error)
        }
        for (b, v) in currentDose where !AppNames.isSystemSurface(b) {
            var d = out[b] ?? ATXDose(bundle: b, name: AppNames.name(b))
            d.today = v
            out[b] = d
        }
        return out.values.sorted { ($0.today ?? 0, $0.average ?? 0) > ($1.today ?? 0, $1.average ?? 0) }
    }
}

enum DuetPaths {
    static var root: URL { Paths.duetExpertCenter }
    static var dataStore: URL { root.appendingPathComponent("_ATXDataStore.db") }
    static var currentDose: URL { root.appendingPathComponent("_ATXAppDailyDose_CurrentDose") }
    static var historicalDose: URL { root.appendingPathComponent("_ATXAppDailyDose_HistoricalDose") }
    static var clientModelCaches: URL { root.appendingPathComponent("ClientModelCaches", isDirectory: true) }
    static var caches: URL { root.appendingPathComponent("caches", isDirectory: true) }
    static var documentPredictions: URL { caches.appendingPathComponent("ATXDocumentPredictorScores-DocumentSpotlight") }
    static var menuPredictions: URL { caches.appendingPathComponent("ATXCacheFile-MenuItemPredictions") }
    static var anchorPredictions: URL { caches.appendingPathComponent("anchorModelSchedulerCurrentPredictions") }
    static var inferredModeStream: URL { root.appendingPathComponent("streams/appLaunchInferredMode", isDirectory: true) }

    /// Small files only (prediction caches are a few KB); anything bigger is skipped.
    static func read(_ url: URL, limit: Int = 8 << 20) -> Data? {
        guard let info = FileProbe.info(url), !info.isDirectory, info.size <= limit else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func consumerTitle(_ file: String) -> String {
        switch file {
        case "atx_app_predictions_spotlight": return "Spotlight"
        case "atx_app_predictions_homescreen": return "Home Screen / Dock"
        case "atx_app_predictions_app_library": return "App Library / Launchpad"
        default:
            return file.replacingOccurrences(of: "atx_app_predictions_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

extension ActivityStore {
    /// Everything read from `~/Library/DuetExpertCenter` (cached; all inputs are small).
    func duet() async -> DuetSnapshot {
        if let duetCache { return duetCache }
        let t0 = Date()
        var snap = DuetSnapshot()
        snap.availability = Paths.probe(DuetPaths.root)
        guard snap.availability.isAvailable else { duetCache = snap; return snap }

        await loadDataStore(&snap)
        loadPredictions(&snap)
        loadDocuments(&snap)
        loadMenuItems(&snap)
        loadDoses(&snap)
        loadModes(&snap)
        duetCache = snap
        note("duet.load", since: t0)
        return snap
    }

    private func decayedCounts(_ data: Data?) -> [(String, Double)] {
        guard let data, let value = PlistDecoder.decodeAny(data), let pairs = value.dict else { return [] }
        return pairs.compactMap { pair in pair.value.double.map { (pair.key, $0) } }.sorted { $0.1 > $1.1 }
    }

    private func loadDataStore(_ snap: inout DuetSnapshot) async {
        guard let db = await SQLiteDB.sharedIfAvailable(DuetPaths.dataStore) else { return }
        for table in ["appInfo", "appLaunchSequence", "alog", "anchorOccurrence", "anchorModelTrainingData", "histograms", "categoricalHistograms"] {
            if await db.tableExists(table) { snap.tables[table] = await db.rowCount(of: table) ?? 0 }
        }
        snap.histogramCount = (snap.tables["histograms"] ?? 0) + (snap.tables["categoricalHistograms"] ?? 0)

        // appInfo — dates are Cocoa seconds.
        let appCols = await db.columnNames(of: "appInfo")
        if appCols.contains("bundleid"), let rows = try? await db.rows("SELECT * FROM appInfo", maxRows: 20_000) {
            for r in rows {
                guard let bundle = r["bundleId"].string else { continue }
                var info = ATXAppInfo(bundle: bundle)
                // Unset dates are stored as small placeholder numbers, not NULL.
                func date(_ v: SQLValue) -> Date? { v.cocoaDate.flatMap { DossierDate.isPlausible($0) ? $0 : nil } }
                info.installDate = date(r["installDate"])
                info.lastLaunch = date(r["lastLaunchDate"])
                info.lastSpotlightLaunch = date(r["lastSpotlightLaunchDate"])
                info.averageGap = r["averageSecondsBetweenLaunches"].double.flatMap { $0 > 0 ? $0 : nil }
                info.medianGap = r["medianSecondsBetweenLaunches"].double.flatMap { $0 > 0 ? $0 : nil }
                info.genreID = r["genreId"].int.map(Int.init)
                info.isExtension = r["isExtension"].bool ?? false
                info.nextLaunches = decayedCounts(r["subsequentLaunchCounts"].data).map { (bundle: $0.0, score: $0.1) }
                info.nextActions = decayedCounts(r["subsequentAppActionLaunchCounts"].data).map { (action: $0.0, score: $0.1) }
                snap.appInfo[bundle] = info
            }
        }

        if await db.hasColumns("appLaunchSequence", ["launchDate", "bundleId"]),
           let rows = try? await db.rows("SELECT launchDate, bundleId FROM appLaunchSequence ORDER BY launchDate DESC LIMIT 200") {
            snap.launchSequence = rows.compactMap { r in
                guard let d = r[0].cocoaDate, let b = r[1].string else { return nil }
                return ATXLaunch(date: d, bundle: b)
            }
        }

        // Anchors — anchorDate is Unix seconds.
        var anchors: [String: ATXAnchor] = [:]
        var order: [String] = []
        if await db.hasColumns("anchorType", ["name", "description"]),
           let rows = try? await db.rows("SELECT name, description FROM anchorType") {
            for r in rows {
                guard let n = r[0].string else { continue }
                anchors[n] = ATXAnchor(name: n, description: r[1].string ?? "")
                order.append(n)
            }
        }
        if await db.hasColumns("anchorOccurrence", ["anchorType", "anchorDate", "anchorLocalHour"]),
           let rows = try? await db.rows("SELECT anchorType, anchorLocalHour, count(*), max(anchorDate) FROM anchorOccurrence GROUP BY 1, 2") {
            for r in rows {
                guard let n = r[0].string else { continue }
                if anchors[n] == nil { anchors[n] = ATXAnchor(name: n, description: ""); order.append(n) }
                let count = Int(r[2].int ?? 0)
                anchors[n]!.occurrences += count
                if let h = r[1].int, (0..<24).contains(Int(h)) { anchors[n]!.hours[Int(h)] += count }
                if let d = r[3].unixDate { anchors[n]!.last = max(anchors[n]!.last ?? d, d) }
            }
        }
        if await db.hasColumns("anchorModelTrainingData", ["anchorType", "candidateType", "candidateId", "candidatePerformed", "candidateEngaged", "secondsSinceAnchor"]),
           let rows = try? await db.rows("""
               SELECT anchorType, candidateType, candidateId, count(*), sum(candidatePerformed), sum(candidateEngaged), avg(secondsSinceAnchor)
               FROM anchorModelTrainingData GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 5000
               """) {
            for r in rows {
                guard let n = r[0].string, let kind = r[1].string, let candidate = r[2].string else { continue }
                if anchors[n] == nil { anchors[n] = ATXAnchor(name: n, description: ""); order.append(n) }
                var label = candidate
                var bundle: String?
                if kind == "app" {
                    bundle = candidate; label = AppNames.name(candidate)
                } else if kind == "action" {
                    let parts = candidate.split(separator: ":").map(String.init)
                    bundle = parts.first
                    let action = parts.count > 1 ? (parts[1] == "RunIntelligenceCommand" ? "menu command" : parts[1]) : ""
                    label = (parts.first.map(AppNames.name) ?? "") + (action.isEmpty ? "" : " › " + action)
                } else if kind == "mode" {
                    label = "Focus mode" + (candidate.split(separator: ":").last.map { " (type \($0))" } ?? "")
                }
                anchors[n]!.followUps.append(ATXFollowUp(
                    kind: kind, candidate: candidate, label: label, bundle: bundle,
                    observations: Int(r[3].int ?? 0), performed: Int(r[4].int ?? 0), engaged: Int(r[5].int ?? 0),
                    averageDelay: r[6].double ?? 0))
            }
        }
        if let data = DuetPaths.read(DuetPaths.anchorPredictions), let v = PlistDecoder.decodeAny(data), let pairs = v.dict {
            for pair in pairs {
                let strings = pair.value.allStrings(limit: 16).filter { !$0.hasPrefix("$") && $0.contains(".") }
                if anchors[pair.key] != nil { anchors[pair.key]!.livePredictions = strings }
            }
        }
        snap.anchors = order.compactMap { anchors[$0] }.sorted {
            ($0.followUps.isEmpty ? 0 : 1, $0.occurrences) > ($1.followUps.isEmpty ? 0 : 1, $1.occurrences)
        }

        // alog — logged menu / app actions; `slots` is an 8-byte header + NSKeyedArchiver(ATXAction{protobufData}).
        if await db.hasColumns("alog", ["id", "bundleId", "actionType", "date", "slots"]),
           await db.tableExists("alogBundleId"), await db.tableExists("alogAction") {
            let cols = await db.columnNames(of: "alog")
            let session = cols.contains("appsessionstartdate") && cols.contains("appsessionenddate")
            if let rows = try? await db.rows("""
                SELECT a.id, b.bundleId, t.actionType, a.date, a.slots, \(session ? "a.appSessionStartDate, a.appSessionEndDate" : "NULL, NULL")
                FROM alog a LEFT JOIN alogBundleId b ON b.id = a.bundleId LEFT JOIN alogAction t ON t.id = a.actionType
                ORDER BY a.date DESC LIMIT 2000
                """) {
                for r in rows {
                    guard let id = r[0].int, let date = r[3].cocoaDate else { continue }
                    let bundle = r[1].string ?? ""
                    snap.menuCommands.append(ATXMenuCommand(
                        id: id, date: date, bundle: bundle, name: AppNames.name(bundle), actionType: r[2].string ?? "",
                        title: r[4].data.flatMap { Self.actionTitle($0) } ?? "", sessionStart: r[5].cocoaDate, sessionEnd: r[6].cocoaDate))
                }
            }
        }
    }

    /// Extracts the human-readable title of an archived `ATXAction`.
    ///
    /// `alog.slots` layout (empirical): 4-byte hash, 1-byte version, `u16` length *n*, 1 pad
    /// byte, then a binary plist of *n* + 8 bytes whose 8-byte `bplist00` magic is replaced by
    /// that header, followed by a short key suffix. The plist is an NSKeyedArchiver graph of
    /// an `ATXAction` whose `protobufData` holds: 1 bundle id, 6 title, 20 (repeated) the menu
    /// path from the top-level menu down to the command.
    static func actionTitle(_ blob: Data) -> String? {
        let magic = Data("bplist00".utf8)
        var plist: Data?
        if blob.starts(with: magic) {
            plist = blob
        } else if blob.count > 16 {
            let bytes = [UInt8](blob.prefix(8))
            let n = Int(bytes[5]) | Int(bytes[6]) << 8
            if n > 8, n + 8 <= blob.count {
                plist = magic + blob.subdata(in: blob.startIndex + 8..<blob.startIndex + 8 + n)
            }
        }
        guard let plist, let value = PlistDecoder.decodeAny(plist) else { return nil }
        guard let proto = value["protobufData"]?.data ?? value["root"]?["protobufData"]?.data else { return nil }
        return actionTitle(proto: proto)
    }

    static func actionTitle(proto: Data) -> String? {
        guard let msg = ProtoMessage(proto) else { return nil }
        let path = msg.all(20).compactMap(\.string).filter { !$0.isEmpty }
        if path.count > 1 { return path.joined(separator: " › ") }
        return path.first ?? msg[6]?.string
    }

    /// `ClientModelCaches/atx_app_predictions_*`: protobuf, 2 = repeated suggestion
    /// { 2 { 1 client model id }, 3 { 1 executable (bundle id) }, 4 { 3 reason text },
    /// 5 { 1 raw score, 2 confidence category } } in rank order.
    private func loadPredictions(_ snap: inout DuetSnapshot) {
        let dir = DuetPaths.clientModelCaches
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard name.hasPrefix("atx_app_predictions"), let data = DuetPaths.read(file), let msg = ProtoMessage(data) else { continue }
            let consumer = DuetPaths.consumerTitle(name)
            var list: [ATXPrediction] = []
            for (i, field) in msg.all(2).enumerated() {
                guard let s = field.message, let bundle = s.string(at: 3, 1) else { continue }
                list.append(ATXPrediction(
                    consumer: consumer, rank: i + 1, bundle: bundle, name: AppNames.name(bundle),
                    score: s.double(at: 5, 1) ?? 0, confidence: s.int(at: 5, 2).map(Int.init), reason: s.string(at: 4, 3) ?? ""))
            }
            if !list.isEmpty {
                snap.predictions[consumer] = list
                snap.consumers.append(consumer)
                if let m = FileProbe.info(file)?.modified { snap.predictionsUpdated = max(snap.predictionsUpdated ?? m, m) }
            }
        }
    }

    private func loadDocuments(_ snap: inout DuetSnapshot) {
        guard let data = DuetPaths.read(DuetPaths.documentPredictions), let v = PlistDecoder.decodeAny(data) else { return }
        let docs = v["predictedDocuments"]?.array ?? v["root"]?["predictedDocuments"]?.array ?? []
        for (i, d) in docs.enumerated() {
            guard let url = d["documentURL"]?.string else { continue }
            snap.documents.append(ATXDocumentPrediction(id: i, url: url, score: d["predictionScore"]?.double ?? 0, type: d["predictionType"]?.int.map(Int.init)))
        }
        snap.documents.sort { $0.score > $1.score }
    }

    private func loadMenuItems(_ snap: inout DuetSnapshot) {
        guard let data = DuetPaths.read(DuetPaths.menuPredictions), let v = PlistDecoder.decodeAny(data), let items = v.array ?? v["root"]?.array else { return }
        for (i, item) in items.enumerated() {
            guard let proto = item["predictedItem"]?["protobufData"]?.data, let msg = ProtoMessage(proto) else { continue }
            let bundle = msg[1]?.string ?? ""
            snap.menuItems.append(ATXMenuPrediction(id: i, bundle: bundle, name: AppNames.name(bundle), title: Self.actionTitle(proto: proto) ?? "", score: item["score"]?.double ?? 0))
        }
        snap.menuItems.sort { $0.score > $1.score }
    }

    /// `_ATXAppDailyDose_CurrentDose` (plist: doses = seconds per bundle id today, expires)
    /// and `_ATXAppDailyDose_HistoricalDose` (archive: bundle id → `_ATXMovingAverage`).
    private func loadDoses(_ snap: inout DuetSnapshot) {
        // CurrentDose is JSON on current macOS; older builds wrote a plist.
        if let data = DuetPaths.read(DuetPaths.currentDose), let v = PlistDecoder.decodeJSON(data) ?? PlistDecoder.decodeAny(data) {
            for pair in v["doses"]?.dict ?? [] { if let s = pair.value.double { snap.currentDose[pair.key] = s } }
            snap.doseExpires = v["expires"]?.double.map(DossierDate.cocoa) ?? v["expires"]?.date
        }
        if let data = DuetPaths.read(DuetPaths.historicalDose), let v = PlistDecoder.decodeAny(data) {
            snap.doseHistoryDate = v["duetHistoryTimestamp"]?.date
            for pair in v["appAverageDurationMapKey"]?.dict ?? [] {
                guard let avg = pair.value["avgDuration"]?.double else { continue }
                snap.historicalDose[pair.key] = (avg, Int(pair.value["count"]?.int ?? 0), pair.value["avgError"]?.double ?? 0)
            }
        }
    }

    /// `streams/appLaunchInferredMode` (SEGB): 1 start, 2 end (Cocoa), 3 mode type,
    /// 4 inference source, 5 confidence.
    private func loadModes(_ snap: inout DuetSnapshot) {
        guard let stream = Biome.loadStream(DuetPaths.inferredModeStream) else { return }
        var id = 0
        var seen = Set<String>()
        BiomeStreamReader(stream).forEachMessage(order: .newestFirst) { _, msg in
            guard let a = msg[1]?.cocoaDate, let b = msg[2]?.cocoaDate else { return true }
            // The stream re-emits unchanged periods; keep each (start, end, mode) once.
            let key = "\(a.timeIntervalSinceReferenceDate)|\(b.timeIntervalSinceReferenceDate)|\(msg[3]?.int ?? -1)"
            guard seen.insert(key).inserted else { return true }
            snap.modes.append(ATXInferredMode(id: id, start: a, end: b, mode: Int(msg[3]?.int ?? -1), source: msg[4]?.string ?? "", confidence: msg[5]?.double ?? 0))
            id += 1
            return id < 2000
        }
    }
}
