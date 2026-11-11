import Foundation
import SwiftUI
import DossierCore

// MARK: - Triples and statements

/// One row of `stable_graph` / `event_graph` / `expired_*`.
///
/// The graph is a reified triple store: a row with `relationshipId == 0` is a plain
/// `subject —predicate→ object` fact. Rows sharing `subject + predicate + relationshipId`
/// (non-zero) together describe ONE structured fact (a "facet"), e.g. one phone number
/// with its label, where `relationshipPredicate` names the field and the `PS1` field gives
/// the facet's type. Objects of the form `md:<int64>` reference another node.
struct Triple: Sendable, Hashable {
    let subject: Int64
    let predicate: String
    let relationshipId: Int64
    let relPredicate: String
    let object: String
    let sources: Int64
    let confidence: Double
    let sourceDuplicates: String
    let timestamp: Double

    /// Referenced node id if the object is an `md:` reference.
    var objectReference: Int64? { GraphRef.parse(object) }
}

enum GraphRef {
    static func parse(_ object: String) -> Int64? {
        guard object.hasPrefix("md:") else { return nil }
        return Int64(object.dropFirst(3))
    }
    static func string(_ id: Int64) -> String { "md:\(id)" }
}

/// One logical statement about a node: either a simple triple or a facet (group of rows
/// sharing a relationshipId).
struct Statement: Identifiable, Sendable {
    struct Field: Sendable, Hashable, Identifiable {
        var id: String { predicate + "|" + object }
        let predicate: String
        let object: String
    }

    let id: String
    let predicate: String
    let relationshipId: Int64
    /// The facet's `PS1` value (relationship type class), nil for simple statements.
    let typeClass: String?
    /// Simple statement: one field with an empty predicate. Facet: its fields (without PS1).
    let fields: [Field]
    let sources: Int64
    let confidence: Double
    let timestamp: Double
    let sourceRecords: [String]

    var isFacet: Bool { relationshipId != 0 }
    var simpleValue: String? { isFacet ? nil : fields.first?.object }
    func field(_ predicate: String) -> String? { fields.first { $0.predicate == predicate }?.object }
    func fields(_ predicate: String) -> [String] { fields.filter { $0.predicate == predicate }.map(\.object) }

    /// Groups raw rows into statements, ordered by predicate then facet id.
    static func group(_ triples: [Triple]) -> [Statement] {
        var simple: [Statement] = []
        var facets: [String: [Triple]] = [:]
        var facetOrder: [String] = []
        for (i, t) in triples.enumerated() {
            if t.relationshipId == 0 {
                simple.append(Statement(
                    id: "s|\(t.predicate)|\(i)", predicate: t.predicate, relationshipId: 0, typeClass: nil,
                    fields: [Field(predicate: "", object: t.object)], sources: t.sources, confidence: t.confidence,
                    timestamp: t.timestamp, sourceRecords: SourceRecord.split(t.sourceDuplicates)))
            } else {
                let key = "\(t.predicate)|\(t.relationshipId)"
                if facets[key] == nil { facetOrder.append(key) }
                facets[key, default: []].append(t)
            }
        }
        var result = simple
        for key in facetOrder {
            guard let rows = facets[key], let first = rows.first else { continue }
            let type = rows.first { $0.relPredicate == "PS1" }?.object
            let fields = rows.filter { $0.relPredicate != "PS1" }
                .sorted { ($0.relPredicate, $0.object) < ($1.relPredicate, $1.object) }
                .map { Field(predicate: $0.relPredicate, object: $0.object) }
            var records: [String] = []
            var seen = Set<String>()
            for r in rows { for rec in SourceRecord.split(r.sourceDuplicates) where seen.insert(rec).inserted { records.append(rec) } }
            result.append(Statement(
                id: "f|\(key)", predicate: first.predicate, relationshipId: first.relationshipId, typeClass: type,
                fields: fields, sources: rows.reduce(0) { $0 | $1.sources },
                confidence: rows.map(\.confidence).min() ?? first.confidence,
                timestamp: rows.map(\.timestamp).max() ?? first.timestamp, sourceRecords: records))
        }
        return result
    }
}

/// `sourceDuplicates` lists the source records a row was merged from, joined by `^^`, each
/// `<kind>:<record id>` (e.g. `cnContact:<uuid>:ABPerson`).
enum SourceRecord {
    static func split(_ duplicates: String) -> [String] {
        guard !duplicates.isEmpty else { return [] }
        return duplicates.components(separatedBy: "^^").filter { !$0.isEmpty }
    }

    /// The record kind prefix (`cnContact`, `phPerson`, …) if the record has one.
    static func kind(_ record: String) -> String? {
        guard let colon = record.firstIndex(of: ":") else { return nil }
        let prefix = record[..<colon]
        guard !prefix.isEmpty, prefix.count <= 40, prefix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), prefix.first?.isLetter == true else { return nil }
        return String(prefix)
    }
}

// MARK: - Sources

/// Human-readable description of the systems that feed the graph. The bit → kind mapping
/// is derived at runtime from rows carrying a single source bit (their `sourceDuplicates`
/// prefix names the kind); this table only supplies friendly names for known kinds.
struct SourceCatalog: Sendable {
    /// bit index → record kind prefix (e.g. 0 → "cnContact").
    var kinds: [Int: String] = [:]

    struct Known { let title: String; let symbol: String; let tint: Color; let explanation: String }

    static let known: [String: Known] = [
        "cnContact": Known(title: "Contacts", symbol: "person.crop.circle", tint: .blue, explanation: "A card in the Contacts database (CNContact)."),
        "phPerson": Known(title: "Photos People", symbol: "face.smiling", tint: .purple, explanation: "A person recognised in the Photos library (PHPerson)."),
        "ekEvent": Known(title: "Calendar", symbol: "calendar", tint: .red, explanation: "A calendar event (EventKit)."),
        "faFamilyCircle": Known(title: "Family Sharing", symbol: "figure.2.and.child.holdinghands", tint: .green, explanation: "The iCloud Family Sharing circle."),
        "lsBundleRecord": Known(title: "Installed Apps", symbol: "app.badge", tint: .teal, explanation: "An application record from Launch Services."),
        "pgRelationship": Known(title: "Photos Graph", symbol: "point.3.connected.trianglepath.dotted", tint: .pink, explanation: "A relationship inferred by the Photos knowledge graph."),
        "pgPerson": Known(title: "Photos Graph", symbol: "point.3.connected.trianglepath.dotted", tint: .pink, explanation: "A person node of the Photos knowledge graph."),
        "pgEvent": Known(title: "Photos Events", symbol: "photo.on.rectangle", tint: .pink, explanation: "An event from the Photos knowledge graph."),
        "sgContact": Known(title: "Siri Suggestions", symbol: "sparkles", tint: .orange, explanation: "A contact found in apps by Siri Suggestions."),
        "sgEvent": Known(title: "Found in Apps", symbol: "sparkles", tint: .orange, explanation: "An event found in mail or messages."),
        "inPerson": Known(title: "App Intents", symbol: "bubble.left.and.bubble.right", tint: .indigo, explanation: "A person donated through an app interaction."),
        "inGroup": Known(title: "App Intents", symbol: "bubble.left.and.bubble.right", tint: .indigo, explanation: "A conversation group donated by an app."),
        "hmHome": Known(title: "Home", symbol: "house", tint: .yellow, explanation: "A HomeKit home."),
        "rtVisit": Known(title: "Significant Locations", symbol: "location", tint: .mint, explanation: "A visit recorded by location routines."),
        "rtLocationOfInterest": Known(title: "Significant Locations", symbol: "location", tint: .mint, explanation: "A location of interest learned by routined."),
        "ppContact": Known(title: "Portrait", symbol: "person.text.rectangle", tint: .brown, explanation: "Personalization Portrait contact signal."),
        "ppTopic": Known(title: "Portrait Topics", symbol: "text.badge.star", tint: .brown, explanation: "Personalization Portrait topic."),
        "ppLocation": Known(title: "Portrait Locations", symbol: "mappin", tint: .brown, explanation: "Personalization Portrait location."),
    ]

    func bits(of mask: Int64) -> [Int] {
        (0..<63).filter { mask & (Int64(1) << Int64($0)) != 0 }
    }

    func kind(bit: Int) -> String? { kinds[bit] }

    func title(bit: Int) -> String {
        if let kind = kinds[bit] { return Self.known[kind]?.title ?? kind }
        return "Source \(bit + 1)"
    }

    func tint(bit: Int) -> Color {
        if let kind = kinds[bit], let known = Self.known[kind] { return known.tint }
        return ChartPalette.color(bit)
    }

    func symbol(bit: Int) -> String {
        if let kind = kinds[bit], let known = Self.known[kind] { return known.symbol }
        return "circle.hexagongrid"
    }

    func titles(mask: Int64) -> [String] { bits(of: mask).map(title(bit:)) }

    static func title(kind: String) -> String { known[kind]?.title ?? kind }
}

// MARK: - Ontology

/// Labels from `ontology.db` (`class` and `predicate` tables: `id → label`).
struct Ontology: Sendable {
    var classLabels: [String: String] = [:]
    var predicateLabels: [String: String] = [:]

    static let empty = Ontology()

    func predicateLabel(_ id: String) -> String {
        if let label = predicateLabels[id], !label.isEmpty { return label }
        return Self.prettify(id)
    }

    func classLabel(_ id: String) -> String {
        if let label = classLabels[id], !label.isEmpty { return label }
        return Self.prettify(id)
    }

    func isClass(_ id: String) -> Bool { classLabels[id] != nil }

    /// `nm_entityAliasRelationship` → "entity alias relationship"; codes stay as they are.
    static func prettify(_ id: String) -> String {
        var s = Substring(id)
        if s.hasPrefix("nm_") { s = s.dropFirst(3) } else { return id }
        var out = ""
        for ch in s {
            if ch == "_" { out.append(" ") }
            else if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" "); out.append(contentsOf: ch.lowercased()) }
            else { out.append(ch) }
        }
        return out
    }
}

// MARK: - Entities

/// Broad node categories used for colouring and filtering. Raw class ids are kept on the
/// entity; this is only the coarse grouping.
enum EntityKind: String, CaseIterable, Sendable, Identifiable {
    case person, software, place, organization, group, event, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .person: return "People"
        case .software: return "Software"
        case .place: return "Places"
        case .organization: return "Organizations"
        case .group: return "Groups"
        case .event: return "Events"
        case .other: return "Other"
        }
    }

    var singular: String {
        switch self {
        case .person: return "Person"
        case .software: return "Software"
        case .place: return "Place"
        case .organization: return "Organization"
        case .group: return "Group"
        case .event: return "Event"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .person: return "person.fill"
        case .software: return "app.fill"
        case .place: return "mappin.and.ellipse"
        case .organization: return "building.2.fill"
        case .group: return "person.3.fill"
        case .event: return "calendar"
        case .other: return "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .person: return .blue
        case .software: return .teal
        case .place: return .green
        case .organization: return .orange
        case .group: return .purple
        case .event: return .red
        case .other: return .gray
        }
    }

    /// Maps an ontology class id + label to a kind. Uses the label (stable wording across
    /// ontology versions) with the well-known codes as a fallback.
    static func from(classID: String, label: String?) -> EntityKind {
        let l = (label ?? "").lowercased()
        switch classID {
        case "SB104": return .person
        case "SB144": return .software
        case "SB152": return .place
        case "SB10": return .organization
        case "SB2": return .group
        case "SB472", "SB65": return .event
        default: break
        }
        if l == "person" || l == "human" { return .person }
        if l.contains("software") || l.contains("application") { return .software }
        if l.contains("place") || l.contains("location") { return .place }
        if l.contains("organization") || l.contains("company") { return .organization }
        if l.contains("group") { return .group }
        if l.contains("event") || l.contains("meeting") { return .event }
        return .other
    }
}

struct EntityInfo: Identifiable, Sendable, Hashable {
    let id: Int64
    var classID: String
    var kind: EntityKind
    var name: String
    /// Secondary line: bundle id, city, …
    var detail: String
    var rowCount: Int
    var sources: Int64
    var confidence: Double
    var updated: Double
    var isOwner: Bool
    var outgoing: Int = 0
    var incoming: Int = 0

    var updatedDate: Date? { updated > 0 ? DossierDate.cocoa(updated) : nil }
}

/// A node → node link (an `md:` reference).
struct GraphEdge: Sendable, Hashable {
    let from: Int64
    let to: Int64
    /// The statement predicate (`PS500` employer, `PS225` location, …).
    let predicate: String
    /// The facet field holding the reference (empty for simple triples).
    let relPredicate: String
}

// MARK: - Value formatting

enum GraphFormat {
    /// Contacts encodes built-in labels as `_$!<Home>!$_`; returns the inner word.
    static func cleanLabel(_ raw: String) -> String {
        guard raw.hasPrefix("_$!<"), raw.hasSuffix(">!$_") else { return raw }
        let inner = raw.dropFirst(4).dropLast(4)
        // "FemaleFriend" → "Female Friend"
        var out = ""
        for ch in inner {
            if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// Decodes the JSON date-components objects stored for dates
    /// (`{"year":…,"month":…,"day":…,"hour":…,"timeZone":{"identifier":…}}`).
    static func dateComponents(_ json: String) -> (components: DateComponents, text: String)? {
        guard json.hasPrefix("{"), let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Some values nest the components one level down (e.g. under "dateComponents").
        var dict = object
        if dict["year"] == nil && dict["month"] == nil && dict["day"] == nil {
            guard let nested = object.values.compactMap({ $0 as? [String: Any] }).first(where: { $0["month"] != nil || $0["year"] != nil }) else { return nil }
            dict = nested
        }
        var c = DateComponents()
        c.year = dict["year"] as? Int
        c.month = dict["month"] as? Int
        c.day = dict["day"] as? Int
        c.hour = dict["hour"] as? Int
        c.minute = dict["minute"] as? Int
        var zoneName: String?
        if let tz = dict["timeZone"] as? [String: Any], let identifier = tz["identifier"] as? String {
            zoneName = identifier
            c.timeZone = TimeZone(identifier: identifier)
        }
        guard c.month != nil || c.year != nil else { return nil }
        var text = ""
        if let y = c.year, let m = c.month, let d = c.day {
            text = String(format: "%04d-%02d-%02d", y, m, d)
        } else if let m = c.month, let d = c.day {
            let names = Calendar.current.monthSymbols
            text = "\(d) \(names.indices.contains(m - 1) ? names[m - 1] : "month \(m)") (no year)"
        } else if let y = c.year {
            text = "\(y)"
        }
        if let h = c.hour {
            text += String(format: " %02d:%02d", h, c.minute ?? 0)
        }
        if let zoneName, c.hour != nil { text += " " + zoneName }
        return (c, text)
    }

    static func looksLikeTimestamp(_ predicate: String, _ label: String) -> Bool {
        let l = label.lowercased() + " " + predicate.lowercased()
        return l.contains("time") || l.contains("date") || l.contains("birthday") || l.contains("timestamp")
    }

    /// Display text for a statement object.
    static func display(_ object: String, predicate: String, ontology: Ontology, name: (Int64) -> String?) -> String {
        if let ref = GraphRef.parse(object) { return name(ref) ?? "Unknown node" }
        if object.hasPrefix("_$!<") { return cleanLabel(object) }
        if object.hasPrefix("{"), let decoded = dateComponents(object) { return decoded.text }
        if let label = ontology.classLabels[object] { return label }
        if looksLikeTimestamp(predicate, ontology.predicateLabel(predicate)), let v = Double(object), v > 1e8, v < 2e9 {
            return DossierDate.medium(DossierDate.cocoa(v))
        }
        if object.contains("\t") { return object.replacingOccurrences(of: "\t", with: " ") }
        return object
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func confidence(_ v: Double) -> String {
        if v >= 0.9995 { return "100%" }
        return String(format: "%.0f%%", v * 100)
    }

    /// Sensitivity of a value given its predicate: structural type information is
    /// technical, everything else describes a real person or their things.
    static func sensitivity(predicate: String, object: String, ontology: Ontology) -> Sensitivity {
        if predicate == "PS1" || predicate == "PS396" || predicate == "nm_signalLabel" || predicate == "nm_associationReason" { return .low }
        if ontology.classLabels[object] != nil { return .low }
        return .sensitive
    }
}

// MARK: - Well-known ontology codes
//
// Generic Apple ontology identifiers this module relies on (labels come from ontology.db
// at runtime; these are only used to pick out structure):
//   PS1 "is a" · PS33 name · PS102 "same as" (source record) · PS312 first name ·
//   PS441 family name · PS546 middle name · PS89 "also known as" · PS72 identifier
//   (PS396 type, PS69 id, PS313 username, PS66 URL) · PS520 contact information
//   (PS406 e-mail, PS407 phone, PS740 label) · PS317 address (PS316 street, PS453 city,
//   PS315 postal code, PS450 country, PS455 district) · PS225 location relationship
//   (PS107 → place, PS733 personalised label) · PS598 association (nm_personIdentifier,
//   nm_relationshipLabel, nm_confidence) · PS500 employer (PS45 → organization) ·
//   PS753 group membership (PS566 → member) · PS194 published by · PS37 date of birth ·
//   PS232 attendee / PS578 organizer (PS143 → person, PS734 obligation) · nm_hasDate
//   (PS29 start, PS30 end, nm_imputedStartTime / nm_imputedEndTime as Cocoa seconds).
enum P {
    static let isA = "PS1", name = "PS33", sameAs = "PS102", firstName = "PS312", familyName = "PS441"
    static let middleName = "PS546", alsoKnownAs = "PS89", identifier = "PS72", identifierType = "PS396", identifierID = "PS69"
    static let username = "PS313", sourceURL = "PS66", contact = "PS520", email = "PS406", phone = "PS407", contactLabel = "PS740"
    static let address = "PS317", street = "PS316", city = "PS453", postalCode = "PS315", country = "PS450"
    static let locationRel = "PS225", hasLocation = "PS107", personalLabel = "PS733"
    static let association = "PS598", employer = "PS500", memberOf = "PS45", groupIncludes = "PS753", groupPart = "PS566"
    static let publishedBy = "PS194", dateOfBirth = "PS37", url = "PS296"
    static let attendee = "PS232", organizer = "PS578", attendeeID = "PS143", obligation = "PS734"
    static let startTime = "PS29", endTime = "PS30"
    static let currentUser = "nm_isCurrentUser", bundleID = "nm_bundleID", alias = "nm_entityAliasRelationship"
    static let visual = "nm_hasVisualIdentifier", hasDate = "nm_hasDate", conferenceURL = "nm_virtualConferenceURL"
}
