import Foundation
import DossierCore

// MARK: - CallHistory

// `~/Library/Application Support/CallHistoryDB/CallHistory.storedata` (CoreData):
//   ZCALLRECORD(ZDATE cocoa, ZDURATION seconds, ZADDRESS text-or-blob, ZNAME, ZORIGINATED 1 = outgoing,
//               ZANSWERED, ZCALLTYPE (1 phone, 8 FaceTime video, 16 FaceTime audio),
//               ZSERVICE_PROVIDER, ZLOCATION, ZISO_COUNTRY_CODE)
enum CallHistoryStore {
    static let name = "CallHistory.storedata"

    static func open() async throws -> SQLiteDB {
        let db = try await CommsDB.open(CommsPaths.callHistory, name)
        guard await db.hasColumns("ZCALLRECORD", ["ZDATE", "ZDURATION"]) else {
            throw DossierError.missing("The call history database has a different schema on this macOS version.")
        }
        return db
    }

    static func callTypeLabel(_ value: Int64?) -> String {
        switch value {
        case 1: return "Phone"
        case 8: return "FaceTime Video"
        case 16: return "FaceTime Audio"
        case .some(let v): return "Type \(v)"
        case nil: return ""
        }
    }

    static func calls() async throws -> [CallRow] {
        let db = try await open()
        let cols = await db.columnSet(of: "ZCALLRECORD")
        func col(_ name: String, _ fallback: String = "NULL") -> String { cols.contains(name) ? name : fallback }
        let rows = try await db.rows("""
            SELECT Z_PK, ZDATE, ZDURATION, \(col("ZADDRESS")), \(col("ZNAME")), \(col("ZORIGINATED", "0")), \(col("ZANSWERED", "0")),
                   \(col("ZCALLTYPE")), \(col("ZSERVICE_PROVIDER")), \(col("ZLOCATION")), \(col("ZISO_COUNTRY_CODE"))
            FROM ZCALLRECORD ORDER BY ZDATE DESC LIMIT 200000
            """)
        return rows.compactMap { r in
            guard let pk = r[0].int else { return nil }
            let address = r[3].string ?? r[3].data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let originated = (r[5].int ?? 0) != 0
            let answered = (r[6].int ?? 0) != 0
            let seconds = r[2].double ?? 0
            let status = originated ? (seconds > 0 ? "Outgoing" : "Outgoing, not connected") : (answered ? "Answered" : "Missed")
            let provider = r[8].string ?? ""
            let bundle = provider.lowercased().contains("facetime") ? "com.apple.FaceTime" : (provider.isEmpty ? "com.apple.Telephony" : provider)
            let detail = [callTypeLabel(r[7].int), r[9].string, r[10].string?.uppercased()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return CallRow(
                id: "ch-\(pk)", date: r[1].cocoaDate, bundle: bundle, direction: originated ? .outgoing : .incoming,
                person: r[4].string ?? "", handle: address, seconds: seconds, status: status, device: "This Mac", detail: detail)
        }
    }
}

// MARK: - CoreRecents

// `~/Library/Containers/com.apple.corerecents.recentsd/Data/Library/Recents/Recents`:
//   recents(ROWID, display_name, bundle_identifier, sending_address, dates TEXT (unix ms list),
//           last_date INTEGER (unix ms), count, group_kind)
//   contacts(recent_id → recents, display_name, kind (email / phone / map-location), address)
struct RecentRow: Identifiable, Sendable, Hashable {
    var id: String
    var source: String          // "CoreRecents" or the kvs store
    var category: String        // Recent / VIP / Favourite / Blocked …
    var name: String
    var address: String
    var kind: String
    var bundle: String
    var count: Int
    var last: Date?
    var detail: String
}

enum RecentsStore {
    static let name = "CoreRecents"

    static func open() async throws -> SQLiteDB {
        let db = try await CommsDB.open(CommsPaths.recentsDB, name)
        guard await db.hasColumns("recents", ["bundle_identifier"]), await db.hasColumns("contacts", ["recent_id", "address"]) else {
            throw DossierError.missing("The CoreRecents database has a different schema on this macOS version.")
        }
        return db
    }

    static func rows() async throws -> [RecentRow] {
        let db = try await open()
        let rc = await db.columnSet(of: "recents")
        let cc = await db.columnSet(of: "contacts")
        func r(_ name: String, _ fallback: String = "NULL") -> String { rc.contains(name) ? "r.\(name)" : fallback }
        func c(_ name: String, _ fallback: String = "NULL") -> String { cc.contains(name) ? "c.\(name)" : fallback }
        let rows = try await db.rows("""
            SELECT c.ROWID, coalesce(\(c("display_name")), \(r("display_name"))), c.address, \(c("kind")), r.bundle_identifier,
                   \(r("count", "0")), \(r("last_date")), \(r("sending_address")), \(r("group_kind", "0"))
            FROM contacts c JOIN recents r ON r.ROWID = c.recent_id ORDER BY \(r("last_date", "c.ROWID")) DESC LIMIT 100000
            """)
        return rows.compactMap { row in
            guard let id = row[0].int else { return nil }
            let sending = row[7].string
            return RecentRow(
                id: "cr-\(id)", source: "CoreRecents", category: "Recent", name: row[1].string ?? "", address: row[2].string ?? "",
                kind: row[3].string ?? "", bundle: row[4].string ?? "", count: Int(row[5].int ?? 0),
                last: row[6].int.map { DossierDate.unixMillis($0) },
                detail: sending.map { "sent from \($0)" } ?? "")
        }
    }
}

// MARK: - iCloud key-value service cache

// `~/Library/Daemon Containers/<uuid of com.apple.kvs>/Data/com.apple.kvs/*.sqlite` (CoreData):
//   ZSYDMANAGEDSTORE(Z_PK, ZIDENTIFIER)                      one row per synced key-value store
//   ZSYDMANAGEDKEYVALUE(ZSTORE, ZKEY, ZPLISTDATAVALUE, ZVALUEMODIFICATIONDATE)
// Value shapes used here (binary plists):
//   com.apple.mail.recents / calendar.recents / facetime.recents   key MR_* → { n name, a address, t [dates] }
//   com.apple.mail.vipsenders                                      key VIP_* → { n name, a [addresses] }
//   com.apple.contacts.favorites                                   key entries → [{ Name, Value, Label, ActionType, BundleIdentifier }]
//   com.apple.cmfsyncagent                                         block list → [{ …PhoneNumberUnformattedKey / …EmailUnformattedKey }]
enum KVSStore {
    static let name = "iCloud Key-Value Cache"

    static let stores: [String: String] = [
        "com.apple.mail.recents": "Mail recent",
        "com.apple.calendar.recents": "Calendar recent",
        "com.apple.facetime.recents": "FaceTime recent",
        "com.apple.mail.vipsenders": "Mail VIP",
        "com.apple.contacts.favorites": "Favourite",
        "com.apple.cmfsyncagent": "Blocked",
    ]

    static func rows() async throws -> [RecentRow] {
        guard CommsPaths.kvsDirectory != nil else { throw DossierError.missing("The iCloud key-value cache does not exist on this Mac.") }
        let files = CommsPaths.kvsDatabases()
        if files.isEmpty {
            if case .inaccessible(let reason) = Paths.probe(CommsPaths.kvsDirectory) { throw DossierError.inaccessible(reason) }
            throw DossierError.missing("The iCloud key-value cache does not exist on this Mac.")
        }
        var out: [RecentRow] = []
        var seen = Set<String>()
        let placeholders = stores.keys.map { _ in "?" }.joined(separator: ",")
        for file in files {
            guard let db = await CommsDB.openIfAvailable(file),
                  await db.hasColumns("ZSYDMANAGEDKEYVALUE", ["ZKEY", "ZPLISTDATAVALUE", "ZSTORE"]),
                  await db.hasColumns("ZSYDMANAGEDSTORE", ["ZIDENTIFIER"]) else { continue }
            let rows = (try? await db.rows("""
                SELECT s.ZIDENTIFIER, k.ZKEY, k.ZPLISTDATAVALUE, k.Z_PK FROM ZSYDMANAGEDKEYVALUE k
                JOIN ZSYDMANAGEDSTORE s ON s.Z_PK = k.ZSTORE WHERE s.ZIDENTIFIER IN (\(placeholders)) LIMIT 50000
                """, stores.keys.map { SQLValue.text($0) })) ?? []
            for row in rows {
                guard let store = row[0].string, let category = stores[store], let data = row[2].data,
                      let value = PlistDecoder.decodeAny(data) else { continue }
                let base = "kvs-\(file.lastPathComponent)-\(row[3].int ?? 0)"
                for item in items(store: store, category: category, key: row[1].string ?? "", value: value, base: base) {
                    // The same entry can live in several encryption-class databases.
                    let fingerprint = "\(item.category)|\(item.name)|\(item.address)"
                    if seen.insert(fingerprint).inserted { out.append(item) }
                }
            }
        }
        return out.sorted { ($0.category, $1.last ?? .distantPast) < ($1.category, $0.last ?? .distantPast) }
    }

    private static func items(store: String, category: String, key: String, value: PlistValue, base: String) -> [RecentRow] {
        let bundle: String
        switch store {
        case "com.apple.mail.recents", "com.apple.mail.vipsenders": bundle = "com.apple.mail"
        case "com.apple.calendar.recents": bundle = "com.apple.iCal"
        case "com.apple.facetime.recents": bundle = "com.apple.FaceTime"
        default: bundle = ""
        }
        switch store {
        case "com.apple.mail.recents", "com.apple.calendar.recents", "com.apple.facetime.recents":
            guard let address = value["a"]?.string else { return [] }
            let dates = (value["t"]?.array ?? []).compactMap(\.date)
            return [RecentRow(id: base, source: store, category: category, name: value["n"]?.string ?? "", address: address,
                              kind: address.contains("@") ? "email" : "phone", bundle: bundle, count: dates.count, last: dates.max(), detail: "")]
        case "com.apple.mail.vipsenders":
            let addresses = (value["a"]?.array ?? []).compactMap(\.string)
            let name = value["n"]?.string ?? ""
            return addresses.enumerated().map { index, address in
                RecentRow(id: "\(base)-\(index)", source: store, category: category, name: name, address: address, kind: "email", bundle: bundle, count: 0, last: nil, detail: "VIP sender")
            }
        case "com.apple.contacts.favorites":
            guard key == "entries", let entries = value.array else { return [] }
            return entries.enumerated().compactMap { index, entry in
                guard let address = entry["Value"]?.string else { return nil }
                let action = entry["ActionType"]?.string ?? ""
                let label = entry["Label"]?.string ?? ""
                return RecentRow(id: "\(base)-\(index)", source: store, category: category, name: entry["Name"]?.string ?? "", address: address,
                                 kind: address.contains("@") ? "email" : "phone", bundle: entry["BundleIdentifier"]?.string ?? "", count: 0, last: nil,
                                 detail: [action, label].filter { !$0.isEmpty }.joined(separator: " · "))
            }
        case "com.apple.cmfsyncagent":
            guard let pairs = value.dict else { return [] }
            guard let list = pairs.first(where: { $0.key.contains("ArrayKey") })?.value.array else { return [] }
            return list.enumerated().compactMap { index, entry in
                guard let fields = entry.dict, let address = fields.first(where: { $0.key.contains("Unformatted") })?.value.string else { return nil }
                return RecentRow(id: "\(base)-\(index)", source: store, category: category, name: "", address: address,
                                 kind: address.contains("@") ? "email" : "phone", bundle: "", count: 0, last: nil, detail: "blocked contact")
            }
        default:
            return []
        }
    }
}
