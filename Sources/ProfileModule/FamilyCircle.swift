import SwiftUI
import DossierCore

// MARK: - Model

/// One member of the cached Family Sharing circle.
struct FamilyMember: Identifiable, Sendable, Hashable {
    let id: String
    let firstName: String
    let lastName: String
    let appleID: String
    let aliases: [String]
    let phones: String
    let birth: Date?
    let age: Int?
    let joined: Date?
    let type: String
    let displayLabel: String
    let status: String
    let isMe: Bool
    let isOrganizer: Bool
    let isParent: Bool
    let isChild: Bool
    let pending: Bool
    let purchaseSharing: Bool?
    let askToBuy: Bool?
    let linkedStoreAccount: String
    /// Every remaining field of the member dictionary (account identifiers, flags), for the inspector.
    let other: [(key: String, value: String)]

    static func == (a: FamilyMember, b: FamilyMember) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var name: String {
        let full = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? (appleID.isEmpty ? "Unnamed member" : appleID) : full
    }

    var role: String {
        if pending { return "Invited" }
        if isOrganizer { return "Organizer" }
        if isParent { return "Parent / Guardian" }
        if isChild { return "Child" }
        return type.isEmpty ? "Member" : type.capitalized
    }
}

struct FamilyCircle: Sendable {
    var members: [FamilyMember] = []
    /// Circle-level fields (family id, flags), for the self-test and the header.
    var properties: [(key: String, value: String)] = []
    var modified: Date?
}

// MARK: - Store

/// Reader for `~/Library/DuetExpertCenter/caches/familyCircleCache`: an NSKeyedArchiver
/// archive whose root is an `FAFamilyCircle`. `_members` is an array of `FAFamilyMember`
/// objects, each wrapping the server's member dictionary in `_dictionary` (keys such as
/// `member-first-name`, `member-apple-id`, `member-date-of-birth` and
/// `member-join-date-epoch` in Unix milliseconds, `member-type`, `is-me`). Invitations that
/// were not accepted yet sit in `__serverResponse › pending-members`.
enum FamilyStore {
    /// Throws `DossierError.missing` / `.inaccessible`; a Mac without Family Sharing has no file.
    static func load() throws -> FamilyCircle {
        let url = ProfilePaths.familyCircleCache
        switch Paths.probe(url) {
        case .missing: throw DossierError.missing("No Family Sharing cache exists on this Mac (DuetExpertCenter/caches/familyCircleCache). It is only written when the Apple Account belongs to a family group.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 16 << 20 else {
            throw DossierError.message("The Family Sharing cache could not be read.")
        }
        guard let root = PlistDecoder.decodeAny(data) else {
            throw DossierError.message("The Family Sharing cache is not a property list this version understands.")
        }
        return parse(root, modified: FileProbe.info(url)?.modified)
    }

    /// `nil` when the cache is missing, unreadable or undecodable (summary, search).
    static func loadIfAvailable() -> FamilyCircle? { try? load() }

    static func parse(_ root: PlistValue, modified: Date? = nil) -> FamilyCircle {
        var circle = FamilyCircle(modified: modified)
        var seen = Set<String>()
        func add(_ dictionary: PlistValue?, pending: Bool) {
            guard let dictionary, let member = member(dictionary, index: circle.members.count, pending: pending), seen.insert(member.id).inserted else { return }
            circle.members.append(member)
        }
        for item in root["_members"]?.array ?? [] { add(item["_dictionary"] ?? item, pending: false) }
        // Fallback for a layout without `_members`: the raw server response.
        if circle.members.isEmpty {
            for item in root.value(at: "__serverResponse", "family-members")?.array ?? [] { add(item, pending: false) }
        }
        for item in root.value(at: "__serverResponse", "pending-members")?.array ?? [] { add(item, pending: true) }
        for pair in root.dict ?? [] where pair.key != "$class" {
            switch pair.value {
            case .string, .int, .real, .bool:
                if let text = pair.value.string, !text.isEmpty { circle.properties.append((pair.key, text)) }
            default: break
            }
        }
        return circle
    }

    private static let shownKeys: Set<String> = [
        "member-first-name", "member-last-name", "member-apple-id", "member-appleID-aliases", "member-phone-numbers",
        "member-date-of-birth", "member-age", "member-join-date-epoch", "member-type", "member-display-label",
        "member-status", "is-me", "member-is-organizer", "member-is-parent-account", "member-is-child-account",
        "family-purchase-sharing-enabled", "is-ask-to-buy-enabled", "linked-itunes-account-appleid",
    ]

    private static func member(_ dictionary: PlistValue, index: Int, pending: Bool) -> FamilyMember? {
        guard let pairs = dictionary.dict, !pairs.isEmpty else { return nil }
        func text(_ key: String) -> String { dictionary[key]?.string ?? "" }
        /// Unix milliseconds (birth dates before 1970 are negative). `seconds`: lower bound
        /// below which a positive value can only be seconds (join dates, never before 2014).
        func date(_ key: String, secondsBelow: Double = 0) -> Date? {
            guard let value = dictionary[key] else { return nil }
            if let date = value.date { return date }
            guard let number = value.double, number != 0 else { return nil }
            return Date(timeIntervalSince1970: number > 0 && number < secondsBelow ? number : number / 1_000)
        }
        var other: [(String, String)] = []
        for pair in pairs where !shownKeys.contains(pair.key) && pair.key != "$class" {
            if let value = pair.value.string, !value.isEmpty { other.append((pair.key, value)) }
            else if let items = pair.value.array, !items.isEmpty { other.append((pair.key, items.compactMap(\.string).joined(separator: ", "))) }
        }
        let appleID = text("member-apple-id")
        let stable = [text("member-dsid"), text("member-altDSID"), appleID, text("member-invite-email")].first { !$0.isEmpty }
        return FamilyMember(
            id: stable ?? "member-\(index)-\(pending)",
            firstName: text("member-first-name"), lastName: text("member-last-name"), appleID: appleID.isEmpty ? text("member-invite-email") : appleID,
            aliases: dictionary["member-appleID-aliases"]?.array?.compactMap(\.string) ?? [],
            phones: text("member-phone-numbers"),
            birth: date("member-date-of-birth"), age: dictionary["member-age"]?.int.map { Int($0) }, joined: date("member-join-date-epoch", secondsBelow: 100_000_000_000),
            type: text("member-type"), displayLabel: text("member-display-label"), status: text("member-status"),
            isMe: dictionary["is-me"]?.bool ?? false,
            isOrganizer: dictionary["member-is-organizer"]?.bool ?? false,
            isParent: dictionary["member-is-parent-account"]?.bool ?? false,
            isChild: dictionary["member-is-child-account"]?.bool ?? false,
            pending: pending,
            purchaseSharing: dictionary["family-purchase-sharing-enabled"]?.bool,
            askToBuy: dictionary["is-ask-to-buy-enabled"]?.bool,
            linkedStoreAccount: text("linked-itunes-account-appleid"),
            other: other.map { (key: $0.0, value: $0.1) })
    }

    /// Birth dates are stored as an instant; show the calendar day in UTC so that the
    /// viewer's time zone cannot shift it across midnight.
    static func birthday(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .current))
    }

    static func yesNo(_ value: Bool?) -> String { value.map { $0 ? "On" : "Off" } ?? "—" }
}

// MARK: - View

/// "Family" tab of Contacts Intelligence: the Family Sharing circle macOS caches for
/// suggestions, with each member's Apple Account, date of birth and role.
struct FamilyTable: View {
    @Binding var filter: String
    @State private var selected: FamilyMember?

    var body: some View {
        AsyncContent(emptyTitle: "No Family Members", emptySymbol: "figure.2.and.child.holdinghands") {
            try FamilyStore.load()
        } isEmpty: { $0.members.isEmpty } content: { circle in
            PagedTable(
                rows: circle.members,
                columns: columns,
                searchPrompt: "Filter family members",
                reloadKey: circle.members.count,
                exportName: "family-sharing",
                emptyTitle: "No Family Members",
                filter: $filter,
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { inspector(selected, circle: circle) }
            }
        }
    }

    private var columns: [PagedColumn<FamilyMember>] {
        [
            PagedColumn<FamilyMember>("Member", width: 220, min: 140, sensitivity: .sensitive) { $0.name + ($0.isMe ? " (you)" : "") }
                .cell { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.isChild ? "figure.child" : "person.crop.circle").foregroundStyle(.secondary).frame(width: 16)
                        Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                        if row.isMe { TagLabel("You", tint: .blue) }
                    }
                },
            PagedColumn("Role", width: 130, sensitivity: .sensitive) { $0.role }
                .cell { row in
                    HStack(spacing: 5) {
                        if row.isOrganizer { Image(systemName: "crown.fill").foregroundStyle(.yellow).imageScale(.small) }
                        Text(row.role).font(.callout).lineLimit(1)
                    }
                },
            PagedColumn("Apple Account", width: 230, min: 120, sensitivity: .sensitive) { $0.appleID }
                .cell { Text($0.appleID).font(.callout).lineLimit(1).truncationMode(.middle) },
            PagedColumn("Age", width: 50, alignment: .trailing, sensitivity: .sensitive) { $0.age.map(String.init) ?? "—" },
            PagedColumn("Date of Birth", width: 120, sensitivity: .sensitive) { FamilyStore.birthday($0.birth) }
                .sortKey { $0.birth?.timeIntervalSince1970 ?? -.infinity },
            PagedColumn("Joined", width: 120, sensitivity: .sensitive) { DossierDate.day($0.joined) }
                .sortKey { $0.joined?.timeIntervalSince1970 ?? -.infinity },
            PagedColumn("Purchase Sharing", width: 116, sensitivity: .sensitive) { FamilyStore.yesNo($0.purchaseSharing) },
            PagedColumn("Ask to Buy", width: 84, sensitivity: .sensitive) { FamilyStore.yesNo($0.askToBuy) },
            PagedColumn("Phone", width: 140, sensitivity: .sensitive, hiddenByDefault: true) { $0.phones },
            PagedColumn("Aliases", width: 220, sensitivity: .sensitive, hiddenByDefault: true) { $0.aliases.joined(separator: ", ") },
            PagedColumn("Store Account", width: 220, sensitivity: .sensitive, hiddenByDefault: true) { $0.linkedStoreAccount },
            PagedColumn("Status", width: 90, sensitivity: .sensitive, secondary: true, hiddenByDefault: true) { $0.status },
        ]
    }

    private func inspector(_ member: FamilyMember, circle: FamilyCircle) -> some View {
        InspectorPage(title: member.name, subtitle: "Family Sharing · " + member.role + (member.isMe ? " · you" : ""), sensitivity: .sensitive, onClose: { selected = nil }) {
            KeyValueGrid([
                KeyValueItem("First name", member.firstName, sensitivity: .sensitive),
                KeyValueItem("Last name", member.lastName, sensitivity: .sensitive),
                KeyValueItem("Role", member.role + (member.displayLabel.isEmpty || member.displayLabel == member.role ? "" : "  (“\(member.displayLabel)”)"), sensitivity: .sensitive),
                KeyValueItem("Account type", member.type.isEmpty ? nil : member.type.capitalized, sensitivity: .sensitive),
                KeyValueItem("Status", member.status.isEmpty ? nil : member.status, sensitivity: .sensitive),
                KeyValueItem("Apple Account", member.appleID, sensitivity: .sensitive),
                KeyValueItem("Aliases", member.aliases.isEmpty ? nil : member.aliases.joined(separator: "\n"), sensitivity: .sensitive),
                KeyValueItem("Phone numbers", member.phones.isEmpty ? nil : member.phones, sensitivity: .sensitive),
                KeyValueItem("Date of birth", member.birth == nil ? nil : FamilyStore.birthday(member.birth), sensitivity: .sensitive),
                KeyValueItem("Age", member.age.map(String.init), sensitivity: .sensitive),
                KeyValueItem("Joined", member.joined.map { DossierDate.medium($0) + " (" + DossierDate.relative($0) + ")" }, sensitivity: .sensitive),
                KeyValueItem("Purchase sharing", FamilyStore.yesNo(member.purchaseSharing), sensitivity: .sensitive),
                KeyValueItem("Ask to Buy", FamilyStore.yesNo(member.askToBuy), sensitivity: .sensitive),
                KeyValueItem("Store account", member.linkedStoreAccount.isEmpty ? nil : member.linkedStoreAccount, sensitivity: .sensitive),
            ])
            if !member.other.isEmpty {
                InspectorGroupTitle("Other cached fields")
                KeyValueGrid(member.other.map { KeyValueItem($0.key, $0.value, sensitivity: .sensitive, monospaced: true, id: "other." + $0.key) })
            }
            if !circle.properties.isEmpty {
                InspectorGroupTitle("Family group")
                KeyValueGrid(circle.properties.map { KeyValueItem($0.key.trimmingCharacters(in: CharacterSet(charactersIn: "_")), $0.value, sensitivity: .sensitive, monospaced: true, id: "circle." + $0.key) })
            }
            Text("A copy of the Family Sharing roster from your Apple Account, cached on this Mac so that suggestions can recognise family members" + (circle.modified.map { "; last written " + DossierDate.relative($0) } ?? "") + ".")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
