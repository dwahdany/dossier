import Foundation
import DossierCore

// The iCloud key-value service daemon (com.apple.kvs) keeps a local cache of every
// NSUbiquitousKeyValueStore on the account in a few CoreData SQLite files, one per
// encryption class:
//   ZSYDMANAGEDSTORE(Z_PK, ZIDENTIFIER, ZTOTALDATALENGTH)           — one row per store
//   ZSYDMANAGEDKEYVALUE(Z_PK, ZSTORE → store, ZKEY, ZPLISTDATAVALUE, — one row per key;
//                        ZPLISTDATALENGTH, ZVALUEMODIFICATIONDATE)    value = binary plist
// Dates are Cocoa-epoch seconds.

struct KVSDatabase: Identifiable, Sendable, Hashable {
    var id: String { url.path }
    let url: URL
    let title: String
    let explanation: String
    let bytes: Int64
    let availability: Availability
}

struct KVSStoreInfo: Identifiable, Sendable, Hashable {
    var id: String { database.id + "|" + identifier }
    let database: KVSDatabase
    let pk: Int64
    let identifier: String
    let keys: Int
    let bytes: Int
    let range: ClosedRange<Date>?
    let highlight: KVSHighlight?

    /// Bundle-style identifier without a team prefix.
    var displayName: String {
        let parts = identifier.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) { return String(parts[1]) }
        return identifier
    }
}

struct KVSHighlight: Sendable, Hashable {
    let title: String
    let explanation: String
    let symbol: String
    let sensitivity: Sensitivity
    let rank: Int

    /// Known stores worth pointing out. Keys are generic Apple store identifiers.
    static let known: [String: KVSHighlight] = [
        "com.apple.mail.recents": .init(title: "Mail Recent Recipients", explanation: "People you recently wrote to in Mail: name, address and the dates of the last messages. Synced to all your devices for address completion.", symbol: "clock.arrow.circlepath", sensitivity: .sensitive, rank: 0),
        "com.apple.mail.vipsenders": .init(title: "Mail VIPs", explanation: "Your VIP senders in Mail with all their known addresses.", symbol: "star", sensitivity: .sensitive, rank: 1),
        "com.apple.accounts.sync.suggestion": .init(title: "Account Suggestions", explanation: "Mail and other accounts set up on one device and offered to your others: server names, user names, account types.", symbol: "person.badge.key", sensitivity: .sensitive, rank: 2),
        "com.apple.cmfsyncagent": .init(title: "Blocked Contacts", explanation: "The synced block list for calls, messages and mail: phone numbers and addresses.", symbol: "hand.raised", sensitivity: .sensitive, rank: 3),
        "com.apple.mail.businesses": .init(title: "Mail Businesses", explanation: "Businesses Mail recognised among your senders, with when each was last seen per category.", symbol: "building.2", sensitivity: .personal, rank: 4),
        "com.apple.PrintKit.PrinterTool": .init(title: "Printers", explanation: "Printers you have used on any device: names, network addresses, last-used dates.", symbol: "printer", sensitivity: .personal, rank: 5),
        "com.apple.wifi.syncable-networks": .init(title: "Wi-Fi Networks", explanation: "Known Wi-Fi networks synced across your devices.", symbol: "wifi", sensitivity: .sensitive, rank: 6),
        "com.apple.wifid.known-networks": .init(title: "Wi-Fi Sync State", explanation: "State of Wi-Fi known-network syncing.", symbol: "wifi", sensitivity: .personal, rank: 7),
        "com.apple.mail.listUnsubscribeInfo": .init(title: "Mailing-List Unsubscribes", explanation: "Mailing lists and senders you unsubscribed from in Mail, and when.", symbol: "envelope.badge.shield.half.filled", sensitivity: .personal, rank: 8),
        "com.apple.mail.remindMe": .init(title: "Mail Remind Me", explanation: "Messages you asked Mail to remind you about.", symbol: "bell", sensitivity: .personal, rank: 9),
        "com.apple.mail.mailboxCategories": .init(title: "Mail Categories", explanation: "Category overrides for senders in Mail.", symbol: "tray.2", sensitivity: .personal, rank: 10),
        "com.apple.calendar.recents": .init(title: "Calendar Recent Invitees", explanation: "People you recently invited to events.", symbol: "calendar", sensitivity: .sensitive, rank: 11),
        "com.apple.contacts.favorites": .init(title: "Favourite Contacts", explanation: "Your favourites: names, numbers and the preferred way to reach them.", symbol: "heart", sensitivity: .sensitive, rank: 12),
        "com.apple.eventkit.locations": .init(title: "Recent Event Locations", explanation: "Locations recently used for calendar events.", symbol: "mappin.and.ellipse", sensitivity: .sensitive, rank: 13),
        "com.apple.passbook.locations": .init(title: "Wallet Locations", explanation: "Locations recently used by Wallet.", symbol: "wallet.pass", sensitivity: .sensitive, rank: 14),
        "com.apple.CoreSuggestions": .init(title: "Siri Suggestions State", explanation: "Sync state of contact and event suggestions found in apps.", symbol: "sparkles", sensitivity: .personal, rank: 15),
        "com.apple.security.cloudkeychainproxy3": .init(title: "Keychain Sync Proxy", explanation: "Circle and peer information of iCloud Keychain syncing (opaque binary records).", symbol: "key", sensitivity: .sensitive, rank: 16),
    ]
}

struct KVSKey: Identifiable, Sendable, Hashable {
    let id: Int64
    let key: String
    let modified: Date?
    let bytes: Int
    let preview: String
    /// One value per field of the store's ``KVSLayout`` (empty for untyped stores).
    var values: [KVSValue] = []
}

enum KVSStore {
    static func databases() -> [KVSDatabase] {
        guard let dir = MSPaths.kvs, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "sqlite" }.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let title: String, explanation: String
            if name.contains("EndToEndEncrypted.AllPlatforms") {
                title = "End-to-End Encrypted (All Platforms)"; explanation = "Stores synced with end-to-end encryption to every platform."
            } else if name.contains("EndToEndEncrypted") {
                title = "End-to-End Encrypted"; explanation = "Stores synced with end-to-end encryption."
            } else if name.contains(".Encrypted") {
                title = "Encrypted"; explanation = "Stores synced with service-side encryption."
            } else {
                title = "Standard"; explanation = "Stores of apps using iCloud key-value storage, encrypted in transit and at rest on the server."
            }
            return KVSDatabase(url: url, title: title, explanation: explanation, bytes: FileProbe.databaseSize(url), availability: Paths.probe(url))
        }.sorted { $0.bytes > $1.bytes }
    }

    private static func open(_ database: KVSDatabase) async throws -> SQLiteDB {
        if case .inaccessible(let reason) = database.availability { throw DossierError.inaccessible(reason) }
        guard let db = await SQLiteDB.sharedIfAvailable(database.url) else { throw DossierError.missing("The key-value cache is not available.") }
        guard await db.hasColumns("ZSYDMANAGEDKEYVALUE", ["Z_PK", "ZSTORE", "ZKEY", "ZPLISTDATAVALUE"]),
              await db.hasColumns("ZSYDMANAGEDSTORE", ["Z_PK", "ZIDENTIFIER"]) else {
            throw DossierError.missing("The key-value cache uses a schema Dossier does not understand.")
        }
        return db
    }

    /// All stores of all databases with key counts; empty stores are omitted.
    static func stores() async -> [KVSStoreInfo] {
        var out: [KVSStoreInfo] = []
        for database in databases() {
            guard let db = try? await open(database) else { continue }
            let hasDate = await db.hasColumns("ZSYDMANAGEDKEYVALUE", ["ZVALUEMODIFICATIONDATE"])
            let sql = """
            SELECT s.Z_PK, s.ZIDENTIFIER, count(k.Z_PK), coalesce(sum(length(k.ZPLISTDATAVALUE)), 0),
                   \(hasDate ? "min(k.ZVALUEMODIFICATIONDATE), max(k.ZVALUEMODIFICATIONDATE)" : "NULL, NULL")
            FROM ZSYDMANAGEDSTORE s LEFT JOIN ZSYDMANAGEDKEYVALUE k ON k.ZSTORE = s.Z_PK GROUP BY s.Z_PK
            """
            for row in (try? await db.rows(sql)) ?? [] {
                guard let pk = row[0].int, let identifier = row[1].string, let keys = row[2].int, keys > 0 else { continue }
                var range: ClosedRange<Date>?
                if let lo = row[4].cocoaDate, let hi = row[5].cocoaDate, lo <= hi { range = lo...hi }
                out.append(KVSStoreInfo(
                    database: database, pk: pk, identifier: identifier, keys: Int(keys), bytes: Int(row[3].int ?? 0), range: range,
                    highlight: KVSHighlight.known[identifier]
                ))
            }
        }
        return out.sorted { a, b in
            switch (a.highlight, b.highlight) {
            case let (x?, y?): return x.rank != y.rank ? x.rank < y.rank : a.keys > b.keys
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.keys != b.keys ? a.keys > b.keys : a.identifier < b.identifier
            }
        }
    }

    static let sortColumns: [String: String] = ["key": "k.ZKEY", "modified": "k.ZVALUEMODIFICATIONDATE", "bytes": "length(k.ZPLISTDATAVALUE)"]

    static func keys(_ store: KVSStoreInfo, offset: Int, limit: Int, sort: PageSort?, search: String, layout: KVSLayout? = nil) async throws -> [KVSKey] {
        let db = try await open(store.database)
        let hasDate = await db.hasColumns("ZSYDMANAGEDKEYVALUE", ["ZVALUEMODIFICATIONDATE"])
        var order = hasDate ? "k.ZVALUEMODIFICATIONDATE DESC" : "k.ZKEY ASC"
        if let sort, let column = sortColumns[sort.columnID], hasDate || sort.columnID != "modified" { order = "\(column) \(sort.sqlDirection)" }
        var conditions = "k.ZSTORE = ?"
        var params: [SQLValue] = [.integer(store.pk)]
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            conditions += " AND k.ZKEY LIKE ? ESCAPE '\\'"
            let escaped = needle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            params.append(.text("%\(escaped)%"))
        }
        params += [.integer(Int64(limit)), .integer(Int64(offset))]
        // Values above 256 KiB are not decoded for the list preview.
        let sql = """
        SELECT k.Z_PK, k.ZKEY, \(hasDate ? "k.ZVALUEMODIFICATIONDATE" : "NULL"), length(k.ZPLISTDATAVALUE),
               CASE WHEN length(k.ZPLISTDATAVALUE) <= 262144 THEN k.ZPLISTDATAVALUE END
        FROM ZSYDMANAGEDKEYVALUE k WHERE \(conditions) ORDER BY \(order), k.Z_PK LIMIT ? OFFSET ?
        """
        return try await db.rows(sql, params).map { row in
            var preview = ""
            var values: [KVSValue] = []
            let key = row[1].string ?? ""
            if let data = row[4].data {
                if let value = PlistDecoder.decodeAny(data) {
                    preview = MSFormat.preview(value)
                    if let layout { values = layout.decode(key, value) }
                } else {
                    preview = "\(Format.bytes(data.count)) of binary data"
                }
            } else if let size = row[3].int, size > 0 {
                preview = "\(Format.bytes(size)) (select to decode)"
            }
            if let layout, values.count != layout.fields.count {
                values = [KVSValue](repeating: .none, count: layout.fields.count)
                if !values.isEmpty { values[0] = .text(preview.isEmpty ? key : preview) }
            }
            return KVSKey(id: row[0].int ?? 0, key: key, modified: row[2].cocoaDate, bytes: Int(row[3].int ?? 0), preview: preview, values: values)
        }
    }

    static func keyCount(_ store: KVSStoreInfo, search: String) async -> Int? {
        guard let db = try? await open(store.database) else { return nil }
        let needle = search.trimmingCharacters(in: .whitespaces)
        if needle.isEmpty { return store.keys }
        let escaped = needle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return await db.count("SELECT count(*) FROM ZSYDMANAGEDKEYVALUE k WHERE k.ZSTORE = ? AND k.ZKEY LIKE ? ESCAPE '\\'", [.integer(store.pk), .text("%\(escaped)%")])
    }

    static func value(_ store: KVSStoreInfo, key: Int64) async throws -> Data {
        let db = try await open(store.database)
        let value = try await db.scalar("SELECT ZPLISTDATAVALUE FROM ZSYDMANAGEDKEYVALUE WHERE Z_PK = ?", [.integer(key)])
        guard let data = value.data else { throw DossierError.message("This key has no stored value.") }
        return data
    }

    /// Keys whose name or decoded value contains the query, across all stores (global
    /// search). Values are small binary plists, so decoding a few thousand is quick; the
    /// scan is bounded and stops at `limit` hits.
    static func search(_ query: String, limit: Int) async -> [(store: KVSStoreInfo, key: KVSKey, match: String)] {
        let needle = query.lowercased()
        var out: [(KVSStoreInfo, KVSKey, String)] = []
        let all = await stores()
        for database in databases() {
            if Task.isCancelled || out.count >= limit { break }
            guard let db = try? await open(database) else { continue }
            let sql = """
            SELECT k.Z_PK, k.ZKEY, k.ZSTORE, length(k.ZPLISTDATAVALUE),
                   CASE WHEN length(k.ZPLISTDATAVALUE) <= 65536 THEN k.ZPLISTDATAVALUE END
            FROM ZSYDMANAGEDKEYVALUE k LIMIT 20000
            """
            guard let rows = try? await db.rows(sql, maxRows: 20_000) else { continue }
            let byPK = Dictionary(all.filter { $0.database == database }.map { ($0.pk, $0) }, uniquingKeysWith: { a, _ in a })
            for row in rows {
                if out.count >= limit || Task.isCancelled { break }
                guard let storePK = row[2].int, let store = byPK[storePK] else { continue }
                let key = row[1].string ?? ""
                var match: String?
                if key.lowercased().contains(needle) {
                    match = key
                } else if let data = row[4].data, let value = PlistDecoder.decodeAny(data) {
                    match = value.allStrings(limit: 64).first { $0.lowercased().contains(needle) }
                }
                guard let match else { continue }
                out.append((store, KVSKey(id: row[0].int ?? 0, key: key, modified: nil, bytes: Int(row[3].int ?? 0), preview: ""), Format.oneLine(match, max: 120)))
            }
        }
        return out
    }
}
