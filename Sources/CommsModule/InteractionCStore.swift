import Foundation
import DossierCore

// interactionC — `/private/var/db/CoreDuet/People/interactionC.db` (CoreData, `_CDInteraction`)
//
// The "People" store behind share-sheet and Mail / Calendar suggestions on this Mac:
//   ZINTERACTIONS(ZBUNDLEID, ZMECHANISM, ZDIRECTION, ZSTARTDATE, ZENDDATE, ZSENDER → ZCONTACTS,
//                 ZRECIPIENTCOUNT, ZDOMAINIDENTIFIER, ZACCOUNT, ZGROUPNAME …)
//   ZCONTACTS(ZDISPLAYNAME, ZIDENTIFIER (e-mail / phone), ZPERSONID (Contacts id),
//             ZINCOMINGSENDERCOUNT, ZINCOMINGRECIPIENTCOUNT, ZOUTGOINGRECIPIENTCOUNT + first/last dates)
//   Z_<n>INTERACTIONRECIPIENT(contact, interaction)   — recipients join (column prefixes vary)
//   ZKEYWORDS(ZKEYWORD) + Z_<n>KEYWORDS(interaction, keyword) — words taken from meeting titles
//
// Observed: ZDIRECTION 0 = incoming, 1 = outgoing; ZMECHANISM 1 = e-mail, 5 = calendar
// event, 16 = call (labels for other values are not verified and shown as numbers).
// Dates are Cocoa-epoch. Calendar interactions may lie in the future: Calendar records
// every occurrence of a recurring event, years ahead. Those are scheduled meetings, not
// things that happened, so the overview counts them separately (`scheduled`) and the
// reported time range, totals and per-mechanism counts cover `ZSTARTDATE <= now` only.

struct CorrespondentRow: Identifiable, Sendable, Hashable {
    var id: Int64
    var name: String
    var identifier: String
    var personID: String?
    var sent: Int               // they wrote to the owner
    var coRecipient: Int        // they were addressed together with the owner
    var received: Int           // the owner wrote to them
    var first: Date?, last: Date?
    var total: Int { sent + coRecipient + received }
}

struct KeywordCount: Identifiable, Sendable, Hashable {
    var id: String { word }
    var word: String
    var count: Int
}

struct MechanismTotal: Identifiable, Sendable, Hashable {
    var id: String { "\(bundle)|\(mechanism)|\(direction)" }
    var bundle: String
    var mechanism: Int
    var direction: Int
    var count: Int
    var first: Date?, last: Date?

    var mechanismLabel: String { InteractionCStore.mechanismLabel(mechanism) }
    var directionLabel: String { direction == 1 ? "Outgoing" : "Incoming" }
}

struct InteractionCOverview: Sendable {
    /// All rows of ZINTERACTIONS, past and scheduled.
    var interactions = 0
    /// Rows that start after now (future occurrences of calendar events).
    var scheduled = 0
    /// Start of the last scheduled occurrence.
    var scheduledUntil: Date?
    /// Rows that have already happened.
    var past: Int { interactions - scheduled }
    var contacts = 0
    var keywords: [KeywordCount] = []
    var keywordLinks = 0
    /// Per app × mechanism × direction, past interactions only.
    var mechanisms: [MechanismTotal] = []
    /// Time range of the past interactions.
    var range: ClosedRange<Date>?
    var months: [(month: Date, label: String, count: Int)] = []
}

struct CorrespondentDetail: Sendable {
    var byApp: [(label: String, count: Int)]
    var keywords: [KeywordCount]
    var months: [(month: Date, count: Int)]
}

enum InteractionCStore {
    static let name = "interactionC.db"

    static func mechanismLabel(_ value: Int) -> String {
        switch value {
        case 1: return "E-mail"
        case 5: return "Calendar event"
        case 16: return "Call"
        default: return "Mechanism \(value)"
        }
    }

    struct Schema: Sendable {
        var keywordJoin: (table: String, interaction: String, keyword: String)?
        var recipientJoin: (table: String, contact: String, interaction: String)?
    }

    static func open() async throws -> SQLiteDB {
        let db = try await CommsDB.open(Paths.interactionC, name)
        guard await db.hasColumns("ZINTERACTIONS", ["ZBUNDLEID", "ZSTARTDATE"]),
              await db.hasColumns("ZCONTACTS", ["ZIDENTIFIER"]) else {
            throw DossierError.missing("interactionC.db has a different schema on this macOS version.")
        }
        return db
    }

    /// CoreData many-to-many tables carry entity numbers in their names (`Z_3KEYWORDS`,
    /// `Z_2INTERACTIONRECIPIENT`) that change between OS versions — find them by shape.
    static func schema(_ db: SQLiteDB) async -> Schema {
        var out = Schema()
        let tables = (try? await db.tables()) ?? []
        for table in tables where table.hasPrefix("Z_") {
            let columns = Array(await db.columnNames(of: table)) /*lowercased*/
            guard columns.count == 2 else { continue }
            if table.hasSuffix("KEYWORDS"),
               let interaction = columns.first(where: { $0.uppercased().contains("INTERACTIONS") }),
               let keyword = columns.first(where: { $0.uppercased().contains("KEYWORDS") && $0 != interaction }) {
                out.keywordJoin = (table, interaction, keyword)
            } else if table.uppercased().contains("INTERACTIONRECIPIENT"),
                      let interaction = columns.first(where: { $0.uppercased().contains("INTERACTIONRECIPIENT") }),
                      let contact = columns.first(where: { $0 != interaction }) {
                out.recipientJoin = (table, contact, interaction)
            }
        }
        return out
    }

    static func overview() async throws -> InteractionCOverview {
        let db = try await open()
        let schema = await schema(db)
        var out = InteractionCOverview()
        out.interactions = await db.rowCount(of: "ZINTERACTIONS") ?? 0
        out.contacts = await db.rowCount(of: "ZCONTACTS") ?? 0
        let cols = await db.columnSet(of: "ZINTERACTIONS")
        let mechanism = cols.contains("ZMECHANISM") ? "ZMECHANISM" : "0"
        let direction = cols.contains("ZDIRECTION") ? "ZDIRECTION" : "0"
        let now = Date().cocoa
        let rows = try await db.rows("""
            SELECT ZBUNDLEID, \(mechanism), \(direction), ZSTARTDATE > ?1, count(*), min(ZSTARTDATE), max(ZSTARTDATE)
            FROM ZINTERACTIONS GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC
            """, [.real(now)])
        var lo: Date?, hi: Date?
        for r in rows {
            let count = Int(r[4].int ?? 0)
            let first = r[5].cocoaDate, last = r[6].cocoaDate
            if (r[3].int ?? 0) != 0 {
                out.scheduled += count
                if let last { out.scheduledUntil = max(out.scheduledUntil ?? last, last) }
                continue
            }
            out.mechanisms.append(MechanismTotal(bundle: r[0].string ?? "", mechanism: Int(r[1].int ?? 0), direction: Int(r[2].int ?? 0), count: count, first: first, last: last))
            if let first { lo = min(lo ?? first, first) }
            if let last { hi = max(hi ?? last, last) }
        }
        if let lo, let hi { out.range = lo...hi }
        if let join = schema.keywordJoin, await db.hasColumns("ZKEYWORDS", ["ZKEYWORD"]) {
            let words = try await db.rows("""
                SELECT k.ZKEYWORD, count(*) FROM \(SQLiteDB.quote(join.table)) j
                JOIN ZKEYWORDS k ON k.Z_PK = j.\(SQLiteDB.quote(join.keyword))
                GROUP BY k.Z_PK ORDER BY 2 DESC, 1 LIMIT 400
                """)
            out.keywords = words.compactMap { r in r[0].string.map { KeywordCount(word: $0, count: Int(r[1].int ?? 0)) } }
            out.keywordLinks = await db.rowCount(of: join.table) ?? 0
        }
        let monthRows = try await db.rows("""
            SELECT strftime('%Y-%m', \(CommsSQL.local("ZSTARTDATE"))), \(mechanism), count(*)
            FROM ZINTERACTIONS WHERE ZSTARTDATE <= ? GROUP BY 1, 2 ORDER BY 1
            """, [.real(now)])
        out.months = monthRows.compactMap { r in
            guard let key = r[0].string, let month = CommsSQL.monthDate(key) else { return nil }
            return (month, mechanismLabel(Int(r[1].int ?? 0)), Int(r[2].int ?? 0))
        }
        return out
    }

    static func correspondents() async throws -> [CorrespondentRow] {
        let db = try await open()
        let cols = await db.columnSet(of: "ZCONTACTS")
        func col(_ name: String, _ fallback: String = "NULL") -> String { cols.contains(name) ? name : fallback }
        let dateColumns = ["ZFIRSTINCOMINGSENDERDATE", "ZFIRSTINCOMINGRECIPIENTDATE", "ZFIRSTOUTGOINGRECIPIENTDATE",
                           "ZLASTINCOMINGSENDERDATE", "ZLASTINCOMINGRECIPIENTDATE", "ZLASTOUTGOINGRECIPIENTDATE"].map { col($0) }
        let rows = try await db.rows("""
            SELECT Z_PK, \(col("ZDISPLAYNAME")), ZIDENTIFIER, \(col("ZPERSONID")),
                   \(col("ZINCOMINGSENDERCOUNT", "0")), \(col("ZINCOMINGRECIPIENTCOUNT", "0")), \(col("ZOUTGOINGRECIPIENTCOUNT", "0")),
                   \(dateColumns.joined(separator: ", "))
            FROM ZCONTACTS LIMIT 100000
            """)
        let list = rows.compactMap { r -> CorrespondentRow? in
            guard let pk = r[0].int else { return nil }
            let firsts = (7...9).compactMap { r[$0].cocoaDate }
            let lasts = (10...12).compactMap { r[$0].cocoaDate }
            let identifier = r[2].string ?? ""
            let name = r[1].string ?? ""
            if identifier.isEmpty && name.isEmpty { return nil }
            return CorrespondentRow(
                id: pk, name: name, identifier: identifier, personID: r[3].string,
                sent: Int(r[4].int ?? 0), coRecipient: Int(r[5].int ?? 0), received: Int(r[6].int ?? 0),
                first: firsts.min(), last: lasts.max())
        }
        return list.sorted { ($0.sent + $0.received, $0.total, $0.name) > ($1.sent + $1.received, $1.total, $1.name) }
    }

    static func detail(contact: Int64) async throws -> CorrespondentDetail {
        let db = try await open()
        let schema = await schema(db)
        let cols = await db.columnSet(of: "ZINTERACTIONS")
        var members = cols.contains("ZSENDER") ? "SELECT Z_PK FROM ZINTERACTIONS WHERE ZSENDER = ?1" : "SELECT NULL WHERE 0"
        if let join = schema.recipientJoin {
            members += " UNION SELECT \(SQLiteDB.quote(join.interaction)) FROM \(SQLiteDB.quote(join.table)) WHERE \(SQLiteDB.quote(join.contact)) = ?1"
        }
        let mechanism = cols.contains("ZMECHANISM") ? "ZMECHANISM" : "0"
        let appRows = try await db.rows("""
            SELECT ZBUNDLEID, \(mechanism), count(*) FROM ZINTERACTIONS WHERE Z_PK IN (\(members)) GROUP BY 1, 2 ORDER BY 3 DESC
            """, [.integer(contact)])
        var keywords: [KeywordCount] = []
        if let join = schema.keywordJoin {
            let rows = try await db.rows("""
                SELECT k.ZKEYWORD, count(*) FROM \(SQLiteDB.quote(join.table)) j
                JOIN ZKEYWORDS k ON k.Z_PK = j.\(SQLiteDB.quote(join.keyword))
                WHERE j.\(SQLiteDB.quote(join.interaction)) IN (\(members)) GROUP BY k.Z_PK ORDER BY 2 DESC, 1 LIMIT 40
                """, [.integer(contact)])
            keywords = rows.compactMap { r in r[0].string.map { KeywordCount(word: $0, count: Int(r[1].int ?? 0)) } }
        }
        let monthRows = try await db.rows("""
            SELECT strftime('%Y-%m', \(CommsSQL.local("ZSTARTDATE"))), count(*) FROM ZINTERACTIONS
            WHERE Z_PK IN (\(members)) AND ZSTARTDATE < ?2 GROUP BY 1 ORDER BY 1
            """, [.integer(contact), .real(Date().cocoa)])
        return CorrespondentDetail(
            byApp: appRows.map { ("\(AppNames.name($0[0].string)) · \(mechanismLabel(Int($0[1].int ?? 0)))", Int($0[2].int ?? 0)) },
            keywords: keywords,
            months: monthRows.compactMap { r in
                guard let key = r[0].string, let month = CommsSQL.monthDate(key) else { return nil }
                return (month, Int(r[1].int ?? 0))
            })
    }

    static func search(_ query: String, limit: Int) async -> [CorrespondentRow] {
        guard let db = try? await open() else { return [] }
        let cols = await db.columnSet(of: "ZCONTACTS")
        guard cols.contains("ZDISPLAYNAME") else { return [] }
        let pattern = CommsSQL.like(query)
        let rows = (try? await db.rows("""
            SELECT Z_PK, ZDISPLAYNAME, ZIDENTIFIER FROM ZCONTACTS
            WHERE ZDISPLAYNAME LIKE ? ESCAPE '\\' OR ZIDENTIFIER LIKE ? ESCAPE '\\' LIMIT ?
            """, [.text(pattern), .text(pattern), .integer(Int64(limit))])) ?? []
        return rows.compactMap { r in
            guard let pk = r[0].int else { return nil }
            return CorrespondentRow(id: pk, name: r[1].string ?? "", identifier: r[2].string ?? "", personID: nil, sent: 0, coRecipient: 0, received: 0)
        }
    }
}
