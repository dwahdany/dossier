import SwiftUI
import DossierCore

// Other Siri memories — everything in the Siri Remembers view database that is neither a
// message nor a call: media requests, Find My lookups, shortcut runs, reminders, and the
// suggestions Siri offered or the owner followed. These arrive through the Biome streams
// `Siri.Remembers.InteractionHistory`, `.AudioHistory` and `.AssistantSuggestions`.
//
// Observed on real data (types are open-ended; unknown ones get a generic label):
//   INPlayMediaIntent            → entity `items` : MediaItem        fields { title, artist, mediaType }
//   DirectEngagement,
//   GetSuggestions_*             → entity `SuggestionEntities` : SuggestionAction   fields { exampleUtterance, … }
//   INRunWorkflowIntent, LocateDeviceIntent, LocateIntent, INAddTasksIntent,
//   CNUICreateContactIntent, WeatherIntent … → usually no entities and empty `fields`
//   interactions.isDonatedBySiri = 1 for what Siri itself recorded, 0 for app donations;
//   interactions.sourceStreams   = "^<stream>:remotes:<device id>^…" (only the stream name is shown).

struct SiriMemoryRow: Identifiable, Sendable, Hashable {
    var id: Int64                // interactions.rowid
    var interactionID: String
    var date: Date?
    var type: String
    var domain: String
    var bundle: String
    var summary: String          // readable digest of the linked entities
    var entityCount: Int
    var device: String
    var donatedBySiri: Bool?
    var status: Int64?
    var seconds: Double
    var streams: String

    var kind: String { SiriMemories.kindLabel(type) }
}

struct SiriMemoryKind: Identifiable, Sendable, Hashable {
    var id: String { type }
    var type: String
    var count: Int
    var bundles: [String]
    var label: String { SiriMemories.kindLabel(type) }
}

struct SiriMemoryDetail: Sendable {
    struct Entity: Sendable, Identifiable {
        let id: Int
        let parameter: String
        let type: String
        let value: String
        let fields: String
    }
    var fields: String
    var entities: [Entity]
}

enum SiriMemories {
    // MARK: Labels

    static func kindLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "inplaymediaintent": return "Play media"
        case "inrunworkflowintent": return "Run shortcut"
        case "locatedeviceintent": return "Locate device"
        case "locateintent": return "Locate (Find My)"
        case "inaddtasksintent": return "Add reminder"
        case "cnuicreatecontactintent": return "Create contact"
        case "weatherintent": return "Weather request"
        case "directengagement": return "Siri suggestion used"
        case "getsuggestions_assistantsuggestions": return "Siri suggestions shown"
        default: return humanise(type)
        }
    }

    static func kindSymbol(_ type: String) -> String {
        switch type.lowercased() {
        case "inplaymediaintent": return "play.circle"
        case "inrunworkflowintent": return "square.2.layers.3d"
        case "locatedeviceintent", "locateintent": return "location"
        case "inaddtasksintent": return "checklist"
        case "cnuicreatecontactintent": return "person.badge.plus"
        case "weatherintent": return "cloud.sun"
        case "directengagement": return "hand.tap"
        case "getsuggestions_assistantsuggestions": return "lightbulb"
        default: return "waveform"
        }
    }

    /// "INSearchForNotebookItemsIntent" → "Search for notebook items".
    static func humanise(_ type: String) -> String {
        var name = type
        if name.hasSuffix("Intent"), name.count > 6 { name.removeLast(6) }
        for prefix in ["CNUI", "IN"] where name.hasPrefix(prefix) && name.count > prefix.count {
            if name.dropFirst(prefix.count).first?.isUppercase == true { name.removeFirst(prefix.count); break }
        }
        var words = ""
        var previous: Character?
        for ch in name {
            if ch == "_" { words.append(" "); previous = nil; continue }
            if let previous, ch.isUppercase, previous.isLowercase || previous.isNumber { words.append(" ") }
            words.append(ch)
            previous = ch
        }
        let lower = words.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.isEmpty ? type : lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// "^Siri.Remembers.AudioHistory:remotes:<device id>^" → "Siri.Remembers.AudioHistory".
    static func streamNames(_ raw: String?) -> String {
        var names: [String] = []
        for part in (raw ?? "").split(separator: "^") {
            let name = String(part.split(separator: ":").first ?? "")
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: ", ")
    }

    // MARK: Queries

    private static let condition = "i.type NOT IN (?, ?)"
    private static var conditionParams: [SQLValue] { [.text(RemembersSchema.messageType), .text(RemembersSchema.callType)] }

    /// Readable digest of one entity (alias `e`): media title and artist, the example
    /// utterance of a suggestion, a person's name — or its id when nothing better exists.
    private static let entitySummary = """
        CASE WHEN json_valid(e.fields) THEN coalesce(
            nullif(json_extract(e.fields, '$.title'), '') || ' — ' || nullif(json_extract(e.fields, '$.artist'), ''),
            nullif(json_extract(e.fields, '$.title'), ''),
            nullif(json_extract(e.fields, '$.artist'), ''),
            nullif(json_extract(e.fields, '$.exampleUtterance'), ''),
            nullif(json_extract(e.fields, '$.name'), ''),
            e.id) ELSE e.id END
        """

    static func kinds() async throws -> [SiriMemoryKind] {
        let db = try await RemembersStore.open()
        let rows = try await db.rows("SELECT i.type, i.bundleId, count(*) FROM interactions i WHERE \(condition) GROUP BY 1, 2", conditionParams)
        var kinds: [String: SiriMemoryKind] = [:]
        for r in rows {
            guard let type = r[0].string else { continue }
            var kind = kinds[type.lowercased()] ?? SiriMemoryKind(type: type, count: 0, bundles: [])
            kind.count += Int(r[2].int ?? 0)
            if let bundle = r[1].string { kind.bundles.append(bundle) }
            kinds[type.lowercased()] = kind
        }
        return kinds.values.sorted { ($0.count, $1.label) > ($1.count, $0.label) }
    }

    static func total() async throws -> Int {
        let db = try await RemembersStore.open()
        return await db.count("SELECT count(*) FROM interactions i WHERE \(condition)", conditionParams) ?? 0
    }

    private static func filterSQL(type: String?, rowid: Int64?, search: String, entityOnly: Bool, kinds: [SiriMemoryKind]) -> (sql: String, params: [SQLValue]) {
        var parts = [condition]
        var params = conditionParams
        if let type { parts.append("i.type = ?"); params.append(.text(type)) }
        if let rowid { parts.append("i.rowid = ?"); params.append(.integer(rowid)) }
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            let pattern = CommsSQL.like(needle)
            var alternatives = ["""
                EXISTS (SELECT 1 FROM interactionEntities ie JOIN entities e ON e.rowid = ie.entityRowid
                        WHERE ie.interactionRowid = i.rowid AND (e.id LIKE ? ESCAPE '\\' OR e.fields LIKE ? ESCAPE '\\'))
                """]
            params += [.text(pattern), .text(pattern)]
            if !entityOnly {
                alternatives += ["i.type LIKE ? ESCAPE '\\'", "i.bundleId LIKE ? ESCAPE '\\'"]
                params += [.text(pattern), .text(pattern)]
                // The table shows humanised kinds and app names; let the filter match those too.
                func matches(_ text: String) -> Bool { text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                let types = kinds.filter { matches($0.label) }.map(\.type)
                let bundles = Set(kinds.flatMap(\.bundles)).filter { matches(AppNames.name($0)) }
                if !types.isEmpty {
                    alternatives.append("i.type IN (" + types.map { _ in "?" }.joined(separator: ",") + ")")
                    params += types.map { .text($0) }
                }
                if !bundles.isEmpty {
                    alternatives.append("i.bundleId IN (" + bundles.map { _ in "?" }.joined(separator: ",") + ")")
                    params += bundles.map { .text($0) }
                }
            }
            parts.append("(" + alternatives.joined(separator: " OR ") + ")")
        }
        return (parts.joined(separator: " AND "), params)
    }

    static func page(type: String? = nil, rowid: Int64? = nil, request: PageRequest, entityOnly: Bool = false, namer: RemembersStore.DeviceNamer) async throws -> [SiriMemoryRow] {
        let db = try await RemembersStore.open()
        let kinds = request.search.isEmpty || entityOnly ? [] : try await kinds()
        let (where_, params) = filterSQL(type: type, rowid: rowid, search: request.search, entityOnly: entityOnly, kinds: kinds)
        let cols = await db.columnSet(of: "interactions")
        func col(_ name: String, _ fallback: String) -> String { cols.contains(name) ? "i.\(name)" : fallback }
        let dev = await RemembersStore.deviceColumns(db)
        let sortColumn: String
        switch request.sort?.columnID {
        case "type": sortColumn = "i.type"
        case "bundleId": sortColumn = "i.bundleId"
        case "isDonatedBySiri": sortColumn = col("isDonatedBySiri", "i.startDate")
        default: sortColumn = "i.startDate"
        }
        let direction = request.sort?.sqlDirection ?? "DESC"
        let rows = try await db.rows("""
            SELECT i.rowid, \(col("id", "NULL")), i.type, \(col("domain", "''")), i.bundleId, i.startDate,
                   \(col("isDonatedBySiri", "NULL")), \(col("handlingStatus", "NULL")), \(col("durationSeconds", "0")), \(col("sourceStreams", "''")),
                   \(dev.isLocal), \(dev.platform), \(dev.remote),
                   (SELECT group_concat(x, ' · ') FROM (
                        SELECT \(entitySummary) x FROM interactionEntities ie JOIN entities e ON e.rowid = ie.entityRowid
                        WHERE ie.interactionRowid = i.rowid ORDER BY e.rowid LIMIT 8)),
                   (SELECT count(*) FROM interactionEntities ie WHERE ie.interactionRowid = i.rowid)
            FROM interactions i WHERE \(where_)
            ORDER BY \(sortColumn) \(direction), i.rowid \(direction) LIMIT ? OFFSET ?
            """, params + [.integer(Int64(request.limit)), .integer(Int64(request.offset))])
        return rows.compactMap { r in
            guard let rowid = r[0].int else { return nil }
            return SiriMemoryRow(
                id: rowid, interactionID: r[1].string ?? "", date: r[5].cocoaDate, type: r[2].string ?? "", domain: r[3].string ?? "",
                bundle: r[4].string ?? "", summary: r[13].string ?? "", entityCount: Int(r[14].int ?? 0),
                device: namer.name(isLocal: (r[10].int ?? 1) != 0, platform: r[11].int, remoteID: r[12].string),
                donatedBySiri: r[6].int.map { $0 != 0 }, status: r[7].int, seconds: r[8].double ?? 0,
                streams: streamNames(r[9].string))
        }
    }

    static func count(type: String?, search: String) async throws -> Int? {
        let db = try await RemembersStore.open()
        let kinds = search.isEmpty ? [] : try await kinds()
        let (where_, params) = filterSQL(type: type, rowid: nil, search: search, entityOnly: false, kinds: kinds)
        return await db.count("SELECT count(*) FROM interactions i WHERE \(where_)", params)
    }

    static func detail(_ rowid: Int64) async throws -> SiriMemoryDetail {
        let db = try await RemembersStore.open()
        let hasFields = await db.hasColumns("interactions", ["fields"])
        let fields = hasFields ? (try await db.first("SELECT fields FROM interactions WHERE rowid = ?", [.integer(rowid)]))?[0].string ?? "" : ""
        let entities = try await RemembersStore.interactionEntities(rowid).enumerated().map {
            SiriMemoryDetail.Entity(id: $0.offset, parameter: $0.element.parameter, type: $0.element.type, value: $0.element.id, fields: $0.element.fields)
        }
        return SiriMemoryDetail(fields: fields, entities: entities)
    }

    /// Global search: memories whose linked entities (media titles, suggestion texts …) match.
    static func search(_ query: String, limit: Int) async -> [SiriMemoryRow] {
        let namer = await RemembersStore.deviceNamer()
        return (try? await page(request: PageRequest(offset: 0, limit: limit, search: query), entityOnly: true, namer: namer)) ?? []
    }
}

/// (5b) Other Siri Memories — non-message, non-call interactions Siri remembers.
struct SiriMemoriesView: View {
    @State private var kind = ""
    @State private var kinds: [SiriMemoryKind] = []
    @State private var selected: SiriMemoryRow?
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink

    var body: some View {
        let _ = selected
        let token = refreshToken
        let type = kind.isEmpty ? nil : kind
        VStack(spacing: 0) {
            HeaderStrip {
                Picker("Kind", selection: $kind) {
                    Text("All kinds").tag("")
                    if !kinds.isEmpty { Divider() }
                    ForEach(kinds) { Text("\($0.label) (\(Format.count($0.count)))").tag($0.type) }
                }
                .labelsHidden().frame(width: 220)
                HeaderNote("What Siri remembers besides messages and calls: media you asked to play, Find My lookups, shortcut runs, reminders, and the suggestions Siri showed or you followed. Synced from your devices through Biome.")
            }
            PagedTable(
                columns: columns,
                searchPrompt: "Filter memories",
                reloadKey: AnyHashable([AnyHashable(token), AnyHashable(kind)]),
                exportName: "siri-memories",
                emptyTitle: "No Other Siri Memories",
                initialSort: PageSort(columnID: "startDate", ascending: false),
                fetch: { request in
                    let namer = await CommsCache.shared.deviceNamer(token)
                    return try await SiriMemories.page(type: type, request: request, namer: namer)
                },
                count: { request in try await SiriMemories.count(type: type, search: request.search) },
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { inspector(selected) }
            }
            StoreFooter(CommsPaths.remembersView, note: "interactions (other than INSendMessageIntent / INStartCallIntent) · entities")
        }
        .task(id: token) {
            await SnapshotReadiness.track { kinds = (try? await SiriMemories.kinds()) ?? [] }
        }
        .task(id: deepLink?.nonce) {
            guard let link = deepLink, link.payload.hasPrefix("memory:"), let rowid = Int64(link.payload.dropFirst("memory:".count)) else { return }
            await SnapshotReadiness.track {
                let namer = await CommsCache.shared.deviceNamer(token)
                if let row = try? await SiriMemories.page(rowid: rowid, request: PageRequest(offset: 0, limit: 1), namer: namer).first {
                    kind = ""
                    selected = row
                }
            }
        }
        .onChange(of: kind) { selected = nil }
    }

    private var columns: [PagedColumn<SiriMemoryRow>] {
        [
            PagedColumn<SiriMemoryRow>.date("Time", id: "startDate") { $0.date },
            PagedColumn("Kind", id: "type", width: 190, min: 160, sensitivity: .personal) { $0.kind }
                .cell { row in
                    HStack(spacing: 6) {
                        Image(systemName: SiriMemories.kindSymbol(row.type)).foregroundStyle(.secondary).frame(width: 16)
                        Text(row.kind).font(.callout.weight(.medium)).lineLimit(1)
                    }
                    .help(row.type)
                },
            PagedColumn("App", id: "bundleId", width: 130, min: 84, sensitivity: .personal) { AppNames.name($0.bundle) }
                .cell { AppCell(bundle: $0.bundle) },
            PagedColumn("What", id: "summary", width: 380, min: 120, sortable: false, sensitivity: .personal) { $0.summary }
                .cell { row in
                    Text(row.summary.isEmpty ? "No details stored" : row.summary)
                        .font(.callout).lineLimit(1)
                        .foregroundStyle(row.summary.isEmpty ? .tertiary : .primary)
                },
            PagedColumn("Recorded On", id: "device", width: 130, sortable: false, sensitivity: .personal, secondary: true) { $0.device },
            PagedColumn("Donated By", id: "isDonatedBySiri", width: 90, secondary: true) { donor($0) },
            PagedColumn("Status", id: "status", width: 110, sortable: false, secondary: true, hiddenByDefault: true) { RemembersSchema.statusLabel($0.status) },
            PagedColumn("Intent Type", id: "rawType", width: 220, sortable: false, monospaced: true, secondary: true, hiddenByDefault: true) { $0.type },
            PagedColumn("Stream", id: "streams", width: 240, sortable: false, monospaced: true, secondary: true, hiddenByDefault: true) { $0.streams },
        ]
    }

    private func donor(_ row: SiriMemoryRow) -> String {
        switch row.donatedBySiri {
        case true?: return "Siri"
        case false?: return "App"
        case nil: return "—"
        }
    }

    @ViewBuilder private func inspector(_ row: SiriMemoryRow) -> some View {
        InspectorPage(title: row.kind, subtitle: "\(AppNames.name(row.bundle)) · \(DossierDate.medium(row.date))", sensitivity: .personal, onClose: { selected = nil }) {
            if !row.summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        InspectorGroupTitle("What Siri remembers")
                        Spacer()
                        SensitivityBadge(.personal, compact: true)
                    }
                    Text(row.summary).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).sensitive(.personal)
                }
                .card(padding: 10)
            }
            KeyValueGrid([
                KeyValueItem("Time", DossierDate.medium(row.date)),
                KeyValueItem("Kind", row.kind, sensitivity: .personal),
                KeyValueItem("Intent type", row.type, sensitivity: .personal, monospaced: true),
                KeyValueItem("Domain", row.domain.isEmpty ? nil : row.domain),
                KeyValueItem("App", AppNames.name(row.bundle), sensitivity: .personal),
                KeyValueItem("Bundle id", row.bundle, monospaced: true),
                KeyValueItem("Duration", row.seconds > 0 ? Format.duration(row.seconds) : nil),
                KeyValueItem("Handling status", RemembersSchema.statusLabel(row.status)),
                KeyValueItem("Recorded on", row.device, sensitivity: .personal),
                KeyValueItem("Donated by", row.donatedBySiri == true ? "Siri itself" : row.donatedBySiri == false ? "the app" : nil),
                KeyValueItem("Source stream", row.streams.isEmpty ? nil : row.streams, monospaced: true),
                KeyValueItem("Interaction ID", row.interactionID.isEmpty ? nil : row.interactionID, monospaced: true),
            ])
            AsyncContent(reloadKey: row.id) {
                try await SiriMemories.detail(row.id)
            } content: { detail in
                VStack(alignment: .leading, spacing: 10) {
                    InspectorGroupTitle("Linked entities")
                    if detail.entities.isEmpty {
                        Text("No entities are linked to this interaction.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(detail.entities) { entity in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(entity.parameter) · \(entity.type)").font(.caption).foregroundStyle(.secondary)
                            Text(entity.value).font(.callout.monospaced()).lineLimit(2).textSelection(.enabled).sensitive(.personal)
                            if let nodes = Self.nodes(entity.fields, key: "fields") {
                                DataTreeView(nodes, sensitivity: .personal)
                            }
                        }
                    }
                    InspectorGroupTitle("Raw fields")
                    if let nodes = Self.nodes(detail.fields, key: "fields") {
                        DataTreeView(nodes, sensitivity: .personal)
                    } else {
                        Text("This interaction carries no additional fields.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80)
        }
    }

    /// JSON text → tree nodes; nil for empty objects and non-JSON text.
    private static func nodes(_ json: String, key: String) -> [DataNode]? {
        guard json.count > 2, let value = PlistDecoder.decodeJSON(Data(json.utf8)) else { return nil }
        return [DataNode.from(value, key: key)]
    }
}
