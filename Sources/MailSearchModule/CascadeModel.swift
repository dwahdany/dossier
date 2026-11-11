import Foundation
import DossierCore

// MARK: - Sets

/// What a Cascade set holds, derived from its stream / source names.
enum CascadeKind: String, Sendable, Hashable {
    case mail, mailBody, attachment, attachmentText
    case photos, reminders, contacts, safari, music, findMy, home, calendar
    case apps, shortcuts, extracted, siri, other

    var symbol: String {
        switch self {
        case .mail: return "envelope"
        case .mailBody: return "text.alignleft"
        case .attachment: return "paperclip"
        case .attachmentText: return "doc.text.magnifyingglass"
        case .photos: return "photo.on.rectangle"
        case .reminders: return "checklist"
        case .contacts: return "person.crop.circle"
        case .safari: return "bookmark"
        case .music: return "music.note"
        case .findMy: return "location.circle"
        case .home: return "house"
        case .calendar: return "calendar"
        case .apps: return "square.grid.2x2"
        case .shortcuts: return "square.2.layers.3d"
        case .extracted: return "text.viewfinder"
        case .siri: return "waveform"
        case .other: return "tray.full"
        }
    }

    /// How private the entity titles of this kind are.
    var sensitivity: Sensitivity {
        switch self {
        case .mail, .mailBody, .attachment, .attachmentText, .contacts, .findMy, .extracted, .siri, .photos: return .sensitive
        case .apps, .shortcuts: return .low
        default: return .personal
        }
    }

    var isPlainText: Bool { self == .mailBody || self == .attachmentText }
}

enum CascadeGroup: String, CaseIterable, Sendable {
    case mail = "Mail"
    case personal = "Personal Data"
    case apps = "Apps & Shortcuts"
    case extracted = "Extracted by Text Understanding"
    case other = "Other"
}

/// One `Set.db` under `~/Library/Biome/sets`.
struct CascadeSetInfo: Identifiable, Sendable, Hashable {
    /// Path of the set directory relative to the sets root (stable deep-link key).
    let id: String
    /// Set (stream) name, e.g. `App.Intents.IndexedEntity`.
    let stream: String
    /// `sourceIdentifier=` component (donating process), if the set is per source.
    let source: String?
    /// `associatedSet=` component (for `Cascade.CachedDocument`).
    let associated: String?
    let url: URL
    let bytes: Int64
    let kind: CascadeKind
    let title: String
    let group: CascadeGroup
    let explanation: String

    var isIndexedEntity: Bool { stream == "App.Intents.IndexedEntity" }
}

struct CascadeSetSummary: Identifiable, Sendable, Hashable {
    var id: String { info.id }
    let info: CascadeSetInfo
    /// Live (not deleted) items; nil when the schema could not be read.
    let live: Int?
    /// Distinct content blobs.
    let contents: Int?
    /// Deleted item versions still recorded in the provenance log.
    let deleted: Int?
    let lastWrite: Date?
    let availability: Availability
}

extension CascadeSetInfo {
    static func classify(stream: String, source: String?, associated: String?) -> (CascadeKind, String, CascadeGroup, String) {
        let app = source.map(shortBundle) ?? ""
        switch stream {
        case "App.Intents.IndexedEntity":
            switch source ?? "" {
            case "com.apple.mail":
                return (.mail, "Mail Messages & Attachments", .mail, "Every message — and every attachment file — Mail donated to the system index as an app entity: subject, sender, recipients, dates, flags and the complete header block.")
            case "com.apple.Photos":
                return (.photos, "Photos Assets", .personal, "Photo and album entities donated by Photos, including scene classifications and capture metadata.")
            case "com.apple.reminders":
                return (.reminders, "Reminders", .personal, "Reminders, lists and sections donated by Reminders, with due dates and attached locations.")
            case "com.apple.contactsd":
                return (.contacts, "Contacts (App Entities)", .personal, "Contact cards donated by the Contacts daemon: names, phone numbers, e-mail and postal addresses.")
            case "com.apple.Safari":
                return (.safari, "Safari Bookmarks & Reading List", .personal, "Bookmarks, Reading List items and page donations from Safari.")
            case "com.apple.Music":
                return (.music, "Music Library", .personal, "Songs, albums, artists and playlists donated by Music.")
            case "com.apple.findmy.findmylocateagent":
                return (.findMy, "Find My People", .personal, "People you share locations with in Find My.")
            case "com.apple.icloud.searchpartyuseragent":
                return (.findMy, "Find My Items", .personal, "Items and accessories tracked through the Find My network, including ones shared by other people.")
            case "com.apple.homed":
                return (.home, "Home Rooms & Accessories", .personal, "Homes, rooms, scenes and accessories donated by HomeKit.")
            case "com.apple.shortcuts":
                return (.shortcuts, "Shortcuts", .apps, "Entities donated by the Shortcuts app.")
            default:
                return (.other, "App Entities · \(app)", .apps, "App entities donated by \(source ?? "an app") through App Intents.")
            }
        case "Cascade.CachedDocument":
            if associated == "Mail.ImportedAttachment" {
                return (.attachmentText, "Attachment Text", .mail, "Plain text extracted from mail attachments (PDFs, documents), cached for language models and semantic search.")
            }
            if associated == "App.Intents.IndexedEntity", source == "com.apple.mail" {
                return (.mailBody, "Mail Body Text", .mail, "Plain-text copies of mail message bodies, cached alongside the message entities for language models and semantic search.")
            }
            return (.other, "Cached Documents · \(associated ?? app)", .other, "Cached plain-text documents associated with another set.")
        case "Mail.ImportedAttachment":
            return (.attachment, "Mail Attachments", .mail, "One record per attachment file Mail imported: file name, type, sender, message and the path of the file on disk.")
        case "App.InstalledApp":
            return (.apps, "Installed Apps", .apps, "The apps installed on this Mac, as known to the system index.")
        case "App.Shortcut.Phrase":
            return (.shortcuts, "Shortcut Phrases · \(app)", .apps, "Spoken phrases that trigger App Shortcuts of this app.")
        case "App.Shortcut.Entity":
            return (.shortcuts, "Shortcut Entities · \(app)", .apps, "Entities usable as parameters of this app's App Shortcuts.")
        case "Contacts.Contact":
            return (.contacts, "Contacts", .personal, "Names from your address book, used to recognise people in requests.")
        case "FindMy.Device":
            return (.findMy, "Find My Devices", .personal, "Devices in Find My, with the names of their owners.")
        case "HomeKit.Home":
            return (.home, "HomeKit", .personal, "Homes, rooms, accessories and scenes known to HomeKit.")
        case "Calendar.Event":
            return (.calendar, "Calendar Events", .personal, "Calendar events donated to the system index.")
        case "Siri.Transcript.Conversation":
            return (.siri, "Siri Conversations", .other, "Transcripts of Siri conversations.")
        default:
            if stream.hasPrefix("TextUnderstanding.Extracted.") {
                let name = String(stream.dropFirst("TextUnderstanding.Extracted.".count))
                return (.extracted, "Extracted · \(spaced(name))", .extracted, "Structured facts the text-understanding pipeline extracted from your content (\(spaced(name).lowercased())).")
            }
            if stream.hasPrefix("Photos.") {
                return (.photos, spaced(stream.replacingOccurrences(of: ".", with: " ")), .personal, "Knowledge derived from your photo library.")
            }
            let suffix = app.isEmpty ? "" : " · \(app)"
            return (.other, stream + suffix, .other, "Cascade set \(stream).")
        }
    }

    /// `com.apple.VoiceMemos` → `VoiceMemos`
    static func shortBundle(_ bundle: String) -> String {
        let parts = bundle.split(separator: ".")
        guard let last = parts.last else { return bundle }
        return String(last)
    }

    /// `HotelReservation` → `Hotel Reservation`
    static func spaced(_ camel: String) -> String {
        var out = ""
        for (index, ch) in camel.enumerated() {
            if index > 0, ch.isUppercase, let prev = out.last, prev.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }
}

// MARK: - Rows and details

/// One live item of a set — small, display-only (the table keeps all loaded rows).
struct CascadeRow: Identifiable, Sendable, Hashable {
    /// `metacontent_provenance.sequence_number` (unique per set).
    let id: Int64
    let type: String
    let title: String
    let subtitle: String
    let date: Date?
    let written: Date?
    let bytes: Int
    let storedBytes: Int
    let itemID: String
}

struct CascadeAttachmentRef: Identifiable, Sendable, Hashable {
    var id: Int64 { seq }
    let seq: Int64
    let name: String
    let type: String
    let sourceHash: Int64?
}

/// Everything the inspector shows for one item.
struct CascadeDetail: Sendable {
    let set: CascadeSetInfo
    let row: CascadeRow
    let attributes: [KeyValueItem]
    let custom: [KeyValueItem]
    let identifiers: [KeyValueItem]
    let headers: [KeyValueItem]
    /// The item's own text (plain-text sets only).
    let text: String?
    let nodes: [DataNode]
    /// Links this item to its cached body / attachment text in sibling sets.
    let sourceHash: Int64?
    let attachments: [CascadeAttachmentRef]
    /// For cached documents: the message the text belongs to.
    let origin: [KeyValueItem]
}

// MARK: - Decoding
//
// Field numbers below were established empirically on macOS 27 by decoding real records;
// they are not a published schema. Anything unknown is still shown (raw tree).
//
// App.Intents.IndexedEntity content (after LZFSE):
//   1  entity type name ("MailMessageEntity", "ReminderEntity", …)
//   2  { 1: display title }
//   3  { 1: type display name }
//   5  searchable attribute set, grouped:
//        2 { 13 subject }
//        3 { 1 keywords*, 2 content type, 3 content type tree*, 4 URL, 6 display name, 9 path,
//            14 title, 15 domain identifier, 17 account type }
//        5 { 2 due date (unix) }
//        6 { 20 latitude, 21 longitude, 22 place name, 26 address }
//        7 { 1 host, 2 created (unix), 3 modified (unix), 5 copyright, 15 duration, 16 media type,
//            31 genre, 44 received (unix) }
//        8 { 1 album, 2 artist, 7 contributors, 10 genre }
//        9 { 3 camera }
//        10 { 2 handles*, 3 account id, 5 postal address parts*, 6 author addresses*, 7 author
//             names*, 9 e-mail*, 14 mailbox URL, 15 phone*, 18 recipient addresses*, 19 recipient
//             names*, 25 date sent (unix), 29 { 1 header name, 2 values* }* }
//        11 { 1 container title, 2 container identifier, 4 container display name }
//        13 content type tree (ignored)
//   6* custom attributes { 3 key, 2* value { 1 string | 2 integer | 3 double | 4 bool } }
//
// Set metacontent (never compressed): 1 item identifier, 2 file URL / token, 4 domain,
//   5 date, 6 app entity identifier, 7 related identifier.
//
// Mail.ImportedAttachment content: 1 UTI, 2 file name, 3 account, 4 mailboxes*, 5 Message-ID,
//   6 sent (unix), 7 received (unix), 8 { 2 sender address }.

enum CascadeDecoder {
    static let groupLabels: [Int: [Int: String]] = [
        2: [13: "Subject"],
        3: [1: "Keywords", 2: "Content Type", 4: "URL", 6: "Display Name", 9: "Path", 14: "Title", 15: "Domain", 16: "Related Identifier", 17: "Account Type"],
        5: [2: "Due"],
        6: [20: "Latitude", 21: "Longitude", 22: "Place", 26: "Address"],
        7: [1: "Host", 2: "Created", 3: "Modified", 5: "Copyright", 15: "Duration", 16: "Media Type", 31: "Genre", 44: "Received"],
        8: [1: "Album", 2: "Artist", 7: "Contributors", 10: "Genre"],
        9: [3: "Camera"],
        10: [2: "Handles", 3: "Account", 5: "Postal Address", 6: "From (Address)", 7: "From (Name)", 9: "E-mail", 14: "Mailbox", 15: "Phone", 18: "To (Address)", 19: "To (Name)", 25: "Sent"],
        11: [1: "Container", 2: "Container ID", 4: "Container Name"],
    ]

    static let rawLabels: [String: [Int: String]] = [
        "App.InstalledApp": [1: "Bundle ID", 3: "Name"],
        "App.Shortcut.Phrase": [1: "Phrase", 2: "Base Phrase", 4: "Action"],
        "App.Shortcut.Entity": [1: "Title", 2: "Identifier", 3: "Type", 4: "Display Name"],
        "Contacts.Contact": [1: "Given Name", 2: "Middle Name", 3: "Family Name"],
        "FindMy.Device": [1: "Name", 2: "Owner"],
        "Mail.ImportedAttachment": [1: "Type", 2: "File Name", 3: "Account", 4: "Mailbox", 5: "Message-ID", 6: "Sent", 7: "Received", 8: "Sender"],
    ]

    static let metaLabels: [Int: String] = [1: "Item ID", 2: "Location", 4: "Domain", 5: "Recorded", 6: "Entity ID", 7: "Related ID"]

    // MARK: Row

    static func row(set: CascadeSetInfo, seq: Int64, meta: Data?, raw: Data?, written: Int64?) -> (row: CascadeRow, haystack: String) {
        let content = raw.map(CascadeBlob.decode) ?? Data()
        let metaMsg = meta.flatMap { ProtoMessage($0) }
        let itemID = metaMsg?[1]?.string ?? ""
        let writtenDate = written.flatMap { $0 > 0 ? DossierDate.unixMicros($0) : nil }
        var type = "", title = "", subtitle = "", haystack = ""
        var date: Date?

        if set.kind.isPlainText {
            let text = content.lossyUTF8
            type = "Text"
            title = Format.oneLine(text, max: 200)
            subtitle = "\(Format.count(text.count)) characters"
            haystack = text
        } else if let msg = ProtoMessage(content) {
            if set.isIndexedEntity || looksLikeEntity(msg) {
                let entity = Entity(msg)
                type = entity.typeName
                title = entity.title
                subtitle = entity.subtitle
                date = entity.date
            } else {
                (type, title, subtitle, date) = rawSummary(set: set, msg: msg)
            }
            haystack = title + "\n" + subtitle + "\n" + type
        } else {
            type = "Binary"
            title = "\(Format.bytes(content.count)) of undecoded data"
        }
        if title.isEmpty { title = itemID.isEmpty ? "Untitled" : itemID }
        let row = CascadeRow(
            id: seq, type: type, title: Format.oneLine(title, max: 240), subtitle: Format.oneLine(subtitle, max: 200),
            date: date, written: writtenDate, bytes: content.count, storedBytes: raw?.count ?? 0, itemID: itemID
        )
        return (row, haystack + "\n" + itemID)
    }

    static func looksLikeEntity(_ msg: ProtoMessage) -> Bool {
        guard let name = msg[1]?.string, name.hasSuffix("Entity") || name.hasSuffix("Destination") else { return false }
        return msg[5] != nil
    }

    private static func rawSummary(set: CascadeSetInfo, msg: ProtoMessage) -> (String, String, String, Date?) {
        switch set.stream {
        case "App.InstalledApp":
            let bundle = msg[1]?.string ?? ""
            return ("App", msg[3]?.string ?? bundle, bundle, nil)
        case "Mail.ImportedAttachment":
            let sender = msg[8]?.message?[2]?.string ?? ""
            let date = msg[6]?.double.flatMap(plausibleUnix)
            return (msg[1]?.string ?? "", msg[2]?.string ?? "", sender, date)
        case "Contacts.Contact":
            let name = [msg[1]?.string, msg[2]?.string, msg[3]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let rest = msg.fields.filter { $0.number > 3 }.compactMap(\.string).filter { !$0.isEmpty }
            return ("Contact", name.isEmpty ? (rest.first ?? "") : name, rest.joined(separator: " · "), nil)
        case "FindMy.Device":
            let owner = msg[2]?.message.map { [$0[1]?.string, $0[2]?.string].compactMap { $0 }.joined(separator: " ") } ?? ""
            return ("Device", msg[1]?.string ?? "", owner, nil)
        default:
            let strings = msg.allStrings(maxDepth: 4, limit: 8).filter { !$0.isEmpty }
            let type = set.stream.split(separator: ".").last.map(String.init) ?? ""
            return (type, strings.first ?? "", strings.dropFirst().prefix(4).joined(separator: " · "), nil)
        }
    }

    static func plausibleUnix(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        let date = DossierDate.unix(value)
        return DossierDate.isPlausible(date) ? date : nil
    }

    // MARK: Entity

    struct Entity {
        let msg: ProtoMessage
        let attrs: ProtoMessage?

        init(_ msg: ProtoMessage) {
            self.msg = msg
            self.attrs = msg[5]?.message
        }

        func group(_ number: Int) -> ProtoMessage? { attrs?[number]?.message }

        var typeName: String { msg[1]?.string ?? "" }

        var title: String {
            if let t = msg[2]?.message?[1]?.string, !t.isEmpty { return t }
            if let g = group(3) {
                if let t = g[6]?.string, !t.isEmpty { return t }
                if let t = g[14]?.string, !t.isEmpty { return t }
            }
            if let t = group(2)?[13]?.string, !t.isEmpty { return t }
            return ""
        }

        var date: Date? {
            if let d = group(7)?[2]?.double.flatMap(CascadeDecoder.plausibleUnix) { return d }
            if let d = group(10)?[25]?.double.flatMap(CascadeDecoder.plausibleUnix) { return d }
            if let d = group(5)?[2]?.double.flatMap(CascadeDecoder.plausibleUnix) { return d }
            return nil
        }

        var author: String {
            guard let g = group(10) else { return "" }
            let name = g[7]?.string ?? "", address = g[6]?.string ?? ""
            if name.isEmpty { return address }
            return address.isEmpty ? name : "\(name) <\(address)>"
        }

        func custom(_ key: String) -> [String] {
            for field in msg.all(6) {
                guard let m = field.message, m[3]?.string == key else { continue }
                return m.all(2).compactMap { CascadeDecoder.customValue($0, key: key) }
            }
            return []
        }

        var subtitle: String {
            switch typeName {
            case "MailMessageEntity", "MailAttachmentEntity":
                return author
            case "ReminderEntity", "SectionEntity", "ListEntity":
                return group(11)?[1]?.string ?? ""
            case "ContactEntity":
                return (group(10)?.all(2).compactMap(\.string) ?? []).joined(separator: " · ")
            case "BookmarkEntity", "ReadingListItemEntity", "HistoryEntity":
                return group(3)?[4]?.string ?? ""
            case "SongSiriEntity", "AlbumSiriEntity":
                return [group(8)?[2]?.string, group(8)?[1]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            case "AssetEntity":
                let classes = custom("photosContentClassifications")
                if !classes.isEmpty { return classes.prefix(4).joined(separator: " · ") }
                return group(9)?[3]?.string ?? ""
            default:
                let author = self.author
                if !author.isEmpty { return author }
                if let t = group(3)?[14]?.string, !t.isEmpty, t != title { return t }
                if let k = group(3)?[1]?.string, !k.isEmpty, k != title { return k }
                let home = custom("HomeKit_homeName")
                return home.first ?? ""
            }
        }
    }

    static func customValue(_ field: ProtoField, key: String) -> String? {
        guard let m = field.message else { return field.string }
        if let s = m[1]?.string { return s }
        if let i = m[2]?.int { return String(i) }
        if let d = m[3]?.double {
            if key.lowercased().contains("date"), d > 0, DossierDate.isPlausible(DossierDate.cocoa(d)) {
                return DossierDate.medium(DossierDate.cocoa(d))
            }
            return Format.number(d, maxDigits: 6)
        }
        if let b = m[4]?.bool { return b ? "Yes" : "No" }
        return nil
    }

    // MARK: Detail

    static func scalarText(_ field: ProtoField, dateLike: Bool) -> String? {
        switch field.value.wireTypeName {
        case "varint":
            return field.int.map { String($0) }
        case "fixed64":
            guard let d = field.double else { return nil }
            if dateLike, let date = plausibleUnix(d) { return DossierDate.medium(date) }
            return Format.number(d, maxDigits: 6)
        case "fixed32":
            return field.float.map { Format.number(Double($0), maxDigits: 4) }
        default:
            switch field.guess {
            case .string(let s): return s
            case .message(let m): return m.allStrings(maxDepth: 4, limit: 12).joined(separator: " · ")
            case .data(let d): return "\(d.count) bytes"
            case .number: return nil
            }
        }
    }

    static func detail(
        set: CascadeSetInfo, row: CascadeRow, meta: Data?, raw: Data?, sourceHash: Int64?,
        attachments: [CascadeAttachmentRef], origin: [KeyValueItem]
    ) -> CascadeDetail {
        let content = raw.map(CascadeBlob.decode) ?? Data()
        let sensitivity = set.kind.sensitivity
        var attributes: [KeyValueItem] = []
        var custom: [KeyValueItem] = []
        var headers: [KeyValueItem] = []
        var nodes: [DataNode] = []
        var text: String?

        if set.kind.isPlainText {
            text = content.lossyUTF8
        } else if let msg = ProtoMessage(content) {
            nodes = DataNode.from(msg)
            if set.isIndexedEntity || looksLikeEntity(msg) {
                let entity = Entity(msg)
                if let attrs = entity.attrs {
                    var seen: [String: Int] = [:]
                    var order: [String] = []
                    var values: [String: [String]] = [:]
                    for groupField in attrs.fields {
                        let g = groupField.number
                        guard g != 13, let group = groupField.message else { continue }
                        for field in group.fields {
                            if g == 3 && field.number == 3 { continue }       // content type tree
                            if g == 10 && field.number == 29 {                // header block
                                if let h = field.message, let name = h[1]?.string {
                                    let value = h.all(2).compactMap(\.string).joined(separator: "\n")
                                    let n = (seen["h:" + name] ?? 0) + 1
                                    seen["h:" + name] = n
                                    headers.append(KeyValueItem(name, value, sensitivity: sensitivity, id: "h:\(name):\(n)"))
                                }
                                continue
                            }
                            let label = groupLabels[g]?[field.number] ?? "Attribute \(g).\(field.number)"
                            let dateLike = g == 5 || g == 7 || (g == 10 && field.number == 25)
                            guard let value = scalarText(field, dateLike: dateLike), !value.isEmpty else { continue }
                            if values[label] == nil { order.append(label) }
                            values[label, default: []].append(value)
                        }
                    }
                    for label in order {
                        var unique: [String] = []
                        for v in values[label] ?? [] where !unique.contains(v) { unique.append(v) }
                        attributes.append(KeyValueItem(label, unique.joined(separator: ", "), sensitivity: sensitivity, id: "a:" + label))
                    }
                }
                for (index, field) in msg.all(6).enumerated() {
                    guard let m = field.message, let key = m[3]?.string else { continue }
                    let value = m.all(2).compactMap { customValue($0, key: key) }.joined(separator: ", ")
                    custom.append(KeyValueItem(key, value, sensitivity: sensitivity, id: "c:\(index):" + key))
                }
            } else {
                let labels = rawLabels[set.stream] ?? [:]
                var seen: [Int: Int] = [:]
                for field in msg.fields {
                    let n = (seen[field.number] ?? 0) + 1
                    seen[field.number] = n
                    let label = labels[field.number] ?? "Field \(field.number)"
                    let value = scalarText(field, dateLike: true) ?? ""
                    guard !value.isEmpty else { continue }
                    attributes.append(KeyValueItem(label, value, sensitivity: sensitivity, id: "r:\(field.number):\(n)"))
                }
            }
        }

        var identifiers: [KeyValueItem] = []
        if let metaMsg = meta.flatMap({ ProtoMessage($0) }) {
            var seen: [Int: Int] = [:]
            for field in metaMsg.fields {
                let n = (seen[field.number] ?? 0) + 1
                seen[field.number] = n
                guard let label = metaLabels[field.number] else { continue }
                var value = field.string ?? ""
                if field.number == 5, let d = field.double.flatMap(plausibleUnix) { value = DossierDate.medium(d) }
                guard !value.isEmpty else { continue }
                identifiers.append(KeyValueItem(label, value, sensitivity: .personal, monospaced: field.number != 5, id: "m:\(field.number):\(n)"))
            }
        }
        identifiers.append(KeyValueItem("Sequence", String(row.id), monospaced: true, id: "seq"))
        if let written = row.written { identifiers.append(KeyValueItem("Written to Set", DossierDate.medium(written), id: "written")) }
        identifiers.append(KeyValueItem("Size", row.storedBytes == row.bytes ? Format.bytes(row.bytes) : "\(Format.bytes(row.bytes)) (\(Format.bytes(row.storedBytes)) compressed)", id: "size"))

        return CascadeDetail(
            set: set, row: row, attributes: attributes, custom: custom, identifiers: identifiers, headers: headers,
            text: text, nodes: nodes, sourceHash: sourceHash, attachments: attachments, origin: origin
        )
    }
}
