import Foundation
import DossierCore

/// One key of the iCloud key-value cache kept by `kvsd` (what apps store with
/// `NSUbiquitousKeyValueStore`, synced across the owner's devices).
struct KVSEntry: Sendable {
    let database: String
    let pk: Int64
    let store: String
    let key: String
    let modified: Date?
    let value: PlistValue?

    var ref: RawRef { .kvs(database: database, pk: pk) }
}

enum KVSSource {
    /// Entries of one store identifier across all kvs databases.
    static func entries(store: String, limit: Int = 5_000) async -> [KVSEntry] {
        var out: [KVSEntry] = []
        for url in EnvPaths.kvsDatabases {
            guard let db = await SQLiteDB.sharedIfAvailable(url),
                  await db.hasColumns("ZSYDMANAGEDKEYVALUE", ["ZKEY", "ZSTORE", "ZPLISTDATAVALUE"]),
                  await db.hasColumns("ZSYDMANAGEDSTORE", ["ZIDENTIFIER"]) else { continue }
            let hasDate = await db.hasColumns("ZSYDMANAGEDKEYVALUE", ["ZVALUEMODIFICATIONDATE"])
            let sql = """
                SELECT k.Z_PK, k.ZKEY, \(hasDate ? "k.ZVALUEMODIFICATIONDATE" : "NULL"), k.ZPLISTDATAVALUE
                FROM ZSYDMANAGEDKEYVALUE k JOIN ZSYDMANAGEDSTORE s ON k.ZSTORE = s.Z_PK
                WHERE s.ZIDENTIFIER = ? ORDER BY k.Z_PK LIMIT ?
                """
            for row in (try? await db.rows(sql, [.text(store), .integer(Int64(limit))])) ?? [] {
                guard let pk = row[0].int, let key = row[1].string else { continue }
                out.append(KVSEntry(database: url.path, pk: pk, store: store, key: key, modified: row[2].cocoaDate, value: row[3].data.flatMap(decode)))
            }
        }
        return out
    }

    /// Values are binary plists, occasionally a plist wrapped in plist data.
    static func decode(_ data: Data) -> PlistValue? {
        guard !data.isEmpty, let value = PlistDecoder.decodePlist(data) else { return nil }
        if let inner = value.data, PlistDecoder.isBinaryPlist(inner), let nested = PlistDecoder.decodePlist(inner) { return nested }
        return value
    }

    /// Number of keys and newest modification per store identifier (all databases).
    static func storeCounts(_ stores: [String]) async -> [String: (keys: Int, range: ClosedRange<Date>?)] {
        var out: [String: (keys: Int, range: ClosedRange<Date>?)] = [:]
        guard !stores.isEmpty else { return out }
        let marks = stores.map { _ in "?" }.joined(separator: ",")
        for url in EnvPaths.kvsDatabases {
            guard let db = await SQLiteDB.sharedIfAvailable(url),
                  await db.hasColumns("ZSYDMANAGEDKEYVALUE", ["ZSTORE", "ZVALUEMODIFICATIONDATE"]),
                  await db.hasColumns("ZSYDMANAGEDSTORE", ["ZIDENTIFIER"]) else { continue }
            let sql = """
                SELECT s.ZIDENTIFIER, count(k.Z_PK), min(k.ZVALUEMODIFICATIONDATE), max(k.ZVALUEMODIFICATIONDATE)
                FROM ZSYDMANAGEDSTORE s JOIN ZSYDMANAGEDKEYVALUE k ON k.ZSTORE = s.Z_PK
                WHERE s.ZIDENTIFIER IN (\(marks)) GROUP BY 1
                """
            for row in (try? await db.rows(sql, stores.map { .text($0) })) ?? [] {
                guard let id = row[0].string else { continue }
                var entry = out[id] ?? (0, nil)
                entry.keys += Int(row[1].int ?? 0)
                if let lo = row[2].cocoaDate, let hi = row[3].cocoaDate, lo <= hi {
                    entry.range = entry.range.map { min($0.lowerBound, lo)...max($0.upperBound, hi) } ?? lo...hi
                }
                out[id] = entry
            }
        }
        return out
    }
}

// MARK: - Known Wi-Fi networks

/// A Wi-Fi network remembered in iCloud (`com.apple.wifi.syncable-networks`).
struct KnownNetwork: Identifiable, Sendable {
    let id: String
    let ssid: String
    let addedAt: Date?
    let lastJoinedByUser: Date?
    let lastJoinedBySystem: Date?
    let removedAt: Date?
    let bssid: String
    let security: String
    let hidden: Bool
    let captive: Bool
    /// Raw `addedByVersion` ("macos.27_2.<build>.<model>.2").
    let addedBy: String
    /// "Mac · macOS 27.2".
    var addedByText: String { addedBy.isEmpty ? "" : EnvFormat.addedBy(addedBy) }
    let modified: Date?
    let details: [KV]
    let ref: RawRef

    /// A removal date older than the (re-)add date is a stale tombstone.
    var isRemoved: Bool { removedAt.map { $0 >= (addedAt ?? .distantPast) } ?? false }
    /// The system only records the week of its last automatic join.
    var lastJoinedText: String {
        guard let date = lastJoined else { return "—" }
        if let user = lastJoinedByUser, user >= date { return DossierDate.sortable(user) }
        return String(DossierDate.sortable(date).prefix(10)) + " (week of)"
    }
    var lastJoined: Date? { [lastJoinedByUser, lastJoinedBySystem].compactMap { $0 }.max() }
}

/// A printer remembered in iCloud (`com.apple.PrintKit.PrinterTool`).
struct KnownPrinter: Identifiable, Sendable {
    let id: String
    let name: String
    let location: String
    let urls: [String]
    let networks: [String]
    let lastUsed: Date?
}

enum WifiKVS {
    static let store = "com.apple.wifi.syncable-networks"
    static let printerStore = "com.apple.PrintKit.PrinterTool"

    /// Boolean flags of a network entry that describe its kind / security.
    private static let securityLabels = [
        "isPSK": "Password", "isWPA": "WPA", "isWPA2": "WPA2", "isWPA3": "WPA3", "isWEP": "WEP", "isEAP": "Enterprise",
        "isPublic": "Public", "isMoving": "Moving (vehicle)", "isAppBased": "App-provided", "isPersonalHotspot": "Personal Hotspot",
    ]

    static func networks() async -> [KnownNetwork] {
        var out: [KnownNetwork] = []
        for entry in await KVSSource.entries(store: store) {
            guard entry.key.hasPrefix("network."), let value = entry.value, value.dict != nil else { continue }
            let ssid = value["SSID"]?.string ?? String(entry.key.dropFirst("network.".count))
            var security: [String] = []
            var details: [KV] = []
            for pair in value.dict ?? [] {
                let key = pair.key
                if key.hasPrefix("is"), pair.value.bool == true, !["isHidden", "isCaptive", "isPrivacyProxyEnabled"].contains(key) {
                    security.append(Self.securityLabels[key] ?? String(key.dropFirst(2)))
                }
            }
            func yesNo(_ key: String) -> String? { (value[key]?.bool ?? value[key]?.int.map { $0 != 0 }).map { $0 ? "Yes" : "No" } }
            func weekOf(_ key: String) -> String? {
                (value[key]?.int.map(Double.init) ?? value[key]?.double).map { "week of " + DossierDate.day(DossierDate.cocoa($0 * 604_800)) }
            }
            func add(_ label: String, _ text: String?) { if let text, !text.isEmpty { details.append(KV(label, text)) } }
            add("Added", value["addedAt"]?.date.map { DossierDate.medium($0) })
            add("Added by", (value["addedByVersion"]?.string).map { EnvFormat.addedBy($0) })
            add("Last joined by you", value["lastJoinedByUserAt"]?.date.map { DossierDate.medium($0) })
            add("Last auto-joined", weekOf("lastJoinedBySystemAtWeek"))
            add("Removed", value["removedAt"]?.date.map { DossierDate.medium($0) })
            add("Security", security.isEmpty ? "Open / unknown" : security.sorted().joined(separator: ", "))
            add("Access point", value["BSSID"]?.string)
            add("Hidden network", yesNo("isHidden"))
            add("Captive portal", yesNo("isCaptive"))
            add("Private relay", yesNo("isPrivacyProxyEnabled"))
            add("Low Data Mode", yesNo("lowDataMode"))
            add("6 GHz only", weekOf("was6GHzOnlyAtWeek"))
            add("Preferred order set", value["preferredOrderTimestamp"]?.date.map { DossierDate.medium($0) })
            add("Roams with", value["seamlessSSIDList"]?.array?.compactMap(\.string).joined(separator: ", "))
            // "lastJoinedBySystemAtWeek" counts weeks since the Cocoa reference date.
            let week = value["lastJoinedBySystemAtWeek"]?.int.map(Double.init) ?? value["lastJoinedBySystemAtWeek"]?.double
            out.append(KnownNetwork(
                id: entry.database + "|\(entry.pk)", ssid: ssid,
                addedAt: value["addedAt"]?.date, lastJoinedByUser: value["lastJoinedByUserAt"]?.date,
                lastJoinedBySystem: week.map { DossierDate.cocoa($0 * 604_800) },
                removedAt: value["removedAt"]?.date, bssid: value["BSSID"]?.string ?? "",
                security: security.isEmpty ? "Open / unknown" : security.sorted().joined(separator: ", "),
                hidden: value["isHidden"]?.bool ?? false, captive: value["isCaptive"]?.bool ?? false,
                addedBy: value["addedByVersion"]?.string ?? "", modified: entry.modified,
                details: details, ref: entry.ref))
        }
        return out.sorted { ($0.lastJoined ?? $0.addedAt ?? .distantPast) > ($1.lastJoined ?? $1.addedAt ?? .distantPast) }
    }

    static func printers() async -> [KnownPrinter] {
        var out: [KnownPrinter] = []
        for entry in await KVSSource.entries(store: printerStore) {
            for (i, printer) in (entry.value?.array ?? []).enumerated() {
                let name = printer["com.apple.printkit.printer-display-name"]?.string ?? printer["printer-dns-sd-name"]?.string ?? "Printer"
                out.append(KnownPrinter(
                    id: "\(entry.pk)-\(i)", name: name,
                    location: printer["com.apple.printkit.printer-location"]?.string ?? "",
                    urls: printer["com.apple.printkit.printer-urls"]?.array?.compactMap(\.string) ?? [],
                    networks: printer["com.apple.printkit.printer-networks"]?.array?.compactMap(\.string) ?? [],
                    lastUsed: printer["com.apple.printkit.last-used-date"]?.date))
            }
        }
        return out
    }
}
