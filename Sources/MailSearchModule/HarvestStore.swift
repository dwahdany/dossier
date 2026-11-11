import Foundation
import DossierCore

// Biome streams of the harvesting / text-understanding pipeline. Protobuf field numbers
// were established empirically on macOS 27 (not a published schema):
//
// ProactiveHarvesting.Mail — a full copy of a message queued for analysis:
//   1 message id, 2 domain identifier, 3 date (Cocoa), 4 account id, 10* { 1 header name,
//   2 value }, 11 subject, 14 HTML body, 17 account address, 19* mailboxes, 21 account
//   type, 23 { 1 name, 2 address } author, 24* { 1 name, 2 address } recipients, 30 date.
// TextUnderstanding.Output.Document — a document the pipeline has processed:
//   1 { 1 bundle id, 2 domain identifier, 3 item id }, 2 processed (Cocoa), 3 document
//   date (Cocoa), 12 title, 14* mailboxes, 17 body snippet, 18 { 1 name, 2 handle } author,
//   19* / 24* recipients, 22 account type.
// TextUnderstanding.Output.Event — an event extracted from a document:
//   1 source (as above), 3 / 4 extraction kind, 5 { 26 iCalendar text }, 6 start (unix),
//   7 end (unix), 13 notes, 14 title.
// TextUnderstanding.Deletions.Document — the deletion log:
//   1 bundle id, 2 domain identifier, 3 item id, 4 date (Cocoa), 9 reason code.
// Mail.Search.Query — 1 query text as typed into Mail's search field.

enum HarvestGroup: String, CaseIterable, Sendable {
    case queue = "Harvest Queue"
    case extracted = "Understood & Extracted"
    case deletions = "Deletion Log"
    case search = "Mail Search"
}

struct HarvestStream: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let group: HarvestGroup
    let title: String
    let explanation: String
    let symbol: String
    let live: Int
    let deleted: Int
    let bytes: Int64
    let range: ClosedRange<Date>?
    let stream: BiomeStream

    var sensitivity: Sensitivity { name.hasPrefix("TextUnderstanding.Deletions") ? .personal : .sensitive }
}

struct HarvestRow: Identifiable, Sendable, Hashable {
    let id: String
    let when: Date
    let title: String
    let subtitle: String
    let extra: String
    let bytes: Int
    let remote: Bool
}

struct HarvestDetail: Sendable {
    let row: HarvestRow
    let items: [KeyValueItem]
    let headers: [KeyValueItem]
    /// Body / notes / iCalendar text, shown on demand.
    let text: String?
    let textLabel: String
    let nodes: [DataNode]
}

enum HarvestStore {
    static let prefixes = ["ProactiveHarvesting.", "TextUnderstanding.", "Mail.Search."]
    static let rowLimit = 5_000

    private static func describe(_ name: String) -> (HarvestGroup, String, String, String) {
        if name.hasPrefix("ProactiveHarvesting.") {
            let what = String(name.dropFirst("ProactiveHarvesting.".count))
            let pretty = CascadeSetInfo.spaced(what.replacingOccurrences(of: ".", with: " "))
            let text: String
            switch what {
            case "Mail": text = "Complete copies of mail messages (headers and HTML body) waiting to be analysed. Records are erased once consumed, so the live queue is usually short."
            case "Messages": text = "Message texts queued for analysis."
            case "Safari.PageView": text = "Pages viewed in Safari, queued for analysis."
            case "Reminders": text = "Reminders queued for analysis."
            case "Notes": text = "Note contents queued for analysis."
            case "Notifications", "NotificationStacks": text = "Notification contents queued for analysis."
            case "Siri.Query": text = "Siri requests queued for analysis."
            default: text = "Content from this source queued for analysis by the proactive harvesting pipeline."
            }
            return (.queue, pretty, text, "tray.and.arrow.down")
        }
        switch name {
        case "TextUnderstanding.Output.Document":
            return (.extracted, "Processed Documents", "Documents the text-understanding pipeline has read: source app, title, author, recipients and a body snippet.", "doc.text.magnifyingglass")
        case "TextUnderstanding.Output.Event":
            return (.extracted, "Extracted Events", "Events found inside your documents (for example calendar invitations in mail), with start and end time.", "calendar.badge.clock")
        case "TextUnderstanding.Output.Link":
            return (.extracted, "Extracted Links", "Links found inside your documents.", "link")
        case "TextUnderstanding.Deletions.Document":
            return (.deletions, "Document Deletions", "Every request to forget a document: which app's item was removed from the derived stores, and when.", "trash")
        case "Mail.Search.Query":
            return (.search, "Search Queries", "What you typed into Mail's search field.", "magnifyingglass")
        case "Mail.Search.UIEvent":
            return (.search, "Search UI Events", "Interactions with Mail search results.", "cursorarrow.click")
        case "Mail.Search.RankerEvent":
            return (.search, "Search Ranker Events", "Ranking features of the results Mail search showed (scores per message id).", "list.number")
        default:
            let group: HarvestGroup = name.hasPrefix("Mail.Search.") ? .search : (name.contains("Deletion") ? .deletions : .extracted)
            return (group, CascadeSetInfo.spaced(name.replacingOccurrences(of: ".", with: " ")), "Biome stream \(name).", "waveform.path.ecg")
        }
    }

    /// All matching streams with record statistics (index only, no payload decoding).
    static func streams() -> [HarvestStream] {
        let all = Biome.discoverAllStreams().filter { s in prefixes.contains { s.name.hasPrefix($0) } }
        var out: [HarvestStream] = []
        for stream in all {
            if Task.isCancelled { break }
            let stats = BiomeStreamReader(stream).stats()
            let (group, title, explanation, symbol) = describe(stream.name)
            out.append(HarvestStream(
                name: stream.name, group: group, title: title, explanation: explanation, symbol: symbol,
                live: stats.records, deleted: stats.deleted, bytes: stats.bytes, range: stats.timeRange, stream: stream
            ))
        }
        let groups = HarvestGroup.allCases
        return out.sorted { a, b in
            let ga = groups.firstIndex(of: a.group) ?? 0, gb = groups.firstIndex(of: b.group) ?? 0
            if ga != gb { return ga < gb }
            if (a.live > 0) != (b.live > 0) { return a.live > 0 }
            return a.title < b.title
        }
    }

    private static func person(_ field: ProtoField?) -> String {
        guard let m = field?.message else { return "" }
        let name = m[1]?.string ?? "", address = m[2]?.string ?? ""
        if name.isEmpty { return address }
        return address.isEmpty ? name : "\(name) <\(address)>"
    }

    private static func source(_ field: ProtoField?) -> (bundle: String, domain: String, item: String) {
        guard let m = field?.message else { return ("", "", "") }
        return (m[1]?.string ?? "", m[2]?.string ?? "", m[3]?.string ?? "")
    }

    private static func row(_ name: String, _ record: BiomeStreamReader.Record, _ msg: ProtoMessage?) -> HarvestRow {
        var title = "", subtitle = "", extra = ""
        if let msg {
            switch name {
            case "ProactiveHarvesting.Mail":
                title = msg[11]?.string ?? ""
                subtitle = person(msg[23])
                extra = msg[17]?.string ?? ""
            case "TextUnderstanding.Output.Document":
                title = msg[12]?.string ?? ""
                subtitle = person(msg[18])
                extra = source(msg[1]).bundle
            case "TextUnderstanding.Output.Event":
                title = msg[14]?.string ?? ""
                let start = msg[6]?.unixDate, end = msg[7]?.unixDate
                if let start { subtitle = DossierDate.medium(start) + (end.map { " – " + DossierDate.short($0) } ?? "") }
                extra = [msg[3]?.string, source(msg[1]).bundle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            case "TextUnderstanding.Deletions.Document":
                title = msg[1]?.string ?? ""
                subtitle = msg[3]?.string ?? msg[2]?.string ?? ""
                extra = msg[9]?.int.map { "reason \($0)" } ?? ""
            case "Mail.Search.Query":
                title = msg[1]?.string ?? ""
                subtitle = "typed in Mail search"
            default:
                let strings = msg.allStrings(maxDepth: 4, limit: 6).filter { !$0.isEmpty }
                title = strings.first ?? ""
                subtitle = strings.dropFirst().prefix(2).joined(separator: " · ")
            }
        }
        if title.isEmpty { title = msg == nil ? "Undecoded record" : "Record" }
        return HarvestRow(
            id: record.id, when: record.timestamp, title: Format.oneLine(title, max: 220), subtitle: Format.oneLine(subtitle, max: 180),
            extra: Format.oneLine(extra, max: 120), bytes: record.payload.count, remote: !record.device.isLocal
        )
    }

    /// Newest live records of a stream (at most ``rowLimit``).
    static func rows(_ stream: HarvestStream) -> [HarvestRow] {
        var out: [HarvestRow] = []
        BiomeStreamReader(stream.stream).forEach(order: .newestFirst) { record in
            out.append(row(stream.name, record, ProtoMessage(record.payload)))
            return out.count < rowLimit && !Task.isCancelled
        }
        return out.sorted { $0.when > $1.when }
    }

    /// Full decode of one record, found again by its id.
    static func detail(_ stream: HarvestStream, row: HarvestRow) throws -> HarvestDetail {
        var payload: Data?
        BiomeStreamReader(stream.stream).forEach(order: .newestFirst) { record in
            if record.id == row.id { payload = record.payload; return false }
            return !Task.isCancelled
        }
        guard let payload else { throw DossierError.message("This record has been removed from the stream since it was listed.") }
        guard let msg = ProtoMessage(payload) else {
            return HarvestDetail(row: row, items: [KeyValueItem("Size", Format.bytes(payload.count))], headers: [], text: nil, textLabel: "", nodes: [])
        }
        var items: [KeyValueItem] = []
        var headers: [KeyValueItem] = []
        var text: String?
        var textLabel = ""
        func add(_ label: String, _ value: String?, _ level: Sensitivity = .sensitive, mono: Bool = false) {
            guard let value, !value.isEmpty else { return }
            items.append(KeyValueItem(label, value, sensitivity: level, monospaced: mono, id: "\(items.count):\(label)"))
        }
        switch stream.name {
        case "ProactiveHarvesting.Mail":
            add("Subject", msg[11]?.string)
            add("From", person(msg[23]))
            add("To", msg.all(24).map { person($0) }.filter { !$0.isEmpty }.joined(separator: ", "))
            add("Account", msg[17]?.string)
            add("Date", (msg[3]?.cocoaDate ?? msg[30]?.cocoaDate).map { DossierDate.medium($0) }, .personal)
            add("Mailboxes", msg.all(19).compactMap(\.string).joined(separator: "\n"), .personal)
            add("Account Type", msg[21]?.string, .low)
            add("Message ID", msg[1]?.string, .personal, mono: true)
            add("Domain", msg[2]?.string, .personal, mono: true)
            for (index, field) in msg.all(10).enumerated() {
                guard let h = field.message, let name = h[1]?.string else { continue }
                headers.append(KeyValueItem(name, h[2]?.string ?? "", sensitivity: .sensitive, id: "h\(index)"))
            }
            if let html = msg[14]?.string { text = HTMLText.plain(html); textLabel = "Message Body" }
        case "TextUnderstanding.Output.Document":
            let src = source(msg[1])
            add("Title", msg[12]?.string)
            add("Author", person(msg[18]))
            add("Recipients", (msg.all(19) + msg.all(24)).map { person($0) }.filter { !$0.isEmpty }.joined(separator: ", "))
            add("Source App", src.bundle, .low, mono: true)
            add("Document Date", msg[3]?.cocoaDate.map { DossierDate.medium($0) }, .personal)
            add("Processed", msg[2]?.cocoaDate.map { DossierDate.medium($0) }, .low)
            add("Mailboxes", msg.all(14).compactMap(\.string).joined(separator: "\n"), .personal)
            add("Item ID", src.item, .personal, mono: true)
            add("Domain", src.domain, .personal, mono: true)
            if let snippet = msg[17]?.string { text = HTMLText.plain(snippet); textLabel = "Body Snippet" }
        case "TextUnderstanding.Output.Event":
            let src = source(msg[1])
            add("Title", msg[14]?.string)
            add("Starts", msg[6]?.unixDate.map { DossierDate.medium($0) })
            add("Ends", msg[7]?.unixDate.map { DossierDate.medium($0) })
            add("Notes", msg[13]?.string)
            add("Extraction", msg[3]?.string, .low)
            add("Source App", src.bundle, .low, mono: true)
            add("Item ID", src.item, .personal, mono: true)
            if let ics = msg[5]?.message?[26]?.string { text = ics; textLabel = "iCalendar Source" }
        case "TextUnderstanding.Deletions.Document":
            add("App", msg[1]?.string, .low, mono: true)
            add("Item ID", msg[3]?.string, .personal, mono: true)
            add("Domain", msg[2]?.string, .personal, mono: true)
            add("Deleted", msg[4]?.cocoaDate.map { DossierDate.medium($0) }, .low)
            add("Reason Code", msg[9]?.int.map { String($0) }, .low)
        case "Mail.Search.Query":
            add("Query", msg[1]?.string)
        default:
            for (index, s) in msg.allStrings(maxDepth: 4, limit: 12).enumerated() where !s.isEmpty { add("Text \(index + 1)", s) }
        }
        add("Recorded", DossierDate.medium(row.when), .low)
        add("Size", Format.bytes(payload.count), .low)
        return HarvestDetail(row: row, items: items, headers: headers, text: text, textLabel: textLabel, nodes: DataNode.from(msg))
    }
}

/// Minimal HTML → text reduction for showing harvested bodies without a web view.
enum HTMLText {
    static func plain(_ html: String, limit: Int = 400_000) -> String {
        guard html.contains("<") else { return html }
        var out = ""
        out.reserveCapacity(min(html.utf8.count, limit))
        var inTag = false
        var tag = ""
        var skipUntil: String?
        for ch in html {
            if out.utf8.count >= limit { out += "\n…"; break }
            if inTag {
                if ch == ">" {
                    inTag = false
                    let name = tag.lowercased().trimmingCharacters(in: .whitespaces)
                    let bare = name.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "\n" }).first.map(String.init) ?? ""
                    if let wanted = skipUntil {
                        if name.hasPrefix("/" + wanted) { skipUntil = nil }
                    } else if bare == "style" || bare == "script" || bare == "head" {
                        if !name.hasPrefix("/") && !name.hasSuffix("/") { skipUntil = bare }
                    } else if ["br", "p", "div", "tr", "li", "h1", "h2", "h3", "h4", "table"].contains(bare) || name.hasPrefix("/p") || name.hasPrefix("/div") || name.hasPrefix("/tr") {
                        if !out.hasSuffix("\n") { out.append("\n") }
                    } else if bare == "td" || bare == "th" {
                        if !out.hasSuffix(" ") && !out.hasSuffix("\n") { out.append(" ") }
                    }
                } else if tag.count < 64 {
                    tag.append(ch)
                }
                continue
            }
            if ch == "<" { inTag = true; tag = ""; continue }
            if skipUntil != nil { continue }
            if ch == "\r" { continue }
            if ch.isWhitespace {
                if ch == "\n" { if !out.hasSuffix("\n") && !out.hasSuffix(" ") { out.append(" ") } }
                else if !out.hasSuffix(" ") && !out.hasSuffix("\n") { out.append(" ") }
                continue
            }
            out.append(ch)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&zwnj;": "", "&shy;": ""]
        for (entity, replacement) in entities where out.contains(entity) { out = out.replacingOccurrences(of: entity, with: replacement) }
        if out.contains("&#") { out = decodeNumericEntities(out) }
        // Collapse runs of blank lines left over from layout tables.
        var lines: [Substring] = []
        var blank = 0
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy({ $0.isWhitespace }) { blank += 1; if blank > 1 { continue } } else { blank = 0 }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `&#8364;` / `&#x1F389;` → the character.
    static func decodeNumericEntities(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var rest = Substring(text)
        while let range = rest.range(of: "&#") {
            out += rest[..<range.lowerBound]
            let tail = rest[range.upperBound...]
            if let semicolon = tail.prefix(10).firstIndex(of: ";") {
                let body = tail[..<semicolon]
                let value = body.hasPrefix("x") || body.hasPrefix("X") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                if let value, let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                    rest = tail[tail.index(after: semicolon)...]
                    continue
                }
            }
            out += "&#"
            rest = tail
        }
        out += rest
        return out
    }
}
