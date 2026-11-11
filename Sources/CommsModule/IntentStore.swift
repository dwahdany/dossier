import Foundation
import DossierCore

// knowledgeC `/app/intents` — `~/Library/Application Support/Knowledge/knowledgeC.db`
//
// ZOBJECT rows of stream `/app/intents` (synced from the owner's other devices, kept for
// a few weeks) join ZSTRUCTUREDMETADATA, whose
// `Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION` blob is:
//
//   NSKeyedArchiver { root: NSData }                       ← outer archive
//     └ NSKeyedArchiver { root: INInteraction }            ← inner archive
//         dateInterval { NS.startDate, NS.duration }, direction, identifier, groupIdentifier
//         intent { identifier, donationMetadata { callDuration … }, backingStore { bytes } }
//
// `backingStore.bytes` is a protobuf (`_INPBSendMessageIntent` / `_INPBStartCallIntent`).
// Field numbers used here (established from real records):
//
//   SendMessage: 1 { 2 launch bundle id }            2 { 1* recipient contact }
//                5 { 1 { 2 message text } }          7 { 1 conversation / group name }
//                8 conversation identifier           9 service name
//                10 { 1 sender contact }
//   StartCall:   5 { 1* contact }                    4 call capability (1 audio, 2 video)
//   Contact:     1 { 2 contact identifier }  2 first name  3 last name  4 display name
//                7 { 1 handle value, 2 handle type (1 e-mail, 2 phone) }  8 custom identifier
//
// `intent.identifier` equals `interactions.id` in the Siri Remembers view, which is how the
// retained message text is attached to the long-term timeline.
// The ZSTRUCTUREDMETADATA direction flag is INInteractionDirection: 1 = outgoing, 2 = incoming.

struct IntentContact: Sendable, Hashable {
    var name: String
    var handle: String
    var handleType: String?

    var display: String { name.isEmpty ? handle : name }
}

struct IntentRecord: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable { case message = "Message", call = "Call" }
    var id: Int64                    // ZOBJECT.Z_PK
    var kind: Kind
    var date: Date?
    var bundle: String
    var direction: CommDirection
    var intentID: String             // upper-cased; matches Siri Remembers interactions.id
    var sender: IntentContact?
    var recipients: [IntentContact]
    var groupName: String?
    var conversationID: String?
    var serviceName: String?
    var text: String?
    var isCode: Bool
    var seconds: Double
    var remote: Bool

    /// The other party: the sender of an incoming message, the recipients of an outgoing one.
    var counterpart: String {
        switch direction {
        case .incoming:
            if let sender, !sender.display.isEmpty { return sender.display }
            return groupName ?? ""
        default:
            let names = recipients.map(\.display).filter { !$0.isEmpty }
            return names.isEmpty ? (groupName ?? "") : names.joined(separator: ", ")
        }
    }
}

struct IntentSnapshot: Sendable {
    var records: [IntentRecord] = []
    var byIntentID: [String: IntentRecord] = [:]
    var streamTotal = 0              // all /app/intents rows
    var undecodable = 0
    var truncated = false
    var range: ClosedRange<Date>?

    /// Only the records whose message body is retained, keyed like `byIntentID`.
    var textByIntentID: [String: IntentRecord] = [:]

    var withText: [IntentRecord] { records.filter { $0.text != nil } }
}

actor IntentStore {
    static let shared = IntentStore()
    /// Upper bound of decoded intents (newest first); knowledgeC normally keeps far fewer.
    static let maxRecords = 25_000

    private var cache: IntentSnapshot?
    private var cacheToken = Int.min

    /// Decoded communication intents, cached per refresh token.
    func snapshot(token: Int = 0) async throws -> IntentSnapshot {
        if let cache, cacheToken == token { return cache }
        let value = try await Self.load()
        cache = value
        cacheToken = token
        return value
    }

    /// Like `snapshot` but never throws (missing store → empty snapshot).
    func snapshotOrEmpty(token: Int = 0) async -> IntentSnapshot {
        (try? await snapshot(token: token)) ?? IntentSnapshot()
    }

    private static let blobColumn = "Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION"
    private static let classColumn = "Z_DKINTENTMETADATAKEY__INTENTCLASS"
    private static let directionColumn = "Z_DKINTENTMETADATAKEY__DIRECTION"

    private static func load() async throws -> IntentSnapshot {
        let db = try await CommsDB.open(Paths.knowledgeC, "knowledgeC.db")
        guard await db.hasColumns("ZOBJECT", ["ZSTREAMNAME", "ZSTARTDATE", "ZSTRUCTUREDMETADATA"]),
              await db.hasColumns("ZSTRUCTUREDMETADATA", [blobColumn, classColumn]) else {
            throw DossierError.missing("knowledgeC has no intent metadata on this macOS version.")
        }
        let metaColumns = await db.columnSet(of: "ZSTRUCTUREDMETADATA")
        let objectColumns = await db.columnSet(of: "ZOBJECT")
        let sourceColumns = await db.columnSet(of: "ZSOURCE")
        let hasSource = sourceColumns.contains("ZBUNDLEID") && objectColumns.contains("ZSOURCE")
        let hasDevice = hasSource && sourceColumns.contains("ZDEVICEID")
        let direction = metaColumns.contains(directionColumn) ? "m.\(directionColumn)" : "0"

        var snapshot = IntentSnapshot()
        snapshot.streamTotal = await db.count("SELECT count(*) FROM ZOBJECT WHERE ZSTREAMNAME = '/app/intents'") ?? 0

        struct Acc: Sendable { var records: [IntentRecord] = []; var undecodable = 0 }
        let acc = try await db.reduce("""
            SELECT o.Z_PK, o.ZSTARTDATE, o.ZENDDATE, \(hasSource ? "s.ZBUNDLEID" : "o.ZVALUESTRING"), m.\(classColumn), \(direction),
                   \(hasDevice ? "s.ZDEVICEID IS NOT NULL" : "0"), m.\(blobColumn)
            FROM ZOBJECT o JOIN ZSTRUCTUREDMETADATA m ON m.Z_PK = o.ZSTRUCTUREDMETADATA
            \(hasSource ? "LEFT JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE" : "")
            WHERE o.ZSTREAMNAME = '/app/intents' AND m.\(classColumn) IN ('INSendMessageIntent', 'INStartCallIntent')
            ORDER BY o.ZSTARTDATE DESC LIMIT \(maxRecords + 1)
            """, into: Acc()) { acc, row in
            guard acc.records.count < maxRecords + 1, let pk = row[0].int else { return }
            let isCall = row[4].string == "INStartCallIntent"
            var record = IntentRecord(
                id: pk, kind: isCall ? .call : .message, date: row[1].cocoaDate, bundle: row[3].string ?? "",
                direction: .intent(row[5].int), intentID: "", sender: nil, recipients: [], groupName: nil,
                conversationID: nil, serviceName: nil, text: nil, isCode: false,
                seconds: max(0, (row[2].double ?? 0) - (row[1].double ?? 0)), remote: (row[6].int ?? 0) != 0)
            if let blob = row[7].data, IntentDecoder.decode(blob, into: &record) {
                // decoded in place
            } else {
                acc.undecodable += 1
            }
            acc.records.append(record)
        }
        snapshot.records = acc.records
        snapshot.undecodable = acc.undecodable
        if snapshot.records.count > maxRecords {
            snapshot.records.removeLast(snapshot.records.count - maxRecords)
            snapshot.truncated = true
        }
        for record in snapshot.records where !record.intentID.isEmpty {
            snapshot.byIntentID[record.intentID] = record
            if record.text != nil { snapshot.textByIntentID[record.intentID] = record }
        }
        let dates = snapshot.records.compactMap(\.date)
        if let lo = dates.min(), let hi = dates.max() { snapshot.range = lo...hi }
        return snapshot
    }

    /// Raw blob of one record (for the inspector's tree view).
    static func rawBlob(pk: Int64) async -> Data? {
        guard let db = await CommsDB.openIfAvailable(Paths.knowledgeC) else { return nil }
        let value = try? await db.scalar("""
            SELECT m.\(blobColumn) FROM ZOBJECT o JOIN ZSTRUCTUREDMETADATA m ON m.Z_PK = o.ZSTRUCTUREDMETADATA WHERE o.Z_PK = ?
            """, [.integer(pk)])
        return value?.data
    }
}

/// Decodes a serialized `INInteraction` (see the layout at the top of this file).
enum IntentDecoder {
    /// Unwraps the two archive layers. Returns the resolved `INInteraction` tree.
    static func interaction(_ blob: Data) -> PlistValue? {
        guard let outer = PlistDecoder.decodeAny(blob) else { return nil }
        if case .data(let inner) = outer { return PlistDecoder.decodeAny(inner) }
        if let inner = outer["NS.data"]?.data ?? outer["root"]?.data { return PlistDecoder.decodeAny(inner) }
        return outer
    }

    static func backingStore(_ interaction: PlistValue) -> Data? {
        guard let store = interaction["intent"]?["backingStore"] else { return nil }
        if let d = store.data { return d }
        return store["bytes"]?.data ?? store["NS.data"]?.data
    }

    @discardableResult
    static func decode(_ blob: Data, into record: inout IntentRecord) -> Bool {
        guard let interaction = interaction(blob) else { return false }
        if let id = interaction["intent"]?["identifier"]?.string { record.intentID = id.uppercased() }
        if let start = interaction["dateInterval"]?["NS.startDate"]?.date { record.date = start }
        if let duration = interaction["dateInterval"]?["NS.duration"]?.double, duration > 0 { record.seconds = duration }
        if let call = interaction["intent"]?["donationMetadata"]?["callDuration"]?.double, call > 0 { record.seconds = call }
        if record.direction == .unspecified { record.direction = .intent(interaction["direction"]?.int) }
        guard let bytes = backingStore(interaction), let message = ProtoMessage(bytes) else { return !record.intentID.isEmpty }
        switch record.kind {
        case .message:
            record.recipients = message.all(2).flatMap { contacts(in: $0) }
            record.sender = message[10].flatMap { contacts(in: $0).first }
            if let text = message.field(at: 5, 1, 2)?.string ?? message.field(at: 5, 1, 1)?.string, !text.isEmpty {
                record.text = text
                record.isCode = CodeDetector.looksLikeCode(text)
            }
            record.groupName = nonEmpty(message.field(at: 7, 1)?.string ?? message.field(at: 7, 2)?.string)
            record.conversationID = nonEmpty(message[8]?.string)
            record.serviceName = nonEmpty(message[9]?.string)
        case .call:
            record.recipients = message.all(5).flatMap { contacts(in: $0) }
        }
        return true
    }

    private static func nonEmpty(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }

    /// A contact list field: `{ 1* contact }`.
    private static func contacts(in field: ProtoField) -> [IntentContact] {
        guard let list = field.message else { return [] }
        return list.all(1).compactMap { item -> IntentContact? in
            guard let c = item.message else { return nil }
            let full = c[4]?.string ?? ""
            let composed = [c[2]?.string, c[3]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let handle = c.field(at: 7, 1)?.string ?? ""
            let type: String?
            switch c.field(at: 7, 2)?.int {
            case 1: type = "email"
            case 2: type = "phone"
            default: type = nil
            }
            let name = full.isEmpty ? composed : full
            if name.isEmpty && handle.isEmpty { return nil }
            return IntentContact(name: name, handle: handle, handleType: type)
        }
    }
}
