import Foundation
import DossierCore

// MARK: - Models

struct PseudoContact: Identifiable, Sendable, Hashable {
    let id: Int64
    let name: String
    let details: String
    let detailCount: Int
    let created: Date?
    let lastSeen: Date?
    let entityKey: String
    let entityType: Int
}

struct ContactDetailRow: Identifiable, Sendable, Hashable {
    let id: Int64
    let value: String
    let label: String
    let confidence: Double?
    var kind: String {
        if value.contains("@") { return "E-mail" }
        let digits = value.filter(\.isNumber).count
        if digits >= 5 && digits * 2 >= value.count { return "Phone" }
        return "Address / other"
    }
}

struct PseudoContactDetail: Sendable {
    var details: [ContactDetailRow] = []
    var references: [(bundle: String, identifier: String)] = []
    var tags: [SuggestionTag] = []
}

/// One tag of a Suggestions entity (`PREFIX:value`), with a readable prefix meaning.
struct SuggestionTag: Identifiable, Sendable, Hashable {
    let id: Int
    let prefix: String
    let value: String

    static let meanings: [String: String] = [
        "AMSG": "Source message", "MBOX": "Mailbox", "CD": "Contact detail", "ID": "Identity key",
        "EHSH": "Event hash", "EX": "Extraction", "SO": "schema.org data", "TMPN": "Template",
        "DOM": "Sender domain", "IBID": "Donating app", "ITID": "Developer team", "IUID": "Interaction id",
        "IRIR": "Intent response (archive)", "IRCR": "Intent request (archive)", "WPD": "Wallet pass archive",
        "WPDD": "Wallet pass summary", "ICSD": "Calendar invitation (ICS)", "EVNTC": "Event count",
        "EM": "Event metadata", "ET": "Extracted entity type", "MSG": "Message id",
    ]
    var meaning: String { SuggestionTag.meanings[prefix] ?? (prefix.isEmpty ? "Flag" : prefix) }

    static func parse(_ raw: String, id: Int) -> SuggestionTag {
        if let colon = raw.firstIndex(of: ":"), raw.distance(from: raw.startIndex, to: colon) <= 6 {
            return SuggestionTag(id: id, prefix: String(raw[..<colon]), value: String(raw[raw.index(after: colon)...]))
        }
        return SuggestionTag(id: id, prefix: "", value: raw)
    }
}

struct SuggestedEvent: Identifiable, Sendable, Hashable {
    let id: Int64
    let entityID: Int64
    let title: String
    let start: Date?
    let end: Date?
    let created: Date?
    let category: String
    let domain: String
    let app: String
    let cancelled: Bool
    let allDay: Bool
    let origin: String
}

struct EventLocation: Identifiable, Sendable, Hashable {
    let id: Int64
    let label: String
    let address: String
    let airport: String
    let latitude: Double?
    let longitude: Double?
}

struct SuggestedEventDetail: Sendable {
    var schemaItems: [[(String, String)]] = []
    var metadata: [(String, String)] = []
    var locations: [EventLocation] = []
    var tags: [SuggestionTag] = []
    var ics: String?
    var content: String?
}

struct WalletPassRow: Identifiable, Sendable, Hashable {
    let id: Int64
    let title: String
    let organization: String
    let description: String
    let state: String
    let serial: String
    let url: String
    let created: Date?
    let archiveBytes: Int
    let entityKey: String
}

struct WalletPassDetail: Sendable {
    var style = ""
    var organization = ""
    var description = ""
    var logoText = ""
    var relevantDate = ""
    var expirationDate = ""
    var voided = false
    var passType = ""
    var team = ""
    var serial = ""
    var webService = ""
    var authenticationToken = ""
    var background: String?
    var foreground: String?
    var label: String?
    var groups: [(name: String, fields: [(label: String, value: String)])] = []
    var barcodes: [(format: String, message: String)] = []
    var locations: [(latitude: Double, longitude: Double, text: String)] = []
    var files: [(name: String, size: Int)] = []
    var logo: Data?
    var archiveBytes = 0
}

struct HarvestedURL: Identifiable, Sendable, Hashable {
    let id: Int64
    let url: String
    let title: String
    let documentTitle: String
    let handle: String
    let bundle: String
    let date: Date?
    let flags: Int
    let secrets: [String]
    var host: String { ProfileFormat.host(url) }
}

struct SnippetRow: Identifiable, Sendable, Hashable {
    let id: String
    let kind: String
    let reference: Int64
    let title: String
    let content: String
}

struct OwnAddress: Identifiable, Sendable, Hashable {
    var id: String { address }
    let address: String
    let messages: Int
    let last: Date?
}

struct LearnedName: Identifiable, Sendable, Hashable {
    let id: String
    let handle: String
    let name: String
    let source: String
}

struct SuggestionCounts: Sendable {
    var contacts = 0
    var events = 0
    var passes = 0
    var urls = 0
    var secretURLs = 0
    var mailSnippets = 0
    var entitySnippets = 0
    var emails = 0
    var timeRange: ClosedRange<Date>?
}

enum MailKind: String, CaseIterable, Identifiable, Sendable {
    case contacts = "Contacts"
    case events = "Events"
    case passes = "Wallet Passes"
    case urls = "Links"
    case snippets = "Snippets"
    var id: String { rawValue }
}

// MARK: - Store

/// Read-only access to `~/Library/Suggestions` ("Siri found in apps"): `entities.db` holds
/// contacts, events, wallet passes and links that `suggestd` extracted from Mail / Messages;
/// `snippets.db` keeps the text excerpts they were found in.
///
/// Entity types (`entity.entityType`): 2 event, 4 pseudo-contact, 5 e-mail, 26 wallet pass.
/// Timestamps are Unix seconds.
enum SuggestionsStore {
    static let contactType = 4, eventType = 2, passType = 26

    static func database(_ url: URL = ProfilePaths.suggestionsDB) async throws -> SQLiteDB {
        switch Paths.probe(url) {
        case .missing: throw DossierError.missing("\(url.lastPathComponent) does not exist in ~/Library/Suggestions on this Mac.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        do { return try await SQLiteDB.shared(url) } catch let error as SQLiteError {
            if error.isAccessProblem { throw DossierError.inaccessible(error.localizedDescription) }
            throw DossierError.message(error.localizedDescription)
        }
    }

    private static func require(_ db: SQLiteDB, _ table: String, _ columns: [String]) async throws {
        guard await db.hasColumns(table, columns) else {
            throw DossierError.missing("Table \(table) is missing or has a different layout on this macOS version.")
        }
    }

    private static func page(_ limit: Int, _ offset: Int) -> [SQLValue] { [.integer(Int64(limit)), .integer(Int64(offset))] }

    // MARK: Counts

    static func counts() async throws -> SuggestionCounts {
        let db = try await database()
        var counts = SuggestionCounts()
        if await db.hasColumns("entity", ["entityType"]) {
            counts.contacts = await db.count("SELECT count(*) FROM entity WHERE entityType = \(contactType)") ?? 0
            counts.passes = await db.count("SELECT count(*) FROM entity WHERE entityType = \(passType)") ?? 0
            if let row = try? await db.first("SELECT min(creationTimestamp), max(creationTimestamp) FROM entity WHERE creationTimestamp > 0"),
               let lo = row[0].unixDate, let hi = row[1].unixDate, lo <= hi { counts.timeRange = lo...hi }
        }
        counts.events = await db.rowCount(of: "events") ?? 0
        counts.urls = await db.rowCount(of: "urls") ?? 0
        counts.emails = await db.rowCount(of: "emailMetadata") ?? 0
        if await db.hasColumns("urls", ["url"]) {
            counts.secretURLs = (try? await db.reduce("SELECT url FROM urls LIMIT 200000", into: 0) { acc, row in
                if let url = row[0].string, !ProfileFormat.secretParameters(in: url).isEmpty { acc += 1 }
            }) ?? 0
        }
        if let snippets = try? await database(ProfilePaths.snippetsDB) {
            counts.mailSnippets = await snippets.rowCount(of: "emailSnippets") ?? 0
            counts.entitySnippets = await snippets.rowCount(of: "snippets") ?? 0
        }
        return counts
    }

    // MARK: Pseudo-contacts

    private static let contactSorts: [String: String] = [
        "title": "e.title COLLATE NOCASE", "details": "n", "created": "e.creationTimestamp", "lastSeen": "e.lastSeenTimestamp",
    ]

    private static func contactFilter(_ search: String, hasDetails: Bool) -> (String, [SQLValue]) {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return ("", []) }
        let pattern = SQLValue.text(ProfileFormat.like(text))
        if hasDetails {
            return (" AND (e.title LIKE ? ESCAPE '\\' OR EXISTS(SELECT 1 FROM contactDetails c WHERE c.entityId = e.id AND c.value LIKE ? ESCAPE '\\'))", [pattern, pattern])
        }
        return (" AND e.title LIKE ? ESCAPE '\\'", [pattern])
    }

    static func contacts(offset: Int, limit: Int, sort: PageSort?, search: String) async throws -> [PseudoContact] {
        let db = try await database()
        try await require(db, "entity", ["id", "entityType", "title", "entityKey", "creationTimestamp", "lastSeenTimestamp"])
        let hasDetails = await db.hasColumns("contactDetails", ["entityId", "value"])
        let filter = contactFilter(search, hasDetails: hasDetails)
        let column = sort.flatMap { contactSorts[$0.columnID] } ?? "e.lastSeenTimestamp"
        let direction = sort?.sqlDirection ?? "DESC"
        let sql = """
            SELECT e.id, e.title, e.creationTimestamp, e.lastSeenTimestamp, e.entityKey, e.entityType,
                   \(hasDetails ? "(SELECT group_concat(c.value, ', ') FROM contactDetails c WHERE c.entityId = e.id)" : "NULL") AS details,
                   \(hasDetails ? "(SELECT count(*) FROM contactDetails c WHERE c.entityId = e.id)" : "0") AS n
            FROM entity e WHERE e.entityType = \(contactType)\(filter.0)
            ORDER BY \(column) \(direction), e.id LIMIT ? OFFSET ?
            """
        return try await db.query(sql, filter.1 + page(limit, offset), cellByteLimit: 600).rows.map { row in
            PseudoContact(id: row[0].int ?? 0, name: row[1].string ?? "", details: row[6].string ?? "", detailCount: Int(row[7].int ?? 0),
                          created: row[2].unixDate, lastSeen: row[3].unixDate, entityKey: row[4].string ?? "", entityType: Int(row[5].int ?? 0))
        }
    }

    static func contactCount(search: String) async throws -> Int {
        let db = try await database()
        let filter = contactFilter(search, hasDetails: await db.hasColumns("contactDetails", ["entityId", "value"]))
        return await db.count("SELECT count(*) FROM entity e WHERE e.entityType = \(contactType)\(filter.0)", filter.1) ?? 0
    }

    static func contactDetail(_ contact: PseudoContact) async throws -> PseudoContactDetail {
        let db = try await database()
        var detail = PseudoContactDetail()
        if await db.hasColumns("contactDetails", ["id", "entityId", "value", "label"]) {
            let hasInfoID = await db.hasColumns("contactDetails", ["extractionInfoId"])
            let hasInfos = await db.hasColumns("extractionInfos", ["id", "confidence"])
            let withInfo = hasInfoID && hasInfos
            let sql = withInfo
                ? "SELECT c.id, c.value, c.label, x.confidence FROM contactDetails c LEFT JOIN extractionInfos x ON x.id = c.extractionInfoId WHERE c.entityId = ? LIMIT 200"
                : "SELECT c.id, c.value, c.label, NULL FROM contactDetails c WHERE c.entityId = ? LIMIT 200"
            detail.details = try await db.rows(sql, [.integer(contact.id)]).map {
                ContactDetailRow(id: $0[0].int ?? 0, value: $0[1].string ?? "", label: $0[2].string ?? "", confidence: $0[3].double)
            }
        }
        if await db.hasColumns("entityReferences", ["entityId", "bundleIdentifier", "uniqueIdentifier"]) {
            detail.references = (try? await db.rows("SELECT bundleIdentifier, uniqueIdentifier FROM entityReferences WHERE entityId = ? LIMIT 50", [.integer(contact.id)]))?
                .map { ($0[0].string ?? "", $0[1].string ?? "") } ?? []
        }
        detail.tags = await entityTags(db, key: contact.entityKey, type: contact.entityType)
        return detail
    }

    private static func entityTags(_ db: SQLiteDB, key: String, type: Int) async -> [SuggestionTag] {
        guard await db.hasColumns("entityTags", ["tag", "entityKey", "entityType"]) else { return [] }
        let rows = (try? await db.query("SELECT tag FROM entityTags WHERE entityKey = ? AND entityType = ? LIMIT 200",
                                        [.text(key), .integer(Int64(type))], cellByteLimit: 400).rows) ?? []
        return rows.enumerated().map { SuggestionTag.parse($0.element[0].string ?? "", id: $0.offset) }
    }

    // MARK: Events

    private static let eventSorts: [String: String] = [
        "title": "title COLLATE NOCASE", "start": "e.timeRangeStart", "end": "e.timeRangeEnd", "created": "e.creationTimestamp",
    ]

    static func events(offset: Int, limit: Int, sort: PageSort?, search: String) async throws -> [SuggestedEvent] {
        let db = try await database()
        try await require(db, "events", ["id", "entityId", "title"])
        try await require(db, "entity", ["id", "title", "timeRangeStart", "timeRangeEnd", "creationTimestamp"])
        let hasTags = await db.hasColumns("eventTags", ["eventId", "name"])
        let text = search.trimmingCharacters(in: .whitespaces)
        let column = sort.flatMap { eventSorts[$0.columnID] } ?? "e.timeRangeStart"
        let direction = sort?.sqlDirection ?? "DESC"
        let tags = hasTags
            ? "(SELECT group_concat(substr(t.name, 1, 120), char(31)) FROM eventTags t WHERE t.eventId = v.id AND substr(t.name, 1, 3) NOT IN ('SO:', 'EM:', 'IRI', 'IRC', 'ICS', 'EHS'))"
            : "NULL"
        let sql = """
            SELECT v.id, v.entityId, coalesce(nullif(v.title, ''), e.title, '') AS title, e.timeRangeStart, e.timeRangeEnd,
                   e.creationTimestamp, \(tags) AS tags
            FROM events v LEFT JOIN entity e ON e.id = v.entityId
            \(text.isEmpty ? "" : "WHERE coalesce(nullif(v.title, ''), e.title, '') LIKE ? ESCAPE '\\'")
            ORDER BY \(column) \(direction), v.id LIMIT ? OFFSET ?
            """
        let params: [SQLValue] = (text.isEmpty ? [] : [.text(ProfileFormat.like(text))]) + page(limit, offset)
        return try await db.rows(sql, params).map { row in
            let tags = (row[6].string ?? "").split(separator: "\u{1f}").map(String.init)
            var category = "", domain = "", app = "", origin = ""
            for tag in tags {
                if tag.hasPrefix("EX:") { category = tag.dropFirst(3).split(separator: "|").first.map(String.init) ?? category }
                else if tag.hasPrefix("DOM:") { domain = String(tag.dropFirst(4)) }
                else if tag.hasPrefix("IBID:") { app = String(tag.dropFirst(5)) }
                else if tag == "fromSync" { origin = "Synced from another device" }
                else if tag == "fromInteraction" { origin = "App interaction" }
                else if tag == "ics" { origin = "Calendar invitation" }
                else if tag.hasPrefix("ex"), category.isEmpty { category = String(tag.dropFirst(2)) }
            }
            return SuggestedEvent(
                id: row[0].int ?? 0, entityID: row[1].int ?? 0, title: row[2].string ?? "", start: row[3].unixDate, end: row[4].unixDate,
                created: row[5].unixDate, category: readableCategory(category), domain: domain, app: app,
                cancelled: tags.contains("cancel"), allDay: tags.contains("allDay"), origin: origin)
        }
    }

    /// "carRental" → "Car Rental".
    static func readableCategory(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var out = ""
        for (index, ch) in raw.enumerated() {
            if ch.isUppercase, index > 0 { out.append(" ") }
            out.append(index == 0 ? Character(ch.uppercased()) : ch)
        }
        return out
    }

    static func eventCount(search: String) async throws -> Int {
        let db = try await database()
        let text = search.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return await db.rowCount(of: "events") ?? 0 }
        return await db.count("""
            SELECT count(*) FROM events v LEFT JOIN entity e ON e.id = v.entityId
            WHERE coalesce(nullif(v.title, ''), e.title, '') LIKE ? ESCAPE '\\'
            """, [.text(ProfileFormat.like(text))]) ?? 0
    }

    static func eventDetail(_ event: SuggestedEvent) async throws -> SuggestedEventDetail {
        let db = try await database()
        var detail = SuggestedEventDetail()
        if await db.hasColumns("eventTags", ["eventId", "name"]) {
            let rows = try await db.query("SELECT name FROM eventTags WHERE eventId = ? LIMIT 400", [.integer(event.id)], cellByteLimit: 256 << 10).rows
            var index = 0
            for row in rows {
                guard let raw = row[0].string else { continue }
                if raw.hasPrefix("SO:"), let json = PlistDecoder.decodeJSON(Data(raw.dropFirst(3).utf8)) {
                    for item in json.array ?? [json] { detail.schemaItems.append(JSONFlattener.flatten(item)) }
                } else if raw.hasPrefix("EM:"), let json = PlistDecoder.decodeJSON(Data(raw.dropFirst(3).utf8)) {
                    for pair in json.dict ?? [] where pair.key != "SGEventMetadataSchemaOrgKey" {
                        let key = pair.key.replacingOccurrences(of: "SGEventMetadata", with: "").replacingOccurrences(of: "Key", with: "")
                        let value = pair.value.string ?? pair.value.int.map(String.init) ?? pair.value.double.map { String($0) }
                        if let value, !value.isEmpty { detail.metadata.append((JSONFlattener.readable(key), value)) }
                    }
                } else if raw.hasPrefix("ICSD:"), let data = Data(base64Encoded: String(raw.dropFirst(5))) {
                    detail.ics = String(decoding: data.prefix(64 << 10), as: UTF8.self)
                } else {
                    var tag = SuggestionTag.parse(raw, id: index)
                    if tag.value.count > 160 { tag = SuggestionTag(id: index, prefix: tag.prefix, value: "\(tag.value.prefix(48))…  (\(tag.value.count) characters)") }
                    detail.tags.append(tag)
                    index += 1
                }
            }
        }
        if await db.hasColumns("locations", ["id", "eventId", "label", "address", "latitude", "longitude"]) {
            let airport = await db.hasColumns("locations", ["airportCode"]) ? "airportCode" : "NULL"
            detail.locations = try await db.rows("SELECT id, label, address, \(airport), latitude, longitude FROM locations WHERE eventId = ? LIMIT 50", [.integer(event.id)]).map {
                let lat = $0[4].double, lon = $0[5].double
                let valid = lat != nil && lon != nil && !(lat == 0 && lon == 0)
                return EventLocation(id: $0[0].int ?? 0, label: $0[1].string ?? "", address: $0[2].string ?? "", airport: $0[3].string ?? "",
                                     latitude: valid ? lat : nil, longitude: valid ? lon : nil)
            }
        }
        if await db.hasColumns("events", ["content"]),
           let content = try await db.scalar("SELECT substr(content, 1, 4000) FROM events WHERE id = ?", [.integer(event.id)]).string, !content.isEmpty {
            detail.content = content
        }
        return detail
    }

    // MARK: Wallet passes

    private static let passSorts: [String: String] = ["title": "e.title COLLATE NOCASE", "created": "e.creationTimestamp", "size": "size"]

    static func passes(offset: Int, limit: Int, sort: PageSort?, search: String) async throws -> [WalletPassRow] {
        let db = try await database()
        try await require(db, "entity", ["id", "entityType", "title", "entityKey", "creationTimestamp"])
        try await require(db, "entityTags", ["tag", "entityKey", "entityType"])
        let text = search.trimmingCharacters(in: .whitespaces)
        let column = sort.flatMap { passSorts[$0.columnID] } ?? "e.creationTimestamp"
        let direction = sort?.sqlDirection ?? "DESC"
        let tag = "FROM entityTags t WHERE t.entityKey = e.entityKey AND t.entityType = e.entityType AND"
        let sql = """
            SELECT e.id, e.title, e.creationTimestamp, e.entityKey,
                   (SELECT substr(t.tag, 6, 4000) \(tag) t.tag LIKE 'WPDD:%' LIMIT 1) AS info,
                   (SELECT length(t.tag) \(tag) t.tag LIKE 'WPD:%' LIMIT 1) AS size
            FROM entity e WHERE e.entityType = \(passType)
            \(text.isEmpty ? "" : "AND (e.title LIKE ? ESCAPE '\\' OR EXISTS(SELECT 1 \(tag) t.tag LIKE 'WPDD:%' AND t.tag LIKE ? ESCAPE '\\'))")
            ORDER BY \(column) \(direction), e.id LIMIT ? OFFSET ?
            """
        let pattern = SQLValue.text(ProfileFormat.like(text))
        return try await db.rows(sql, (text.isEmpty ? [] : [pattern, pattern]) + page(limit, offset)).map { row in
            let info = row[4].string.flatMap { PlistDecoder.decodeJSON(Data($0.utf8)) }
            func field(_ key: String) -> String { info?[key]?.string ?? "" }
            // base64 length → archive bytes
            let size = max(0, Int(row[5].int ?? 0) - 4) * 3 / 4
            return WalletPassRow(
                id: row[0].int ?? 0, title: row[1].string ?? field("name"), organization: field("organization"),
                description: field("description"), state: field("passState").replacingOccurrences(of: "SGRealtimeWalletPassState", with: ""),
                serial: field("serial"), url: field("url"), created: row[2].unixDate, archiveBytes: size, entityKey: row[3].string ?? "")
        }
    }

    static func passCount(search: String) async throws -> Int {
        let db = try await database()
        let text = search.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return await db.count("SELECT count(*) FROM entity WHERE entityType = \(passType)") ?? 0 }
        let pattern = SQLValue.text(ProfileFormat.like(text))
        return await db.count("""
            SELECT count(*) FROM entity e WHERE e.entityType = \(passType) AND (e.title LIKE ? ESCAPE '\\' OR EXISTS(
              SELECT 1 FROM entityTags t WHERE t.entityKey = e.entityKey AND t.entityType = e.entityType AND t.tag LIKE 'WPDD:%' AND t.tag LIKE ? ESCAPE '\\'))
            """, [pattern, pattern]) ?? 0
    }

    /// Loads the embedded `.pkpass` (tag `WPD:` + base64 ZIP), unpacks `pass.json` and the logo.
    static func passDetail(_ pass: WalletPassRow) async throws -> WalletPassDetail {
        let db = try await database()
        guard let tag = try await db.scalar("""
            SELECT tag FROM entityTags WHERE entityKey = ? AND entityType = \(passType) AND tag LIKE 'WPD:%' AND length(tag) < 24000000 LIMIT 1
            """, [.text(pass.entityKey)]).string else {
            throw DossierError.message("This pass has no embedded archive.")
        }
        guard let archive = Data(base64Encoded: String(tag.dropFirst(4)), options: .ignoreUnknownCharacters) else {
            throw DossierError.message("The embedded pass archive is not valid base64.")
        }
        return try parsePass(archive)
    }

    static func parsePass(_ archive: Data) throws -> WalletPassDetail {
        guard let zip = ZipArchive(archive) else { throw DossierError.message("The embedded pass is not a readable ZIP archive.") }
        var detail = WalletPassDetail()
        detail.archiveBytes = archive.count
        detail.files = zip.entries.map { ($0.name, $0.uncompressedSize) }
        for name in ["logo@2x.png", "logo.png", "icon@2x.png", "icon.png", "thumbnail@2x.png", "thumbnail.png"] {
            if let data = zip.contents(named: name), !data.isEmpty { detail.logo = data; break }
        }
        guard let json = zip.contents(named: "pass.json"), let pass = PlistDecoder.decodeJSON(json) else {
            throw DossierError.message("The pass archive contains no readable pass.json.")
        }
        func text(_ key: String) -> String { pass[key]?.string ?? "" }
        detail.organization = text("organizationName")
        detail.description = text("description")
        detail.logoText = text("logoText")
        detail.relevantDate = text("relevantDate")
        detail.expirationDate = text("expirationDate")
        detail.voided = pass["voided"]?.bool ?? false
        detail.passType = text("passTypeIdentifier")
        detail.team = text("teamIdentifier")
        detail.serial = text("serialNumber")
        detail.webService = text("webServiceURL")
        detail.authenticationToken = text("authenticationToken")
        detail.background = pass["backgroundColor"]?.string
        detail.foreground = pass["foregroundColor"]?.string
        detail.label = pass["labelColor"]?.string
        let styles = ["boardingPass": "Boarding Pass", "coupon": "Coupon", "eventTicket": "Event Ticket", "generic": "Generic Pass", "storeCard": "Store Card"]
        for (key, label) in styles {
            guard let body = pass[key] else { continue }
            detail.style = label
            if let transit = body["transitType"]?.string {
                detail.style += " (" + transit.replacingOccurrences(of: "PKTransitType", with: "") + ")"
            }
            let groups = [("headerFields", "Header"), ("primaryFields", "Primary"), ("secondaryFields", "Secondary"),
                          ("auxiliaryFields", "Auxiliary"), ("backFields", "Back of Pass"), ("additionalInfoFields", "Additional Info")]
            for (groupKey, groupName) in groups {
                let fields: [(String, String)] = (body[groupKey]?.array ?? []).compactMap { field in
                    let value = field["value"]?.string ?? field["value"]?.int.map(String.init) ?? field["value"]?.double.map { String($0) } ?? ""
                    let label = field["label"]?.string ?? field["key"]?.string ?? ""
                    return value.isEmpty && label.isEmpty ? nil : (label, value)
                }
                if !fields.isEmpty { detail.groups.append((groupName, fields.map { (label: $0.0, value: $0.1) })) }
            }
        }
        var codes = pass["barcodes"]?.array ?? []
        if codes.isEmpty, let single = pass["barcode"] { codes = [single] }
        detail.barcodes = codes.map { (($0["format"]?.string ?? "").replacingOccurrences(of: "PKBarcodeFormat", with: ""), $0["message"]?.string ?? "") }
        detail.locations = (pass["locations"]?.array ?? []).compactMap {
            guard let lat = $0["latitude"]?.double, let lon = $0["longitude"]?.double else { return nil }
            return (lat, lon, $0["relevantText"]?.string ?? "")
        }
        return detail
    }

    // MARK: URLs

    private static let urlSorts: [String: String] = [
        "url": "url COLLATE NOCASE", "title": "title COLLATE NOCASE", "date": "seconds_from_1970", "bundle": "bundle_id", "handle": "received_from_handle",
    ]

    static func urls(offset: Int, limit: Int, sort: PageSort?, search: String) async throws -> [HarvestedURL] {
        let db = try await database()
        try await require(db, "urls", ["id", "url", "title", "bundle_id", "seconds_from_1970"])
        let cols = await db.columnNames(of: "urls")
        func optional(_ name: String) -> String { cols.contains(name) ? name : "NULL" }
        let text = search.trimmingCharacters(in: .whitespaces)
        let column = sort.flatMap { urlSorts[$0.columnID] } ?? "seconds_from_1970"
        let direction = sort?.sqlDirection ?? "DESC"
        let pattern = SQLValue.text(ProfileFormat.like(text))
        let sql = """
            SELECT id, url, title, \(optional("document_title")), \(optional("received_from_handle")), bundle_id, seconds_from_1970, \(optional("flags"))
            FROM urls \(text.isEmpty ? "" : "WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'")
            ORDER BY \(column) \(direction), id LIMIT ? OFFSET ?
            """
        return try await db.query(sql, (text.isEmpty ? [] : [pattern, pattern]) + page(limit, offset), cellByteLimit: 4_000).rows.map { row in
            let url = row[1].string ?? ""
            return HarvestedURL(id: row[0].int ?? 0, url: url, title: row[2].string ?? "", documentTitle: row[3].string ?? "",
                                handle: row[4].string ?? "", bundle: row[5].string ?? "", date: row[6].unixDate,
                                flags: Int(row[7].int ?? 0), secrets: ProfileFormat.secretParameters(in: url))
        }
    }

    static func urlCount(search: String) async throws -> Int {
        let db = try await database()
        let text = search.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return await db.rowCount(of: "urls") ?? 0 }
        let pattern = SQLValue.text(ProfileFormat.like(text))
        return await db.count("SELECT count(*) FROM urls WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'", [pattern, pattern]) ?? 0
    }

    // MARK: Snippets

    private static func snippetSource(_ db: SQLiteDB) async -> String? {
        var parts: [String] = []
        if await db.hasColumns("emailSnippets", ["id", "emailId", "title", "content"]) {
            parts.append("SELECT 'Mail' AS kind, id, emailId AS ref, title, content FROM emailSnippets")
        }
        if await db.hasColumns("snippets", ["id", "entityId", "title", "content"]) {
            parts.append("SELECT 'Entity' AS kind, id, entityId AS ref, title, content FROM snippets")
        }
        return parts.isEmpty ? nil : "(" + parts.joined(separator: " UNION ALL ") + ")"
    }

    static func snippets(offset: Int, limit: Int, sort: PageSort?, search: String) async throws -> [SnippetRow] {
        let db = try await database(ProfilePaths.snippetsDB)
        guard let source = await snippetSource(db) else { throw DossierError.missing("snippets.db has no snippet tables on this macOS version.") }
        let text = search.trimmingCharacters(in: .whitespaces)
        let sorts = ["kind": "kind", "title": "title COLLATE NOCASE", "content": "content COLLATE NOCASE", "id": "id"]
        let column = sort.flatMap { sorts[$0.columnID] } ?? "id"
        let direction = sort?.sqlDirection ?? "DESC"
        let pattern = SQLValue.text(ProfileFormat.like(text))
        let sql = """
            SELECT kind, id, ref, title, substr(content, 1, 2000) FROM \(source)
            \(text.isEmpty ? "" : "WHERE title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\'")
            ORDER BY \(column) \(direction), kind, id LIMIT ? OFFSET ?
            """
        return try await db.rows(sql, (text.isEmpty ? [] : [pattern, pattern]) + page(limit, offset)).map { row in
            let kind = row[0].string ?? ""
            return SnippetRow(id: "\(kind)-\(row[1].int ?? 0)", kind: kind, reference: row[2].int ?? 0, title: row[3].string ?? "", content: row[4].string ?? "")
        }
    }

    static func snippetCount(search: String) async throws -> Int {
        let db = try await database(ProfilePaths.snippetsDB)
        guard let source = await snippetSource(db) else { return 0 }
        let text = search.trimmingCharacters(in: .whitespaces)
        let pattern = SQLValue.text(ProfileFormat.like(text))
        return await db.count("SELECT count(*) FROM \(source) \(text.isEmpty ? "" : "WHERE title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\'")",
                              text.isEmpty ? [] : [pattern, pattern]) ?? 0
    }

    /// Where a snippet came from: the e-mail's sender / date, or the entity it belongs to.
    static func snippetContext(_ snippet: SnippetRow) async -> [(String, String)] {
        guard let db = try? await database() else { return [] }
        var out: [(String, String)] = []
        if snippet.kind == "Mail", await db.hasColumns("emailMetadata", ["id", "author", "creationTimestamp"]),
           let row = try? await db.first("SELECT author, creationTimestamp FROM emailMetadata WHERE id = ?", [.integer(snippet.reference)]) {
            if let author = row[0].string, !author.isEmpty { out.append(("Sender", readableAuthor(author))) }
            if let date = row[1].unixDate { out.append(("Message date", DossierDate.medium(date))) }
        } else if snippet.kind == "Entity", await db.hasColumns("entity", ["id", "title", "entityType", "creationTimestamp"]),
                  let row = try? await db.first("SELECT title, entityType, creationTimestamp FROM entity WHERE id = ?", [.integer(snippet.reference)]) {
            if let title = row[0].string, !title.isEmpty { out.append(("Entity", title)) }
            out.append(("Entity type", entityTypeName(Int(row[1].int ?? 0))))
            if let date = row[2].unixDate { out.append(("Extracted", DossierDate.medium(date))) }
        }
        return out
    }

    static func entityTypeName(_ type: Int) -> String {
        switch type {
        case 2: return "Event"
        case 4: return "Pseudo-contact"
        case 5: return "E-mail"
        case 6: return "Contact detail"
        case 26: return "Wallet pass"
        default: return "Type \(type)"
        }
    }

    // MARK: Own addresses and name caches

    /// Addresses the system saw the owner send mail from (`emailMetadata` rows tagged `isSent`).
    static func ownAddresses() async throws -> [OwnAddress] {
        let db = try await database()
        guard await db.hasColumns("emailMetadata", ["key", "author", "creationTimestamp"]), await db.hasColumns("emailTags", ["key", "tag"]) else { return [] }
        return try await db.rows("""
            SELECT m.author, count(*), max(m.creationTimestamp) FROM emailMetadata m
            WHERE m.author IS NOT NULL AND m.author != '' AND EXISTS(SELECT 1 FROM emailTags t WHERE t.key = m.key AND t.tag = 'isSent')
            GROUP BY m.author ORDER BY 2 DESC LIMIT 500
            """).map { OwnAddress(address: readableAuthor($0[0].string ?? ""), messages: Int($0[1].int ?? 0), last: $0[2].unixDate) }
    }

    /// Authors are stored as `|<name>|<address>|<kind>`; returns "name <address>".
    static func readableAuthor(_ raw: String) -> String {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: true).map(String.init)
        guard raw.hasPrefix("|"), parts.count >= 2 else { return raw }
        return parts[0] == parts[1] || parts[0].caseInsensitiveCompare(parts[1].split(separator: "@").first.map(String.init) ?? "") == .orderedSame
            ? parts[1] : "\(parts[0]) <\(parts[1])>"
    }

    /// `email-to-name.kvcache` / `phone-to-name.kvcache`: handle → display name learned from
    /// message headers. Layout observed: 8-byte header, then per entry
    /// `u16 keyLength, u16 valueLength, u32 0, key bytes, value bytes`.
    static func learnedNames() -> [LearnedName] {
        var out: [LearnedName] = []
        for (url, source) in [(ProfilePaths.emailNameCache, "E-mail"), (ProfilePaths.phoneNameCache, "Phone")] {
            for (key, value) in KVCacheFile.read(url) ?? [] {
                out.append(LearnedName(id: source + "|" + key, handle: key, name: value, source: source))
            }
        }
        return out
    }
}

enum KVCacheFile {
    static func read(_ url: URL) -> [(String, String)]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 8, data.count < 64 << 20 else { return nil }
        var out: [(String, String)] = []
        var offset = 8
        while offset + 8 <= data.count {
            let keyLength = Int(data[offset]) | Int(data[offset + 1]) << 8
            let valueLength = Int(data[offset + 2]) | Int(data[offset + 3]) << 8
            let start = offset + 8
            guard keyLength > 0, start + keyLength + valueLength <= data.count else { return out.isEmpty ? nil : out }
            guard let key = String(data: data[start..<(start + keyLength)], encoding: .utf8),
                  let value = String(data: data[(start + keyLength)..<(start + keyLength + valueLength)], encoding: .utf8) else { return out.isEmpty ? nil : out }
            out.append((key, value.trimmingCharacters(in: .whitespacesAndNewlines)))
            offset = start + keyLength + valueLength
            if out.count >= 100_000 { break }
        }
        return out
    }
}

/// Flattens a JSON object into "path › key" / value pairs for display.
enum JSONFlattener {
    static func flatten(_ value: PlistValue, prefix: String = "", depth: Int = 0) -> [(String, String)] {
        var out: [(String, String)] = []
        switch value {
        case .dict(let pairs):
            for pair in pairs where pair.key != "@context" {
                if pair.key == "@type", depth > 0 { continue }
                let key = pair.key == "@type" ? "Type" : readable(pair.key)
                let path = prefix.isEmpty ? key : prefix + " › " + key
                if depth < 6 { out += flatten(pair.value, prefix: path, depth: depth + 1) }
            }
        case .array(let items):
            for (index, item) in items.prefix(40).enumerated() {
                out += flatten(item, prefix: items.count > 1 ? "\(prefix) \(index + 1)" : prefix, depth: depth + 1)
            }
        case .string(let text):
            let cleaned = text.replacingOccurrences(of: "http://schema.org/", with: "").replacingOccurrences(of: "https://schema.org/", with: "")
            if !cleaned.isEmpty { out.append((prefix, cleaned)) }
        case .int(let n): out.append((prefix, String(n)))
        case .real(let d): out.append((prefix, String(d)))
        case .bool(let b): out.append((prefix, b ? "Yes" : "No"))
        default: break
        }
        return out
    }

    /// "reservationFor" → "Reservation For".
    static func readable(_ key: String) -> String {
        var out = ""
        var previousLower = false
        for ch in key {
            if ch.isUppercase, previousLower { out.append(" ") }
            out.append(out.isEmpty ? Character(ch.uppercased()) : ch)
            previousLower = ch.isLowercase || ch.isNumber
        }
        return out
    }
}
