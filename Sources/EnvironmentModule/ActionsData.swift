import Foundation
import DossierCore

// MARK: - Model

enum ActionKind: String, CaseIterable, Sendable, Identifiable {
    case settings = "Settings Pane"
    case appIntent = "App Intent"
    case siriIntent = "Intent Donation"
    case maps = "Maps"
    case menu = "Menu Item"
    case document = "Document"
    case screenshot = "Screenshot"
    case auth = "Auth Dialog"
    case mailSearch = "Mail Search"
    case settingsSearch = "Settings Search"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .appIntent: return "bolt"
        case .siriIntent: return "wand.and.stars"
        case .maps: return "map"
        case .menu: return "filemenu.and.selection"
        case .document: return "doc"
        case .screenshot: return "camera.viewfinder"
        case .auth: return "lock.shield"
        case .mailSearch: return "envelope.badge"
        case .settingsSearch: return "magnifyingglass"
        }
    }

    /// Plain-English description of where rows of this kind come from.
    var explanation: String {
        switch self {
        case .settings: return "System Settings donates every pane you navigate to as an App Intent; linkd keeps the transcript."
        case .appIntent: return "App Intents executed by apps or the system (Focus filters, calls, calendar and mail actions), recorded by linkd with their resolved parameters."
        case .siriIntent: return "SiriKit intents donated by apps to the Biome App.Intent stream so the system can learn routines."
        case .maps: return "Maps and Find My interactions synced through CoreDuet (knowledgeC), including the address of each destination."
        case .menu: return "Menu bar commands you chose, recorded per app in the Biome App.MenuItem stream."
        case .document: return "Documents opened through an app, with the file path and the opening app."
        case .screenshot: return "Every screenshot taken, with the path it was saved to."
        case .auth: return "Authentication dialogs shown by the system (password / Touch ID prompts) and what asked for them."
        case .mailSearch: return "Search terms typed into Mail."
        case .settingsSearch: return "Search terms typed into System Settings."
        }
    }
}

struct ActionRow: Identifiable, Sendable {
    let id: String
    let date: Date
    let kind: ActionKind
    let app: String
    let title: String
    let detail: String
    let device: String
    /// Name of the backing store / stream.
    let store: String
    let params: [KV]
    let ref: RawRef

    func matches(_ needle: String) -> Bool {
        title.localizedCaseInsensitiveContains(needle) || detail.localizedCaseInsensitiveContains(needle)
            || app.localizedCaseInsensitiveContains(needle) || EnvFormat.appName(app).localizedCaseInsensitiveContains(needle) || kind.rawValue.localizedCaseInsensitiveContains(needle)
    }
}

struct ActionsData: Sendable {
    var rows: [ActionRow] = []
    var counts: [ActionKind: Int] = [:]
    /// Per-source record counts (for the self-test), in load order.
    var sources: [(name: String, count: Int, range: ClosedRange<Date>?)] = []
    var linkdAvailability: Availability = .missing
}

// MARK: - Biome helpers

enum EnvBiome {
    /// Upper bound on rows materialized per stream (newest first).
    static let rowCap = 200_000

    static func stream(_ name: String) -> BiomeStream? {
        let dir = EnvPaths.stream(name)
        guard Paths.probe(dir).isAvailable else { return nil }
        return Biome.loadStream(dir)
    }

    /// Iterates a restricted stream newest-first, decoding each payload as protobuf.
    static func forEach(_ name: String, _ body: (BiomeStreamReader.Record, ProtoMessage) -> Void) {
        guard let s = stream(name) else { return }
        var n = 0
        BiomeStreamReader(s).forEachMessage(order: .newestFirst) { record, message in
            body(record, message)
            n += 1
            return n < rowCap
        }
    }

    static func ref(_ record: BiomeStreamReader.Record) -> RawRef {
        .segb(path: record.segment.url.path, index: record.entry.index)
    }

    /// Live record count and time range without decoding payloads.
    static func stats(_ name: String) -> (available: Bool, records: Int, range: ClosedRange<Date>?, bytes: Int64) {
        guard let s = stream(name) else { return (false, 0, nil, 0) }
        let stats = BiomeStreamReader(s).stats()
        return (true, stats.records, stats.timeRange, s.totalSize)
    }
}

// MARK: - Loader

enum ActionsLoader {
    static func load(token: Int) async throws -> ActionsData {
        await EnvCache.shared.sync(token: token)
        return try await EnvCache.shared.value("actions") { await build() }
    }

    private static func build() async -> ActionsData {
        var data = ActionsData()
        let namer = await DeviceNamer.load()
        var rows: [ActionRow] = []

        func add(_ name: String, _ new: [ActionRow]) {
            let dates = new.map(\.date)
            let range = dates.min().flatMap { lo in dates.max().map { lo...$0 } }
            data.sources.append((name, new.count, range))
            rows.append(contentsOf: new)
        }

        // linkd App Intents transcript (falls back to the Biome copy when unavailable).
        data.linkdAvailability = Paths.probe(EnvPaths.linkdTranscripts)
        let linkd = Linkd.rows()
        if data.linkdAvailability.isAvailable {
            add("linkd ActionTranscript", linkd)
        } else {
            add("App.Intents.Transcript", intentsTranscript(namer))
        }
        add("App.Intent", appIntent(namer))
        add("App.MenuItem", menuItems(namer))
        add("App.DocumentInteraction", documents(namer))
        add("Screenshots.Screenshot", screenshots(namer))
        add("LocalAuthentication.UI.Dialogs", authDialogs(namer))
        add("Mail.Search.Query", searchTerms("Mail.Search.Query", kind: .mailSearch, app: "com.apple.mail", namer))
        add("SystemSettings.SearchTerms", searchTerms("SystemSettings.SearchTerms", kind: .settingsSearch, app: "com.apple.systempreferences", namer))
        add("knowledgeC /app/intents (Maps, Find My)", await KnowledgeSource.mapsActions())

        rows.sort { $0.date > $1.date }
        data.rows = rows
        for row in rows { data.counts[row.kind, default: 0] += 1 }
        return data
    }

    // App.Intents.Transcript — 1 bundle id, 2 source, 3 execution UUID bytes, 4 Unix date,
    // 5/6 original / resolved action { 1 identifier, 7 parameters { 1 name } }.
    private static func intentsTranscript(_ namer: DeviceNamer) -> [ActionRow] {
        var out: [ActionRow] = []
        EnvBiome.forEach("App.Intents.Transcript") { record, msg in
            let bundle = msg[1]?.string ?? ""
            let action = msg[6]?.message ?? msg[5]?.message
            let identifier = action?[1]?.string ?? "Action"
            let names = action?.all(7).compactMap { $0.message?[1]?.string } ?? []
            let isSettings = identifier.hasPrefix("SettingsNavigation")
            out.append(ActionRow(
                id: "ait|" + record.id, date: record.timestamp, kind: isSettings ? .settings : .appIntent, app: bundle,
                title: EnvFormat.humanize(identifier), detail: names.isEmpty ? "" : "Parameters: " + names.joined(separator: ", "),
                device: namer.name(record.device), store: "App.Intents.Transcript",
                params: [KV("Action", identifier), KV("App", bundle)] + names.map { KV("Parameter", $0) },
                ref: EnvBiome.ref(record)))
        }
        return out
    }

    // App.Intent — 1 Cocoa date, 2 bundle id, 3 source ("intents"), 4 intent class, 5 verb,
    // 6/7/10/11 numeric codes, 8 NSKeyedArchiver INInteraction, 9 interaction UUID, 12 item id.
    private static func appIntent(_ namer: DeviceNamer) -> [ActionRow] {
        var out: [ActionRow] = []
        EnvBiome.forEach("App.Intent") { record, msg in
            let bundle = msg[2]?.string ?? ""
            let cls = msg[4]?.string ?? "Intent"
            let verb = msg[5]?.string ?? ""
            var params = [KV("Intent class", cls), KV("Verb", verb), KV("App", bundle)]
            if let s = msg[3]?.string { params.append(KV("Donation source", s)) }
            if let item = msg[12]?.string, !item.isEmpty { params.append(KV("Item / handle", item)) }
            if let id = msg[9]?.string { params.append(KV("Interaction ID", id)) }
            for n in [6, 7, 10, 11] {
                if let v = msg[n]?.int { params.append(KV("Code (field \(n))", String(v))) }
            }
            if let size = msg[8]?.data?.count { params.append(KV("Serialized interaction", Format.bytes(size))) }
            out.append(ActionRow(
                id: "ai|" + record.id, date: msg[1]?.cocoaDate ?? record.timestamp, kind: .siriIntent, app: bundle,
                title: EnvFormat.humanize(cls), detail: msg[12]?.string ?? verb,
                device: namer.name(record.device), store: "App.Intent", params: params, ref: EnvBiome.ref(record)))
        }
        return out
    }

    // App.MenuItem — 1 bundle id, 3 menu path components (repeated: menu, submenu…, item).
    private static func menuItems(_ namer: DeviceNamer) -> [ActionRow] {
        var out: [ActionRow] = []
        EnvBiome.forEach("App.MenuItem") { record, msg in
            let bundle = msg[1]?.string ?? ""
            let path = msg.all(3).compactMap(\.string)
            out.append(ActionRow(
                id: "menu|" + record.id, date: record.timestamp, kind: .menu, app: bundle,
                title: path.last ?? "Menu item", detail: path.count > 1 ? path.joined(separator: " › ") : "",
                device: namer.name(record.device), store: "App.MenuItem",
                params: [KV("App", bundle), KV("Menu path", path.joined(separator: " › "))], ref: EnvBiome.ref(record)))
        }
        return out
    }

    // App.DocumentInteraction — 1 interaction type, 2 { 1 path, 2 bookmark data }, 3 UTI,
    // 4 { 1 app bundle id, 2 app URL }.
    private static func documents(_ namer: DeviceNamer) -> [ActionRow] {
        var out: [ActionRow] = []
        EnvBiome.forEach("App.DocumentInteraction") { record, msg in
            let path = msg.string(at: 2, 1) ?? ""
            let app = msg.string(at: 4, 1) ?? ""
            var params = [KV("Path", path), KV("Content type", msg[3]?.string ?? "—"), KV("Opened with", app)]
            if let url = msg.string(at: 4, 2) { params.append(KV("App location", url)) }
            if let t = msg[1]?.int { params.append(KV("Interaction type", String(t))) }
            out.append(ActionRow(
                id: "doc|" + record.id, date: record.timestamp, kind: .document, app: app,
                title: (path as NSString).lastPathComponent, detail: ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath,
                device: namer.name(record.device), store: "App.DocumentInteraction", params: params, ref: EnvBiome.ref(record)))
        }
        return out
    }

    // Screenshots.Screenshot — 1 { 1/2/6 numeric codes, 4 { 1 file path, 2 security-scoped
    // URL archive, 3 content hash } }.
    private static func screenshots(_ namer: DeviceNamer) -> [ActionRow] {
        var out: [ActionRow] = []
        EnvBiome.forEach("Screenshots.Screenshot") { record, msg in
            let inner = msg[1]?.message
            let file = inner?[4]?.message
            let path = file?[1]?.string ?? ""
            var params = [KV("Saved to", path)]
            if let hash = file?[3]?.data { params.append(KV("Content hash", hash.map { String(format: "%02x", $0) }.joined())) }
            for n in [1, 2, 6] {
                if let v = inner?[n]?.int { params.append(KV("Code (field \(n))", String(v))) }
            }
            out.append(ActionRow(
                id: "shot|" + record.id, date: record.timestamp, kind: .screenshot, app: "com.apple.screencaptureui",
                title: path.isEmpty ? "Screenshot" : (path as NSString).lastPathComponent,
                detail: ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath,
                device: namer.name(record.device), store: "Screenshots.Screenshot", params: params, ref: EnvBiome.ref(record)))
        }
        return out
    }

    // LocalAuthentication.UI.Dialogs — 1 presenting process, 2 requesting client (tool, bundle
    // id or authorization right), 3 dialog/process number, 4 (repeated) / 5 / 6 / 8 codes.
    private static func authDialogs(_ namer: DeviceNamer) -> [ActionRow] {
        var out: [ActionRow] = []
        EnvBiome.forEach("LocalAuthentication.UI.Dialogs") { record, msg in
            let presenter = msg[1]?.string ?? ""
            let client = msg[2]?.string ?? "Unknown requester"
            var params = [KV("Requested by", client), KV("Presented by", presenter)]
            if let n = msg[3]?.int { params.append(KV("Dialog number", String(n))) }
            let codes = msg.all(4).compactMap(\.int).map(String.init)
            if !codes.isEmpty { params.append(KV("Codes (field 4)", codes.joined(separator: ", "))) }
            for n in [5, 6, 8] {
                if let v = msg[n]?.int { params.append(KV("Code (field \(n))", String(v))) }
            }
            out.append(ActionRow(
                id: "auth|" + record.id, date: record.timestamp, kind: .auth, app: presenter,
                title: "Authentication for " + client, detail: "Dialog shown by " + EnvFormat.appName(presenter),
                device: namer.name(record.device), store: "LocalAuthentication.UI.Dialogs", params: params, ref: EnvBiome.ref(record)))
        }
        return out
    }

    // Mail.Search.Query / SystemSettings.SearchTerms — 1 query text, remaining fields flags.
    private static func searchTerms(_ stream: String, kind: ActionKind, app: String, _ namer: DeviceNamer) -> [ActionRow] {
        var out: [ActionRow] = []
        EnvBiome.forEach(stream) { record, msg in
            let query = msg[1]?.string ?? msg.allStrings(limit: 1).first ?? ""
            var params = [KV("Query", query)]
            for field in msg.fields where field.number != 1 {
                if let v = field.int { params.append(KV("Flag (field \(field.number))", String(v))) }
            }
            out.append(ActionRow(
                id: "q|\(stream)|" + record.id, date: record.timestamp, kind: kind, app: app,
                title: query.isEmpty ? "(empty query)" : "“\(query)”", detail: "Search query",
                device: namer.name(record.device), store: stream, params: params, ref: EnvBiome.ref(record)))
        }
        return out
    }
}

// MARK: - linkd ActionTranscript

/// `<linkd container>/ActionTranscript/<bundle id>/local/<segment>`: SEGB files whose
/// payloads are NSKeyedArchiver `LNTranscriptActionRecord` graphs. The `System` directory
/// repeats every record of the per-app directories, so records are de-duplicated by their
/// execution UUID.
enum Linkd {
    static func streams() -> [BiomeStream] {
        guard let root = EnvPaths.linkdTranscripts, Paths.probe(root).isAvailable,
              let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        // Per-app directories first so their copy wins over the aggregated "System" one.
        let sorted = dirs.sorted { a, b in
            let sa = a.lastPathComponent == "System", sb = b.lastPathComponent == "System"
            return sa == sb ? a.lastPathComponent < b.lastPathComponent : !sa
        }
        return sorted.compactMap { Biome.loadStream($0) }.filter { !$0.dataSegments().isEmpty }
    }

    static func rows() -> [ActionRow] {
        var out: [ActionRow] = []
        var seen = Set<String>()
        for stream in streams() {
            var n = 0
            BiomeStreamReader(stream).forEach(order: .newestFirst) { record in
                n += 1
                guard let row = decode(record, directory: stream.name), seen.insert(row.id).inserted else { return n < EnvBiome.rowCap }
                out.append(row)
                return n < EnvBiome.rowCap
            }
        }
        return out
    }

    /// Total records over all directories (duplicates included) and distinct executions.
    static func counts() -> (records: Int, distinct: Int) {
        var total = 0
        for stream in streams() { total += BiomeStreamReader(stream).stats().records }
        return (total, rows().count)
    }

    private static func decode(_ record: BiomeStreamReader.Record, directory: String) -> ActionRow? {
        guard let archive = KeyedArchive(record.payload), let root = archive.deref(archive.root) else { return nil }
        let bundle = archive.string(root["bundleIdentifier"]) ?? directory
        let action = archive.deref(root["resolvedAction"]) ?? archive.deref(root["originalAction"])
        let identifier = archive.string(action?["identifier"]) ?? "Action"
        let uuid = archive.uuid(root["executionUUID"]) ?? record.id
        let date = archive.date(root["executionDate"]) ?? record.timestamp

        var params: [KV] = [KV("Action", identifier), KV("App", bundle)]
        if let source = root["source"]?.int { params.append(KV("Source code", String(source))) }
        if let label = archive.string(root["clientLabel"]) { params.append(KV("Client", label)) }
        var flat: [KV] = []
        for property in archive.items(action?["parameters"]) {
            let name = archive.string(property["identifier"]) ?? "parameter"
            LNValue.flatten(archive, property["value"], prefix: name, depth: 0, into: &flat)
        }
        params.append(contentsOf: flat.prefix(40))
        if let protocols = action.map({ archive.items($0["systemProtocols"]) }), !protocols.isEmpty {
            let names = protocols.compactMap { archive.string($0["identifier"]) }
            if !names.isEmpty { params.append(KV("System protocols", names.joined(separator: ", "))) }
        }
        params.append(KV("Execution ID", uuid))

        let isSettings = identifier.hasPrefix("SettingsNavigation")
        var title = EnvFormat.humanize(identifier)
        var detail = flat.filter { !$0.value.isEmpty && $0.value != "—" }.prefix(3).map { "\($0.key): \($0.value)" }.joined(separator: " · ")
        if isSettings {
            let pane = flat.first { $0.key.hasSuffix("title") }?.value
            let url = archive.allStrings.first { $0.hasPrefix("settings-navigation://") }
            title = "Opened " + (pane ?? "a settings pane")
            detail = url ?? ""
            if let url { params.append(KV("Navigation URL", url)) }
        }
        return ActionRow(
            id: "ln|" + uuid, date: date, kind: isSettings ? .settings : .appIntent, app: bundle,
            title: title, detail: EnvFormat.oneLine(detail, max: 200), device: "This Mac",
            store: "linkd ActionTranscript", params: params, ref: EnvBiome.ref(record))
    }
}

/// Flattens App Intents ("Link") value graphs — `LNValue`, `LNEntity`, `LNProperty`,
/// `INFile`, localized strings — into readable key/value pairs.
enum LNValue {
    static func flatten(_ archive: KeyedArchive, _ value: PlistValue?, prefix: String, depth: Int, into out: inout [KV]) {
        guard out.count < 60 else { return }
        guard let object = archive.deref(value) else {
            if depth == 0 { out.append(KV(prefix, "—")) }
            return
        }
        // Primitives.
        switch object {
        case .string(let s): out.append(KV(prefix, s)); return
        case .int(let i): out.append(KV(prefix, String(i))); return
        case .real(let d): out.append(KV(prefix, Format.number(d, maxDigits: 6))); return
        case .bool(let b): out.append(KV(prefix, b ? "true" : "false")); return
        case .date(let d): out.append(KV(prefix, DossierDate.medium(d))); return
        case .data(let d): out.append(KV(prefix, Format.bytes(d.count))); return
        default: break
        }
        guard depth < 12 else { return }
        let cls = archive.className(object) ?? ""
        switch cls {
        case "LNValue":
            flatten(archive, object["value"], prefix: prefix, depth: depth + 1, into: &out)
        case "LNEntity":
            let id = archive.deref(object["identifier"])
            if let type = archive.string(id?["typeIdentifier"]) { out.append(KV(prefix, type)) }
            for property in archive.items(object["properties"]) {
                let name = archive.string(property["identifier"]) ?? "property"
                flatten(archive, property["value"], prefix: prefix + "." + name, depth: depth + 1, into: &out)
            }
        case "LNProperty":
            let name = archive.string(object["identifier"]) ?? "property"
            flatten(archive, object["value"], prefix: prefix + "." + name, depth: depth + 1, into: &out)
        case "INFile":
            // Localized titles travel as a small JSON file: {"key": "<title>", …}.
            if let data = archive.data(object["data"]), let json = PlistDecoder.decodeJSON(data), let key = json["key"]?.string {
                out.append(KV(prefix, key))
            } else if let name = archive.string(object["filename"]) {
                out.append(KV(prefix, name))
            }
        case "NSDate":
            if let d = archive.date(object) { out.append(KV(prefix, DossierDate.medium(d))) }
        case "NSURL", "NSString", "NSMutableString":
            if let s = archive.string(object) { out.append(KV(prefix, s)) }
        case "NSUUID":
            if let s = archive.uuid(object) { out.append(KV(prefix, s)) }
        case "NSArray", "NSMutableArray", "NSSet", "NSMutableSet", "NSOrderedSet":
            let items = archive.items(object)
            if items.isEmpty { return }
            for (i, item) in items.prefix(6).enumerated() {
                flatten(archive, item, prefix: items.count == 1 ? prefix : "\(prefix)[\(i)]", depth: depth + 1, into: &out)
            }
        case "NSDictionary", "NSMutableDictionary":
            for pair in archive.pairs(object).prefix(8) {
                let key = archive.string(pair.key) ?? "key"
                flatten(archive, pair.value, prefix: prefix + "." + key, depth: depth + 1, into: &out)
            }
        case "LNStaticDeferredLocalizedString":
            if let s = archive.string(object["defaultValue"]) ?? archive.string(object["key"]) { out.append(KV(prefix, s)) }
        default:
            // Unknown object: surface its directly stored strings / numbers (person names,
            // handles, enumeration cases…), one level deep.
            guard case .dict(let pairs) = object else { return }
            var found = false
            for pair in pairs where pair.key != "$class" {
                guard let member = archive.deref(pair.value) else { continue }
                switch member {
                case .string(let s) where !s.isEmpty && s != "$null":
                    out.append(KV(prefix + "." + pair.key, s)); found = true
                case .dict:
                    if depth < 9, ["value", "displayString", "personHandle", "nameComponents", "identifier", "title", "name"].contains(pair.key) {
                        let before = out.count
                        flatten(archive, member, prefix: prefix + "." + pair.key, depth: depth + 2, into: &out)
                        found = found || out.count > before
                    }
                default: break
                }
            }
            if !found, !cls.isEmpty, depth <= 2 { out.append(KV(prefix, "‹\(cls)›")) }
        }
    }
}
