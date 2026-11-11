import Foundation
import DossierCore

// Typed table layouts for iCloud key-value stores whose value shape is known.
//
// Value shapes (binary plists, established empirically; all keys are generic):
//   * "recents" stores (`com.apple.mail.recents`, `com.apple.calendar.recents`,
//     `com.apple.eventkit.locations`, `com.apple.passbook.locations`, …), written by
//     CoreRecents: key `MR_<hash>` = one entry `{a: address, n: name, k: kind,
//     s: sending account, S: donating bundle id, t: [dates used], v: version, m: metadata}`;
//     key `GP_<hash>` = a group `{k: "gr", mrs: [{a, n, k}], s, S, t}`; key
//     `MAX_RECENTS` = `{m: limit, v}`.
//   * `com.apple.mail.vipsenders`: `VIP_<uuid>` = `{n: name, a: [addresses], v}`.
//   * `com.apple.wifi.syncable-networks`: `network.<ssid>` = `{SSID, BSSID, addedAt,
//     lastJoinedByUserAt, removedAt, is… flags}`.
//   * Mail's own stores wrap every value as `{updatedAt: seconds, value: …}`:
//     `listUnsubscribeInfo` (key `L:<list id>` / `S:<sender>`, value = text),
//     `remindMe` (value `{date, display-date, message-id}`),
//     `mailboxCategories` (value `{mailbox, category, ls, lsd}`),
//     `businesses` (value `{id, lastSeenDates: {category: seconds}}`).
//     Seconds are Unix or Cocoa epoch depending on the writing OS version.

enum KVSValue: Sendable, Hashable {
    case none
    case text(String)
    case date(Date)
    case number(Int)

    var text: String {
        switch self {
        case .none: return ""
        case .text(let s): return s
        case .date(let d): return DossierDate.sortable(d)
        case .number(let n): return Format.count(n)
        }
    }

    var date: Date? {
        if case .date(let d) = self { return d }
        return nil
    }

    /// Value as shown in the inspector.
    var detail: String {
        if case .date(let d) = self { return DossierDate.medium(d) + " (" + DossierDate.relative(d) + ")" }
        return text
    }
}

struct KVSField: Sendable {
    enum Kind: Sendable { case text, date, number, app }
    let id: String
    let title: String
    let width: Double
    var kind: Kind = .text
    /// Holds names / addresses (takes the store's sensitivity) rather than technical values.
    var personal = false
    var secondary = false
}

struct KVSLayout: Sendable {
    let fields: [KVSField]
    /// Field the table is sorted by initially (descending), if any.
    var initialSort: String?
    /// One value per field for a key and its decoded plist.
    let decode: @Sendable (_ key: String, _ value: PlistValue) -> [KVSValue]

    /// Stores above this size keep the generic SQL-paged key / value table.
    static let maxKeys = 5_000

    static func layout(for identifier: String) -> KVSLayout? {
        switch identifier {
        case "com.apple.mail.vipsenders": return vips
        case "com.apple.wifi.syncable-networks": return wifi
        case "com.apple.mail.listUnsubscribeInfo": return unsubscribes
        case "com.apple.mail.remindMe": return remindMe
        case "com.apple.mail.mailboxCategories": return mailboxCategories
        case "com.apple.mail.businesses": return businesses
        default:
            if identifier.hasSuffix(".recents") || identifier == "com.apple.eventkit.locations" || identifier == "com.apple.passbook.locations" {
                return recents(locations: identifier.hasSuffix(".locations"))
            }
            return nil
        }
    }

    // MARK: Helpers

    private static func text(_ value: PlistValue?) -> KVSValue {
        guard let s = value?.string, !s.isEmpty else { return .none }
        return .text(Format.oneLine(s, max: 300))
    }

    private static func seconds(_ value: PlistValue?) -> KVSValue {
        if let d = value?.date { return .date(d) }
        guard let n = value?.double, n > 0, let date = DossierDate.cocoaOrUnix(n) else { return .none }
        return .date(date)
    }

    private static func latest(_ dates: [Date]) -> KVSValue { dates.max().map { .date($0) } ?? .none }

    /// Fallback for keys that do not have the store's usual shape: the generic preview
    /// in the first column.
    private static func fallback(_ count: Int, _ key: String, _ value: PlistValue) -> [KVSValue] {
        var out = [KVSValue](repeating: .none, count: count)
        out[0] = .text(key + ": " + MSFormat.preview(value, max: 160))
        return out
    }

    // MARK: Layouts

    private static func recents(locations: Bool) -> KVSLayout {
        KVSLayout(
            fields: [
                KVSField(id: "name", title: "Name", width: 180, personal: true),
                KVSField(id: "address", title: locations ? "Address" : "Address / Number", width: 220, personal: true),
                KVSField(id: "kind", title: "Kind", width: 80, secondary: true),
                KVSField(id: "account", title: "Used From Account", width: 170, personal: true),
                KVSField(id: "app", title: "App", width: 110, kind: .app),
                KVSField(id: "uses", title: "Uses", width: 55, kind: .number),
                KVSField(id: "last", title: "Last Used", width: 130, kind: .date),
            ],
            initialSort: "last",
            decode: { key, value in
                guard value.dict != nil else { return fallback(7, key, value) }
                if key == "MAX_RECENTS" {
                    return [.text("Maximum number of entries"), text(value["m"]), .text("Setting"), .none, .none, .none, .none]
                }
                let dates = (value["t"]?.array ?? []).compactMap(\.date)
                var name = text(value["n"]), address = text(value["a"])
                var kind = value["k"]?.string ?? ""
                if let members = value["mrs"]?.array {
                    let names = members.compactMap { $0["n"]?.string ?? $0["a"]?.string }.filter { !$0.isEmpty }
                    let addresses = members.compactMap { $0["a"]?.string }.filter { !$0.isEmpty }
                    if case .none = name, !names.isEmpty { name = .text(names.joined(separator: ", ")) }
                    if case .none = address, !addresses.isEmpty { address = .text(addresses.joined(separator: ", ")) }
                    kind = "Group of \(members.count)"
                } else if kind == "gr" {
                    kind = "Group"
                }
                return [
                    name, address, kind.isEmpty ? .none : .text(kind), text(value["s"]), text(value["S"]),
                    dates.isEmpty ? .none : .number(dates.count), latest(dates),
                ]
            }
        )
    }

    private static let vips = KVSLayout(
        fields: [
            KVSField(id: "name", title: "Name", width: 220, personal: true),
            KVSField(id: "addresses", title: "Addresses", width: 520, personal: true),
            KVSField(id: "count", title: "Count", width: 60, kind: .number),
        ],
        decode: { key, value in
            guard value.dict != nil else { return fallback(3, key, value) }
            let addresses = (value["a"]?.array ?? []).compactMap(\.string)
            return [text(value["n"]), addresses.isEmpty ? text(value["a"]) : .text(addresses.joined(separator: ", ")), .number(addresses.count)]
        }
    )

    private static let wifi = KVSLayout(
        fields: [
            KVSField(id: "ssid", title: "Network", width: 220, personal: true),
            KVSField(id: "flags", title: "Properties", width: 250),
            KVSField(id: "added", title: "Added", width: 130, kind: .date),
            KVSField(id: "joined", title: "Last Joined by You", width: 130, kind: .date),
            KVSField(id: "removed", title: "Removed", width: 130, kind: .date),
            KVSField(id: "bssid", title: "BSSID", width: 140, personal: true, secondary: true),
            KVSField(id: "version", title: "Added By", width: 110, secondary: true),
        ],
        decode: { key, value in
            guard let pairs = value.dict, value["SSID"] != nil || key.hasPrefix("network.") else { return fallback(7, key, value) }
            // Every true `is…` flag, without the prefix: "WPA2 · PSK · Captive".
            var flags: [String] = []
            for pair in pairs where pair.key.hasPrefix("is") && pair.key.count > 2 && pair.value.bool == true {
                flags.append(CascadeSetInfo.spaced(String(pair.key.dropFirst(2))))
            }
            if value["lowDataMode"]?.bool == true { flags.append("Low Data Mode") }
            let ssid = value["SSID"]?.string ?? String(key.dropFirst("network.".count))
            return [
                .text(ssid), flags.isEmpty ? .none : .text(flags.joined(separator: " · ")),
                seconds(value["addedAt"]), seconds(value["lastJoinedByUserAt"]), seconds(value["removedAt"]),
                text(value["BSSID"]), text(value["addedByVersion"]),
            ]
        }
    )

    private static let unsubscribes = KVSLayout(
        fields: [
            KVSField(id: "kind", title: "Kind", width: 100),
            KVSField(id: "who", title: "List / Sender", width: 420, personal: true),
            KVSField(id: "value", title: "State", width: 110, secondary: true),
            KVSField(id: "updated", title: "Updated", width: 130, kind: .date),
        ],
        initialSort: "updated",
        decode: { key, value in
            guard value.dict != nil, value["updatedAt"] != nil else { return fallback(4, key, value) }
            var kind = "", who = key
            if key.hasPrefix("L:") { kind = "Mailing list"; who = String(key.dropFirst(2)) }
            else if key.hasPrefix("S:") { kind = "Sender"; who = String(key.dropFirst(2)) }
            let state = value["value"].map { $0.string ?? MSFormat.preview($0, max: 80) } ?? ""
            return [kind.isEmpty ? .none : .text(kind), .text(who), state.isEmpty ? .none : .text(state), seconds(value["updatedAt"])]
        }
    )

    private static let remindMe = KVSLayout(
        fields: [
            KVSField(id: "message", title: "Message ID", width: 380, personal: true),
            KVSField(id: "date", title: "Remind At", width: 130, kind: .date),
            KVSField(id: "display", title: "Shown As", width: 130, kind: .date),
            KVSField(id: "updated", title: "Updated", width: 130, kind: .date),
        ],
        initialSort: "date",
        decode: { key, value in
            guard let inner = value["value"], inner.dict != nil else { return fallback(4, key, value) }
            return [text(inner["message-id"]), seconds(inner["date"]), seconds(inner["display-date"]), seconds(value["updatedAt"])]
        }
    )

    private static let mailboxCategories = KVSLayout(
        fields: [
            KVSField(id: "mailbox", title: "Sender", width: 360, personal: true),
            KVSField(id: "category", title: "Category", width: 100),
            KVSField(id: "seen", title: "Last Seen", width: 130, kind: .date),
            KVSField(id: "updated", title: "Updated", width: 130, kind: .date),
        ],
        initialSort: "seen",
        decode: { key, value in
            guard let inner = value["value"], inner.dict != nil else { return fallback(4, key, value) }
            return [text(inner["mailbox"]), inner["category"]?.int.map { .text("Category \($0)") } ?? .none, seconds(inner["ls"]), seconds(value["updatedAt"])]
        }
    )

    private static let businesses = KVSLayout(
        fields: [
            KVSField(id: "business", title: "Business", width: 360, personal: true),
            KVSField(id: "categories", title: "Seen In", width: 200),
            KVSField(id: "seen", title: "Last Seen", width: 130, kind: .date),
            KVSField(id: "updated", title: "Updated", width: 130, kind: .date),
        ],
        initialSort: "seen",
        decode: { key, value in
            guard let inner = value["value"], inner.dict != nil else { return fallback(4, key, value) }
            let seen = inner["lastSeenDates"]?.dict ?? []
            var categories = seen.map(\.key)
            if let type = inner.value(at: "category", "type")?.int { categories.append("Category \(type)") }
            let dates = seen.compactMap { seconds($0.value).date }
            return [
                text(inner["id"]), categories.isEmpty ? .none : .text(categories.joined(separator: ", ")),
                latest(dates), seconds(value["updatedAt"]),
            ]
        }
    )
}
