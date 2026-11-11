import Foundation
import DossierCore

// Siri Remembers — `~/Library/IntelligencePlatform/Artifacts/siri/remembers/view.db`
//
// A GRDB database that materializes the Biome `Siri.Remembers.*` streams (which arrive
// from the owner's other devices, mostly the iPhone):
//
//   interactions(rowid, id, domain, type, bundleId, direction, handlingStatus, startDate,
//                durationSeconds, fields JSON, isLocal, devicePlatform, remoteDeviceId, sourceStreams …)
//   entities(rowid, id, type, fields JSON)         type ∈ PersonHandle, MessageGroup, Message, Person, MediaItem …
//   interactionEntities(interactionRowid, entityRowid, parameter)
//
// Facts established on real data (and re-checked by the self-test):
//   * `startDate` is a Cocoa-epoch double.
//   * `direction` 1 = incoming, 2 = outgoing (the reverse of INInteractionDirection — the
//     same events in knowledgeC carry the opposite number).
//   * `handlingStatus` is INIntentHandlingStatus + 1 (4 = success).
//   * parameter `senderHandle` → PersonHandle of whoever wrote an incoming message,
//     `recipientHandles` → addressees (for incoming messages: the owner's own handle),
//     `contactHandles` → the other party of a call, `speakableGroupName` → MessageGroup
//     whose id *is* the conversation title.
//   * PersonHandle.id is the handle (phone number, e-mail, app-specific id); fields JSON
//     has optional `name`, `type` (phone/email), `label`, `countryCode`.
//   * No message bodies are stored here (only for SMS a `Message` entity with an id).
//
// The Biome stream payloads are protobuf:
//   1 { 1 id, 2 type, 3 domain, 4 bundleId, 5 handlingStatus, 6 direction, 8 startDate(double),
//       9 durationSeconds(double), 11 fields JSON }
//   2* { 1 parameter, 2* { 1 entity id, 2 entity type, 4 fields JSON, 5 tokens } }

enum RemembersSchema {
    static let messageType = "INSendMessageIntent"
    static let callType = "INStartCallIntent"

    /// SQL condition (aliases `i` = interactions, `ie` = interactionEntities) selecting the
    /// link that points at the *other* party of an interaction.
    static let counterpart = """
        ((ie.parameter = 'senderHandle' AND i.direction = 1) \
        OR (ie.parameter = 'recipientHandles' AND i.direction = 2) \
        OR ie.parameter = 'contactHandles')
        """

    static func statusLabel(_ raw: Int64?) -> String {
        switch raw {
        case 1: return "Unspecified"
        case 2: return "Ready"
        case 3: return "In progress"
        case 4: return "Success"
        case 5: return "Failure"
        case 6: return "Deferred to app"
        case 7: return "Needs confirmation"
        case .some(let v): return "Status \(v)"
        case nil: return "—"
        }
    }
}

// MARK: - Models

struct AppTotal: Identifiable, Sendable, Hashable {
    var id: String { bundle }
    var bundle: String
    var messagesIn = 0, messagesOut = 0, callsIn = 0, callsOut = 0, other = 0
    var callSeconds = 0.0
    var first: Date?, last: Date?
    var messages: Int { messagesIn + messagesOut }
    var calls: Int { callsIn + callsOut }
    var total: Int { messages + calls + other }
}

struct DeviceTotal: Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    var detail: String
    var count: Int
    var first: Date?, last: Date?
}

struct MonthBucket: Sendable, Hashable {
    var month: Date
    var kind: String        // "Messages" | "Calls"
    var direction: CommDirection
    var count: Int
    var seconds: Double
}

struct StreamStat: Identifiable, Sendable, Hashable {
    var id: String { name }
    var name: String
    var records: Int
    var deleted: Int
    var bytes: Int64
    var devices: [String]
    var range: ClosedRange<Date>?
}

struct RemembersOverview: Sendable {
    var total = 0, messages = 0, calls = 0
    var incoming = 0, outgoing = 0
    var callSeconds = 0.0
    var range: ClosedRange<Date>?
    var apps: [AppTotal] = []
    var devices: [DeviceTotal] = []
    var months: [MonthBucket] = []
    var heat: [(weekday: Int, hour: Int, weight: Double)] = []
    var handleCount = 0
    var conversationCount = 0
    var types: [(type: String, count: Int)] = []
}

struct HandleInfo: Identifiable, Sendable, Hashable {
    var id: Int64            // entities.rowid
    var value: String
    var name: String?
    var kind: String?        // phone / email
    var label: String?
    var count: Int
    var apps: [String]
}

struct PersonRow: Identifiable, Sendable, Hashable {
    var id: String           // normalized display name, or the handle
    var name: String
    var named: Bool
    var handles: [HandleInfo] = []
    var messagesIn = 0, messagesOut = 0, callsIn = 0, callsOut = 0
    var callSeconds = 0.0
    var apps: [String: Int] = [:]
    var first: Date?, last: Date?

    var messages: Int { messagesIn + messagesOut }
    var calls: Int { callsIn + callsOut }
    var total: Int { messages + calls }
    var entityIDs: [Int64] { handles.map(\.id) }
    var appList: String {
        apps.sorted { $0.value > $1.value }.map { AppNames.name($0.key) }.joined(separator: ", ")
    }
}

struct PersonDetail: Sendable {
    var months: [MonthBucket]
    var heat: [(weekday: Int, hour: Int, weight: Double)]
    var conversations: [(title: String, bundle: String, count: Int)]
}

struct ConversationRow: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable { case conversation = "Conversation", mailSubject = "Mail subject", issueTitle = "Issue / ticket title", contentLike = "Looks like content" }
    var id: String           // "<entity rowid>|<bundle>"
    var entityID: Int64
    var key: String          // entities.id (lower-cased by the store); used for filtering
    var title: String
    var bundle: String
    var count: Int
    var incoming: Int
    var outgoing: Int
    var isGroup: Bool
    var first: Date?, last: Date?
    var kind: Kind = .conversation
    var isContent: Bool { kind != .conversation }
}

struct ConversationAppStat: Identifiable, Sendable, Hashable {
    var id: String { bundle }
    var bundle: String
    var titles: Int
    var interactions: Int
    var averageLength: Double
    var contentKind: ConversationRow.Kind
}

struct ConversationData: Sendable {
    var rows: [ConversationRow]
    var apps: [ConversationAppStat]
}

struct MessageRow: Identifiable, Sendable, Hashable {
    var id: Int64
    var interactionID: String
    var date: Date?
    var bundle: String
    var direction: CommDirection
    var person: String
    var title: String
    var isGroup: Bool
    var device: String
    var status: Int64?
    var text: String?
    var textIsCode: Bool = false
}

struct MessageFilter: Sendable, Hashable {
    var bundle: String?
    var direction: CommDirection?
    var from: Date?
    var to: Date?
    var hasText = false
    var person: String?          // exact person key (deep link / People)
    var conversation: String?    // exact conversation title
}

struct CallRow: Identifiable, Sendable, Hashable {
    var id: String
    var date: Date?
    var bundle: String
    var direction: CommDirection
    var person: String
    var handle: String
    var seconds: Double
    var status: String
    var device: String
    var detail: String = ""
}

struct CallStats: Sendable {
    var total = 0, incoming = 0, outgoing = 0, connected = 0
    var seconds = 0.0, longest = 0.0
    var range: ClosedRange<Date>?
    var months: [MonthBucket] = []
    var buckets: [(label: String, count: Int)] = []
    var topPeople: [(name: String, seconds: Double, count: Int)] = []
    var heat: [(weekday: Int, hour: Int, weight: Double)] = []
}

// MARK: - Store

enum RemembersStore {
    static let name = "Siri Remembers view.db"

    static func open() async throws -> SQLiteDB {
        let db = try await CommsDB.open(CommsPaths.remembersView, name)
        guard await db.hasColumns("interactions", ["type", "bundleId", "direction", "startDate"]),
              await db.hasColumns("interactionEntities", ["interactionRowid", "entityRowid", "parameter"]),
              await db.hasColumns("entities", ["id", "type", "fields"]) else {
            throw DossierError.missing("The Siri Remembers view database has a different schema on this macOS version.")
        }
        return db
    }

    // MARK: Devices

    /// Labels for the device an interaction was donated on.
    struct DeviceNamer: Sendable {
        let peers: [String: BiomeDevicePeer]
        func name(isLocal: Bool, platform: Int64?, remoteID: String?) -> String {
            if isLocal { return "This Mac" }
            if let remoteID, let peer = peers[remoteID] ?? peers[remoteID.uppercased()] { return peer.displayName }
            switch platform {
            case 2: return "iPhone / iPad"
            case 3: return "Mac"
            case 4: return "Apple Watch"
            default: return "Other device"
            }
        }
    }

    static func deviceNamer() async -> DeviceNamer { DeviceNamer(peers: await Biome.devicePeers()) }

    static func deviceColumns(_ db: SQLiteDB) async -> (isLocal: String, platform: String, remote: String) {
        let cols = await db.columnSet(of: "interactions")
        return (cols.contains("isLocal") ? "i.isLocal" : "1",
                cols.contains("devicePlatform") ? "i.devicePlatform" : "0",
                cols.contains("remoteDeviceId") ? "i.remoteDeviceId" : "NULL")
    }

    // MARK: Overview

    static func overview() async throws -> RemembersOverview {
        let db = try await open()
        var out = RemembersOverview()
        let local = CommsSQL.local("i.startDate")
        let dev = await deviceColumns(db)
        let hasDuration = await db.hasColumns("interactions", ["durationSeconds"])
        let duration = hasDuration ? "i.durationSeconds" : "0"

        // Per app × type × direction.
        let rows = try await db.rows("""
            SELECT i.bundleId, i.type, i.direction, count(*), sum(\(duration)), min(i.startDate), max(i.startDate)
            FROM interactions i GROUP BY 1, 2, 3
            """)
        var apps: [String: AppTotal] = [:]
        var types: [String: Int] = [:]
        var lo: Date?, hi: Date?
        for r in rows {
            let bundle = r[0].string ?? ""
            let type = r[1].string ?? ""
            let direction = CommDirection.remembers(r[2].int)
            let n = Int(r[3].int ?? 0)
            var app = apps[bundle] ?? AppTotal(bundle: bundle)
            types[type, default: 0] += n
            out.total += n
            if type.caseInsensitiveCompare(RemembersSchema.messageType) == .orderedSame {
                out.messages += n
                if direction == .incoming { app.messagesIn += n; out.incoming += n } else if direction == .outgoing { app.messagesOut += n; out.outgoing += n } else { app.other += n }
            } else if type.caseInsensitiveCompare(RemembersSchema.callType) == .orderedSame {
                out.calls += n
                let seconds = r[4].double ?? 0
                app.callSeconds += seconds
                out.callSeconds += seconds
                if direction == .incoming { app.callsIn += n; out.incoming += n } else if direction == .outgoing { app.callsOut += n; out.outgoing += n } else { app.other += n }
            } else {
                app.other += n
            }
            if let d = r[5].cocoaDate { app.first = min(app.first ?? d, d); lo = min(lo ?? d, d) }
            if let d = r[6].cocoaDate { app.last = max(app.last ?? d, d); hi = max(hi ?? d, d) }
            apps[bundle] = app
        }
        out.apps = apps.values.sorted { $0.total > $1.total }
        out.types = types.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
        if let lo, let hi { out.range = lo...hi }

        // Per device.
        let namer = await deviceNamer()
        let deviceRows = try await db.rows("""
            SELECT \(dev.isLocal), \(dev.platform), \(dev.remote), count(*), min(i.startDate), max(i.startDate)
            FROM interactions i GROUP BY 1, 2, 3 ORDER BY 4 DESC
            """)
        for (index, r) in deviceRows.enumerated() {
            let isLocal = (r[0].int ?? 1) != 0
            let peer = r[2].string.flatMap { namer.peers[$0] ?? namer.peers[$0.uppercased()] }
            let detail = isLocal ? "donated on this Mac" : [peer.flatMap { $0.name == nil ? nil : $0.platformName }, peer?.model.map { "OS build \($0)" }, "synced via Biome"].compactMap { $0 }.joined(separator: " · ")
            out.devices.append(DeviceTotal(
                id: "device-\(index)",
                name: namer.name(isLocal: isLocal, platform: r[1].int, remoteID: r[2].string),
                detail: detail, count: Int(r[3].int ?? 0), first: r[4].cocoaDate, last: r[5].cocoaDate))
        }

        // Per month.
        out.months = try await monthBuckets(db, where: "i.type IN ('\(RemembersSchema.messageType)', '\(RemembersSchema.callType)')", params: [], join: "")

        // Weekday × hour.
        let heatRows = try await db.rows("""
            SELECT CAST(strftime('%w', \(local)) AS INTEGER) + 1, CAST(strftime('%H', \(local)) AS INTEGER), count(*)
            FROM interactions i WHERE i.type IN ('\(RemembersSchema.messageType)', '\(RemembersSchema.callType)') GROUP BY 1, 2
            """)
        out.heat = heatRows.map { (Int($0[0].int ?? 0), Int($0[1].int ?? 0), Double($0[2].int ?? 0)) }

        out.handleCount = await db.count("SELECT count(*) FROM entities WHERE type = 'PersonHandle'") ?? 0
        out.conversationCount = await db.count("SELECT count(*) FROM entities WHERE type = 'MessageGroup'") ?? 0
        return out
    }

    private static func monthBuckets(_ db: SQLiteDB, where condition: String, params: [SQLValue], join: String, distinct: Bool = false) async throws -> [MonthBucket] {
        let local = CommsSQL.local("i.startDate")
        let hasDuration = await db.hasColumns("interactions", ["durationSeconds"])
        let countExpr = distinct ? "count(DISTINCT i.rowid)" : "count(*)"
        let rows = try await db.rows("""
            SELECT strftime('%Y-%m', \(local)), i.type, i.direction, \(countExpr), sum(\(hasDuration ? "i.durationSeconds" : "0"))
            FROM interactions i \(join) WHERE \(condition) GROUP BY 1, 2, 3 ORDER BY 1
            """, params)
        return rows.compactMap { r in
            guard let key = r[0].string, let month = CommsSQL.monthDate(key) else { return nil }
            let isCall = (r[1].string ?? "").caseInsensitiveCompare(RemembersSchema.callType) == .orderedSame
            return MonthBucket(month: month, kind: isCall ? "Calls" : "Messages", direction: .remembers(r[2].int), count: Int(r[3].int ?? 0), seconds: r[4].double ?? 0)
        }
    }

    // MARK: Biome streams

    /// Record counts of the raw `Siri.Remembers.*` Biome streams (index only, no payload decode).
    static func streamStats() async -> [StreamStat] {
        let peers = await Biome.devicePeers()
        return CommsPaths.remembersStreams.compactMap { name in
            guard let stream = Biome.stream(named: name) else { return nil }
            let stats = BiomeStreamReader(stream).stats()
            let devices = stream.devices.map { device -> String in
                if device.isLocal { return "This Mac" }
                return device.identifier.flatMap { peers[$0]?.displayName } ?? "Other device"
            }
            return StreamStat(name: name, records: stats.records, deleted: stats.deleted, bytes: stats.bytes, devices: Array(Set(devices)).sorted(), range: stats.timeRange)
        }
    }

    /// Decodes the stream payloads and counts records per interaction type (used by the
    /// self-test to cross-check the view database against its source streams).
    static func streamTypeCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for name in CommsPaths.remembersStreams {
            guard let stream = Biome.stream(named: name) else { continue }
            BiomeStreamReader(stream).forEachMessage { _, message in
                if let type = message.string(at: 1, 2) { counts[type, default: 0] += 1 }
                return true
            }
        }
        return counts
    }

    // MARK: People

    static func people() async throws -> [PersonRow] {
        let db = try await open()
        let hasDuration = await db.hasColumns("interactions", ["durationSeconds"])
        let rows = try await db.rows("""
            SELECT e.rowid, e.id, json_extract(e.fields, '$.name'), json_extract(e.fields, '$.type'), json_extract(e.fields, '$.label'),
                   i.bundleId, i.type, i.direction, count(*), sum(\(hasDuration ? "i.durationSeconds" : "0")), min(i.startDate), max(i.startDate)
            FROM interactionEntities ie
            JOIN interactions i ON i.rowid = ie.interactionRowid
            JOIN entities e ON e.rowid = ie.entityRowid
            WHERE e.type = 'PersonHandle' AND \(RemembersSchema.counterpart)
            GROUP BY e.rowid, i.bundleId, i.type, i.direction
            """)
        var people: [String: PersonRow] = [:]
        var handleIndex: [String: [Int64: Int]] = [:]
        for r in rows {
            guard let entity = r[0].int else { continue }
            let handle = r[1].string ?? ""
            let rawName = r[2].string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let named = !(rawName ?? "").isEmpty && rawName != handle
            let display = named ? rawName! : handle
            let key = personKey(name: rawName, handle: handle)
            var person = people[key] ?? PersonRow(id: key, name: display, named: named)
            let bundle = r[5].string ?? ""
            let isCall = (r[6].string ?? "").caseInsensitiveCompare(RemembersSchema.callType) == .orderedSame
            let direction = CommDirection.remembers(r[7].int)
            let n = Int(r[8].int ?? 0)
            if isCall {
                if direction == .incoming { person.callsIn += n } else { person.callsOut += n }
                person.callSeconds += r[9].double ?? 0
            } else {
                if direction == .incoming { person.messagesIn += n } else { person.messagesOut += n }
            }
            person.apps[bundle, default: 0] += n
            if let d = r[10].cocoaDate { person.first = min(person.first ?? d, d) }
            if let d = r[11].cocoaDate { person.last = max(person.last ?? d, d) }
            if let index = handleIndex[key]?[entity] {
                person.handles[index].count += n
                if !person.handles[index].apps.contains(bundle) { person.handles[index].apps.append(bundle) }
            } else {
                handleIndex[key, default: [:]][entity] = person.handles.count
                person.handles.append(HandleInfo(id: entity, value: handle, name: rawName, kind: r[3].string, label: r[4].string, count: n, apps: [bundle]))
            }
            people[key] = person
        }
        return people.values.sorted { ($0.total, $0.name) > ($1.total, $1.name) }
    }

    /// People are merged by display name (case-insensitive); unnamed handles stay separate.
    static func personKey(name: String?, handle: String) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == handle { return "h:" + handle }
        return "n:" + trimmed.lowercased()
    }

    static func personDetail(_ entityIDs: [Int64]) async throws -> PersonDetail {
        let db = try await open()
        guard !entityIDs.isEmpty else { return PersonDetail(months: [], heat: [], conversations: []) }
        let list = entityIDs.map(String.init).joined(separator: ",")
        let join = "JOIN interactionEntities ie ON ie.interactionRowid = i.rowid"
        let condition = "ie.entityRowid IN (\(list)) AND \(RemembersSchema.counterpart)"
        let months = try await monthBuckets(db, where: condition, params: [], join: join, distinct: true)
        let local = CommsSQL.local("i.startDate")
        let heatRows = try await db.rows("""
            SELECT CAST(strftime('%w', \(local)) AS INTEGER) + 1, CAST(strftime('%H', \(local)) AS INTEGER), count(DISTINCT i.rowid)
            FROM interactions i \(join) WHERE \(condition) GROUP BY 1, 2
            """)
        let convRows = try await db.rows("""
            SELECT coalesce(nullif(json_extract(g.fields, '$.name'), ''), g.id), i.bundleId, count(DISTINCT i.rowid) n
            FROM interactions i \(join)
            JOIN interactionEntities ig ON ig.interactionRowid = i.rowid AND ig.parameter = 'speakableGroupName'
            JOIN entities g ON g.rowid = ig.entityRowid
            WHERE \(condition) GROUP BY g.rowid, i.bundleId ORDER BY n DESC LIMIT 12
            """)
        return PersonDetail(
            months: months,
            heat: heatRows.map { (Int($0[0].int ?? 0), Int($0[1].int ?? 0), Double($0[2].int ?? 0)) },
            conversations: convRows.map { ($0[0].string ?? "", $0[1].string ?? "", Int($0[2].int ?? 0)) })
    }

    // MARK: Conversations

    static func conversations() async throws -> ConversationData {
        let db = try await open()
        let rows = try await db.rows("""
            SELECT e.rowid, e.id, i.bundleId, count(*), sum(i.direction = 1), sum(i.direction = 2),
                   min(i.startDate), max(i.startDate), max(coalesce(json_extract(i.fields, '$.isGroup'), 0)),
                   coalesce(nullif(json_extract(e.fields, '$.name'), ''), e.id)
            FROM interactionEntities ie
            JOIN interactions i ON i.rowid = ie.interactionRowid
            JOIN entities e ON e.rowid = ie.entityRowid
            WHERE ie.parameter = 'speakableGroupName'
            GROUP BY e.rowid, i.bundleId
            """)
        var list = rows.compactMap { r -> ConversationRow? in
            guard let entity = r[0].int else { return nil }
            let bundle = r[2].string ?? ""
            return ConversationRow(
                id: "\(entity)|\(bundle)", entityID: entity, key: r[1].string ?? "", title: r[9].string ?? r[1].string ?? "", bundle: bundle,
                count: Int(r[3].int ?? 0), incoming: Int(r[4].int ?? 0), outgoing: Int(r[5].int ?? 0),
                isGroup: (r[8].int ?? 0) != 0, first: r[6].cocoaDate, last: r[7].cocoaDate)
        }
        // Per-app statistics decide whether an app's "conversation titles" are really content.
        var stats: [String: ConversationAppStat] = [:]
        for bundle in Set(list.map(\.bundle)) {
            let mine = list.filter { $0.bundle == bundle }
            let interactions = mine.reduce(0) { $0 + $1.count }
            let avg = mine.isEmpty ? 0 : Double(mine.reduce(0) { $0 + $1.title.count }) / Double(mine.count)
            stats[bundle] = ConversationAppStat(
                bundle: bundle, titles: mine.count, interactions: interactions, averageLength: avg,
                contentKind: contentKind(bundle: bundle, titles: mine.count, interactions: interactions, averageLength: avg))
        }
        for index in list.indices {
            let appKind = stats[list[index].bundle]?.contentKind ?? .conversation
            if appKind != .conversation {
                list[index].kind = appKind
            } else if list[index].title.count > 90 && list[index].count <= 2 {
                list[index].kind = .contentLike
            }
        }
        list.sort { ($0.count, $0.title) > ($1.count, $1.title) }
        return ConversationData(rows: list, apps: stats.values.sorted { $0.interactions > $1.interactions })
    }

    /// Mail clients and issue trackers donate subject lines / ticket titles as the
    /// "conversation name". Unknown apps are judged by shape: almost every interaction has
    /// its own, long title.
    static func contentKind(bundle: String, titles: Int, interactions: Int, averageLength: Double) -> ConversationRow.Kind {
        if AppNames.mailApps.contains(bundle) { return .mailSubject }
        if AppNames.trackerApps.contains(bundle) { return .issueTitle }
        if titles >= 5, Double(titles) / Double(max(interactions, 1)) >= 0.6, averageLength >= 25 { return .contentLike }
        return .conversation
    }

    static func conversationDetail(entityID: Int64, bundle: String) async throws -> (months: [MonthBucket], senders: [(name: String, count: Int)]) {
        let db = try await open()
        let join = "JOIN interactionEntities ig ON ig.interactionRowid = i.rowid AND ig.parameter = 'speakableGroupName'"
        let months = try await monthBuckets(db, where: "ig.entityRowid = ? AND i.bundleId = ?", params: [.integer(entityID), .text(bundle)], join: join)
        let senders = try await db.rows("""
            SELECT coalesce(nullif(trim(json_extract(e.fields, '$.name')), ''), e.id) who, count(DISTINCT i.rowid) n
            FROM interactions i \(join)
            JOIN interactionEntities ie ON ie.interactionRowid = i.rowid AND ie.parameter = 'senderHandle'
            JOIN entities e ON e.rowid = ie.entityRowid
            WHERE ig.entityRowid = ? AND i.bundleId = ? GROUP BY who ORDER BY n DESC LIMIT 15
            """, [.integer(entityID), .text(bundle)])
        return (months, senders.map { ($0[0].string ?? "", Int($0[1].int ?? 0)) })
    }

    // MARK: Messages

    static func messageApps() async throws -> [String] {
        let db = try await open()
        let rows = try await db.rows("SELECT bundleId, count(*) FROM interactions WHERE type = ? GROUP BY 1 ORDER BY 2 DESC", [.text(RemembersSchema.messageType)])
        return rows.compactMap { $0[0].string }
    }

    private static func messageWhere(_ filter: MessageFilter, search: String, textIDs: [String]) -> (sql: String, params: [SQLValue]) {
        var parts = ["i.type = ?"]
        var params: [SQLValue] = [.text(RemembersSchema.messageType)]
        if let bundle = filter.bundle { parts.append("i.bundleId = ?"); params.append(.text(bundle)) }
        if let direction = filter.direction { parts.append("i.direction = ?"); params.append(.integer(Int64(direction.rawValue))) }
        if let from = filter.from { parts.append("i.startDate >= ?"); params.append(.real(from.cocoa)) }
        if let to = filter.to { parts.append("i.startDate < ?"); params.append(.real(to.cocoa)) }
        if filter.hasText {
            // Interaction ids are UUID strings; anything else is dropped before interpolation.
            let safe = textIDs.filter { id in id.count <= 64 && id.allSatisfy { $0.isHexDigit || $0 == "-" } }
            parts.append("upper(i.id) IN (" + safe.map { "'\($0.uppercased())'" }.joined(separator: ",") + ")")
        }
        if let person = filter.person {
            let exists = """
                EXISTS (SELECT 1 FROM interactionEntities ie JOIN entities e ON e.rowid = ie.entityRowid
                        WHERE ie.interactionRowid = i.rowid AND \(RemembersSchema.counterpart) AND
                """
            if person.hasPrefix("n:") {
                parts.append(exists + " lower(trim(json_extract(e.fields, '$.name'))) = ?)")
                params.append(.text(String(person.dropFirst(2))))
            } else {
                parts.append(exists + " e.id = ?)")
                params.append(.text(person.hasPrefix("h:") ? String(person.dropFirst(2)) : person))
            }
        }
        if let conversation = filter.conversation {
            parts.append("""
                EXISTS (SELECT 1 FROM interactionEntities ie JOIN entities e ON e.rowid = ie.entityRowid
                        WHERE ie.interactionRowid = i.rowid AND ie.parameter = 'speakableGroupName' AND e.id = ?)
                """)
            params.append(.text(conversation))
        }
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            parts.append("""
                (i.bundleId LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM interactionEntities ie JOIN entities e ON e.rowid = ie.entityRowid
                        WHERE ie.interactionRowid = i.rowid AND e.type IN ('PersonHandle', 'MessageGroup')
                          AND (e.id LIKE ? ESCAPE '\\' OR json_extract(e.fields, '$.name') LIKE ? ESCAPE '\\')))
                """)
            let pattern = CommsSQL.like(needle)
            params += [.text(pattern), .text(pattern), .text(pattern)]
        }
        return (parts.joined(separator: " AND "), params)
    }

    static func messages(_ filter: MessageFilter, request: PageRequest, texts: [String: IntentRecord], namer: DeviceNamer) async throws -> [MessageRow] {
        let db = try await open()
        if filter.hasText && texts.isEmpty { return [] }
        let (condition, params) = messageWhere(filter, search: request.search, textIDs: filter.hasText ? Array(texts.keys) : [])
        let sortColumn: String
        switch request.sort?.columnID {
        case "bundleId": sortColumn = "i.bundleId"
        case "direction": sortColumn = "i.direction"
        default: sortColumn = "i.startDate"
        }
        let direction = request.sort?.sqlDirection ?? "DESC"
        let dev = await deviceColumns(db)
        let nameOf = "coalesce(nullif(trim(json_extract(e.fields, '$.name')), ''), e.id)"
        let rows = try await db.rows("""
            SELECT i.rowid, i.id, i.bundleId, i.direction, i.startDate, \(dev.isLocal), \(dev.platform), \(dev.remote),
                   coalesce(json_extract(i.fields, '$.isGroup'), 0), i.handlingStatus,
                   (SELECT group_concat(\(nameOf), ', ') FROM interactionEntities ie JOIN entities e ON e.rowid = ie.entityRowid
                     WHERE ie.interactionRowid = i.rowid AND \(RemembersSchema.counterpart)),
                   (SELECT coalesce(nullif(json_extract(e.fields, '$.name'), ''), e.id) FROM interactionEntities ie JOIN entities e ON e.rowid = ie.entityRowid
                     WHERE ie.interactionRowid = i.rowid AND ie.parameter = 'speakableGroupName' LIMIT 1)
            FROM interactions i WHERE \(condition)
            ORDER BY \(sortColumn) \(direction), i.rowid \(direction) LIMIT ? OFFSET ?
            """, params + [.integer(Int64(request.limit)), .integer(Int64(request.offset))])
        return rows.compactMap { r in
            guard let rowid = r[0].int else { return nil }
            let id = r[1].string ?? ""
            let record = texts[id.uppercased()]
            return MessageRow(
                id: rowid, interactionID: id, date: r[4].cocoaDate, bundle: r[2].string ?? "",
                direction: .remembers(r[3].int), person: r[10].string ?? "", title: r[11].string ?? "",
                isGroup: (r[8].int ?? 0) != 0,
                device: namer.name(isLocal: (r[5].int ?? 1) != 0, platform: r[6].int, remoteID: r[7].string),
                status: r[9].int, text: record?.text, textIsCode: record?.isCode ?? false)
        }
    }

    static func messageCount(_ filter: MessageFilter, search: String, texts: [String: IntentRecord]) async throws -> Int? {
        let db = try await open()
        if filter.hasText && texts.isEmpty { return 0 }
        let (condition, params) = messageWhere(filter, search: search, textIDs: filter.hasText ? Array(texts.keys) : [])
        return await db.count("SELECT count(*) FROM interactions i WHERE \(condition)", params)
    }

    /// All entities linked to one interaction, for the inspector.
    static func interactionEntities(_ rowid: Int64) async throws -> [(parameter: String, type: String, id: String, fields: String)] {
        let db = try await open()
        let rows = try await db.rows("""
            SELECT ie.parameter, e.type, e.id, e.fields FROM interactionEntities ie JOIN entities e ON e.rowid = ie.entityRowid
            WHERE ie.interactionRowid = ? ORDER BY ie.parameter
            """, [.integer(rowid)])
        return rows.map { ($0[0].string ?? "", $0[1].string ?? "", $0[2].string ?? "", $0[3].string ?? "") }
    }

    // MARK: Calls

    static func calls() async throws -> [CallRow] {
        let db = try await open()
        let dev = await deviceColumns(db)
        let namer = await deviceNamer()
        let hasDuration = await db.hasColumns("interactions", ["durationSeconds"])
        let nameOf = "coalesce(nullif(trim(json_extract(e.fields, '$.name')), ''), e.id)"
        let rows = try await db.rows("""
            SELECT i.rowid, i.bundleId, i.direction, i.startDate, \(hasDuration ? "i.durationSeconds" : "0"), i.handlingStatus,
                   \(dev.isLocal), \(dev.platform), \(dev.remote),
                   (SELECT group_concat(\(nameOf), ', ') FROM interactionEntities ie JOIN entities e ON e.rowid = ie.entityRowid
                     WHERE ie.interactionRowid = i.rowid AND ie.parameter = 'contactHandles'),
                   (SELECT group_concat(e.id, ', ') FROM interactionEntities ie JOIN entities e ON e.rowid = ie.entityRowid
                     WHERE ie.interactionRowid = i.rowid AND ie.parameter = 'contactHandles')
            FROM interactions i WHERE i.type = ? ORDER BY i.startDate DESC
            """, [.text(RemembersSchema.callType)], maxRows: 200_000)
        return rows.compactMap { r in
            guard let rowid = r[0].int else { return nil }
            return CallRow(
                id: "sr-\(rowid)", date: r[3].cocoaDate, bundle: r[1].string ?? "", direction: .remembers(r[2].int),
                person: r[9].string ?? "", handle: r[10].string ?? "", seconds: r[4].double ?? 0,
                status: RemembersSchema.statusLabel(r[5].int),
                device: namer.name(isLocal: (r[6].int ?? 1) != 0, platform: r[7].int, remoteID: r[8].string))
        }
    }

    // MARK: Search

    static func searchEntities(_ query: String, limit: Int) async -> [(type: String, id: String, name: String?, count: Int)] {
        guard let db = try? await open() else { return [] }
        let pattern = CommsSQL.like(query)
        let rows = (try? await db.rows("""
            SELECT e.type, e.id, json_extract(e.fields, '$.name'),
                   (SELECT count(*) FROM interactionEntities ie WHERE ie.entityRowid = e.rowid)
            FROM entities e
            WHERE e.type IN ('PersonHandle', 'MessageGroup') AND (e.id LIKE ? ESCAPE '\\' OR json_extract(e.fields, '$.name') LIKE ? ESCAPE '\\')
            ORDER BY 4 DESC LIMIT ?
            """, [.text(pattern), .text(pattern), .integer(Int64(limit))])) ?? []
        return rows.map { ($0[0].string ?? "", $0[1].string ?? "", $0[2].string, Int($0[3].int ?? 0)) }
    }
}

/// Derives the call statistics shown above the calls table from any list of calls.
enum CallMath {
    static func stats(_ calls: [CallRow]) -> CallStats {
        var out = CallStats()
        let calendar = Calendar.current
        var months: [String: MonthBucket] = [:]
        var buckets = [0, 0, 0, 0, 0, 0]
        var people: [String: (seconds: Double, count: Int)] = [:]
        var heat: [Int: Double] = [:]
        var lo: Date?, hi: Date?
        for call in calls {
            out.total += 1
            if call.direction == .incoming { out.incoming += 1 } else if call.direction == .outgoing { out.outgoing += 1 }
            out.seconds += call.seconds
            out.longest = max(out.longest, call.seconds)
            if call.seconds > 0 { out.connected += 1 }
            switch call.seconds {
            case ..<0.5: buckets[0] += 1
            case ..<60: buckets[1] += 1
            case ..<300: buckets[2] += 1
            case ..<900: buckets[3] += 1
            case ..<3600: buckets[4] += 1
            default: buckets[5] += 1
            }
            if !call.person.isEmpty {
                var p = people[call.person] ?? (0, 0)
                p.seconds += call.seconds; p.count += 1
                people[call.person] = p
            }
            guard let date = call.date else { continue }
            lo = min(lo ?? date, date); hi = max(hi ?? date, date)
            let c = calendar.dateComponents([.year, .month, .weekday, .hour], from: date)
            if let month = calendar.date(from: DateComponents(year: c.year, month: c.month, day: 1)) {
                let key = "\(c.year ?? 0)-\(c.month ?? 0)-\(call.direction.rawValue)"
                var bucket = months[key] ?? MonthBucket(month: month, kind: "Calls", direction: call.direction, count: 0, seconds: 0)
                bucket.count += 1; bucket.seconds += call.seconds
                months[key] = bucket
            }
            if let weekday = c.weekday, let hour = c.hour { heat[weekday * 100 + hour, default: 0] += 1 }
        }
        if let lo, let hi { out.range = lo...hi }
        out.months = months.values.sorted { ($0.month, $0.direction.rawValue) < ($1.month, $1.direction.rawValue) }
        let labels = ["Not connected", "< 1 min", "1–5 min", "5–15 min", "15–60 min", "> 1 h"]
        out.buckets = zip(labels, buckets).map { ($0, $1) }
        out.topPeople = people.map { ($0.key, $0.value.seconds, $0.value.count) }
            .sorted { ($0.1, Double($0.2)) > ($1.1, Double($1.2)) }.prefix(8).map { $0 }
        out.heat = heat.map { ($0.key / 100, $0.key % 100, $0.value) }
        return out
    }
}
