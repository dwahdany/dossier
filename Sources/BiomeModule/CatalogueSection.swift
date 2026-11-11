import SwiftUI
import DossierCore

/// One table row of the catalogue: a stream on one device.
struct CatalogRow: Identifiable, Sendable {
    let id: String
    let entryID: String
    let name: String
    let family: String
    let origin: BiomeStreamOrigin
    let device: String
    let isLocal: Bool
    let live: Int
    let deleted: Int
    let bytes: Int64
    let first: Date?
    let last: Date?
    /// Records per day for the last `CatalogRow.sparkDays` days (oldest first).
    let spark: [Int]
    let summary: String
    let decoded: Bool
    /// Duplicate of other streams' records (linkd's combined transcript); not counted in totals.
    let isMirror: Bool

    static let sparkDays = 35

    static func rows(_ snapshot: CatalogSnapshot) -> [CatalogRow] {
        let today = DayIndex.today
        var out: [CatalogRow] = []
        for entry in snapshot.entries {
            let devices = entry.devices.filter { $0.live > 0 || $0.deleted > 0 }
            func spark(_ days: [Int: Int]) -> [Int] { (0..<sparkDays).map { days[today - sparkDays + 1 + $0] ?? 0 } }
            if devices.isEmpty {
                out.append(CatalogRow(
                    id: entry.id, entryID: entry.id, name: entry.displayName, family: entry.info.family, origin: entry.origin,
                    device: "—", isLocal: true, live: 0, deleted: 0, bytes: entry.bytes, first: nil, last: nil, spark: [],
                    summary: entry.info.summary, decoded: entry.info.schema != nil, isMirror: entry.isMirror
                ))
                continue
            }
            for stats in devices {
                out.append(CatalogRow(
                    id: entry.id + "|" + (stats.device.identifier ?? "local"), entryID: entry.id, name: entry.displayName,
                    family: entry.info.family, origin: entry.origin, device: snapshot.namer.label(stats.device), isLocal: stats.device.isLocal,
                    live: stats.live, deleted: stats.deleted, bytes: stats.bytes, first: stats.first, last: stats.last,
                    spark: spark(stats.days), summary: entry.info.summary, decoded: entry.info.schema != nil, isMirror: entry.isMirror
                ))
            }
        }
        return out
    }
}

/// (1) Stream catalogue: every Biome stream, grouped by family, per device.
struct CatalogueSection: View {
    private enum Presence: String, CaseIterable, Identifiable {
        case withRecords = "With Records", empty = "Empty", all = "All"
        var id: String { rawValue }
    }

    @State private var family: String?
    @State private var presence: Presence = .withRecords
    @State private var selectedEntryID: String?
    /// Width of the table pane (decides the form of the header's filter control).
    @State private var paneWidth: CGFloat = 0
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.navigate) private var navigate
    @Environment(\.deepLink) private var deepLink

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (family, presence, selectedEntryID, paneWidth)
        let token = refreshToken
        AsyncContent(reloadKey: token, emptyTitle: "No Biome Streams", emptySymbol: "waveform.path.ecg") {
            try await CatalogueSection.load(token: token)
        } content: { loaded in
            content(loaded)
        }
    }

    struct Loaded: Sendable {
        let snapshot: CatalogSnapshot
        let rows: [CatalogRow]
        let families: [FamilyCount]
    }

    struct FamilyCount: Sendable {
        let name: String
        let streams: Int
        let records: Int
    }

    static func load(token: Int) async throws -> Loaded {
        await BiomeCatalog.shared.sync(token: token)
        let snapshot = await BiomeCatalog.shared.snapshot()
        if snapshot.entries.isEmpty {
            switch Paths.probe(Paths.biomeRestrictedStreams) {
            case .inaccessible(let reason): throw DossierError.inaccessible(reason)
            case .missing: throw DossierError.missing("No Biome stream directory exists on this Mac.")
            case .available: throw DossierError.missing("The Biome stream directory contains no streams.")
            }
        }
        var families: [String: (Int, Int)] = [:]
        for e in snapshot.entries {
            var f = families[e.info.family] ?? (0, 0)
            f.0 += 1; f.1 += e.isMirror ? 0 : e.live
            families[e.info.family] = f
        }
        var list: [FamilyCount] = []
        for (name, value) in families { list.append(FamilyCount(name: name, streams: value.0, records: value.1)) }
        list.sort { (a: FamilyCount, b: FamilyCount) -> Bool in
            if a.records == b.records { return a.name < b.name }
            return a.records > b.records
        }
        return Loaded(snapshot: snapshot, rows: CatalogRow.rows(snapshot), families: list)
    }

    private func visibleRows(_ loaded: Loaded) -> [CatalogRow] {
        let presence = self.presence
        let family = self.family
        return loaded.rows.filter { (row: CatalogRow) -> Bool in
            if let family, row.family != family { return false }
            switch presence {
            case .all: return true
            case .withRecords: return row.live > 0
            case .empty: return row.live == 0
            }
        }
    }

    private func content(_ loaded: Loaded) -> some View {
        let snapshot = loaded.snapshot
        let visible = visibleRows(loaded)
        let selected: CatalogEntry? = selectedEntryID.flatMap { id in snapshot.entries.first { $0.id == id } }
        let showInspector = Binding<Bool>(get: { selected != nil }, set: { if !$0 { selectedEntryID = nil } })
        return MasterDetailSplit(masterWidth: 230, compactMasterWidth: 200, inspectorOpen: selected != nil) {
            familyList(loaded)
        } detail: {
            tablePane(loaded, visible: visible, selected: selected, showInspector: showInspector)
        }
        .onChange(of: deepLink?.nonce, initial: true) { _, _ in
            guard let link = deepLink, link.sectionID == "biome.catalogue", !link.payload.isEmpty else { return }
            if let match = snapshot.entry(named: link.payload) {
                self.family = match.info.family
                self.presence = .all
                selectedEntryID = match.id
            } else if loaded.families.contains(where: { $0.name == link.payload }) {
                self.family = link.payload
            }
        }
    }

    private func tablePane(_ loaded: Loaded, visible: [CatalogRow], selected: CatalogEntry?, showInspector: Binding<Bool>) -> some View {
        let snapshot = loaded.snapshot
        let reloadKey: String = "\(family ?? "*")|\(presence.rawValue)|\(loaded.rows.count)|\(snapshot.totalLive)"
        let note: String = "\(snapshot.entries.count) streams indexed in \(String(format: "%.2f", snapshot.seconds)) s · read-only"
        return VStack(spacing: 0) {
            HeaderStrip {
                VStack(alignment: .leading, spacing: 2) {
                    Text(family ?? "All Streams").font(.headline).lineLimit(1)
                    FittingText(headlines(visible))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The segmented control cannot shrink; in a narrow pane (minimum window with the
                // inspector open) a pop-up button takes its place so the title stays readable.
                Group {
                    if paneWidth > 0 && paneWidth < 440 {
                        Picker("Show", selection: $presence) {
                            ForEach(Presence.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker("Show", selection: $presence) {
                            ForEach(Presence.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Most streams exist on every Mac but never receive a record; “Empty” lists those.")
            }
            PagedTable(
                columns: columns,
                pageSize: 400,
                searchPrompt: "Filter streams, devices, descriptions",
                reloadKey: reloadKey,
                exportName: "biome-streams",
                emptyTitle: presence == .empty ? "No Empty Streams" : "No Streams",
                fetch: { request in CatalogueSection.page(visible, request) },
                count: { request in CatalogueSection.filtered(visible, request.search).count },
                onSelect: { rows in selectedEntryID = rows.count == 1 ? rows.first?.entryID : nil },
                onActivate: { row in open(row.entryID, snapshot: snapshot) }
            )
            // Keeps the table usable beside the inspector: in a narrow window the inspector
            // gives up width (down to its minimum) before the table drops below this.
            .frame(minWidth: 400)
            .detailInspector(isPresented: showInspector) {
                if let selected {
                    StreamInfoInspector(entry: selected, namer: snapshot.namer, canOpen: navigate != nil,
                                        onOpen: { open(selected.id, snapshot: snapshot) }, onClose: { selectedEntryID = nil })
                        .id(selected.id)
                }
            }
            StoreFooter(Paths.biomeStreams, note: note)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
    }

    private func open(_ entryID: String, snapshot: CatalogSnapshot) {
        navigate?(DeepLink(sectionID: "biome.stream", payload: entryID))
    }

    /// The header caption, from complete to shortest (the first that fits is shown).
    private func headlines(_ rows: [CatalogRow]) -> [String] {
        let streams = Set(rows.map(\.entryID)).count
        let live = rows.reduce(0) { $0 + ($1.isMirror ? 0 : $1.live) }
        let deleted = rows.reduce(0) { $0 + $1.deleted }
        let remote = rows.filter { !$0.isLocal }.reduce(0) { $0 + $1.live }
        var parts = ["\(Format.count(streams)) stream\(streams == 1 ? "" : "s")", "\(Format.count(live)) live records"]
        if deleted > 0 { parts.append("\(Format.count(deleted)) deleted") }
        if remote > 0 { parts.append("\(Format.count(remote)) synced from other devices") }
        return [parts.joined(separator: " · "), parts.prefix(2).joined(separator: " · "), parts[0]]
    }

    private func familyList(_ loaded: Loaded) -> some View {
        let total = loaded.snapshot.entries.count
        return VStack(spacing: 0) {
            List(selection: Binding(get: { family ?? "*" }, set: { family = $0 == "*" ? nil : $0 })) {
                Section("Families") {
                    familyRow("All Streams", tint: .secondary, streams: total, records: loaded.snapshot.totalLive).tag("*")
                    ForEach(loaded.families, id: \.name) { f in
                        familyRow(f.name, tint: FamilyTint.color(f.name), streams: f.streams, records: f.records).tag(f.name)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            PaneFooter("\(loaded.families.count) families · \(Format.bytes(loaded.snapshot.totalBytes)) on disk")
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func familyRow(_ name: String, tint: Color, streams: Int, records: Int) -> some View {
        HStack(spacing: 7) {
            Circle().fill(tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout).lineLimit(1)
                Text("\(streams) stream\(streams == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(records > 0 ? Format.compact(records) : "—")
                .font(.caption).monospacedDigit()
                .foregroundStyle(records > 0 ? .secondary : .tertiary)
        }
    }

    private var columns: [PagedColumn<CatalogRow>] {
        [
            PagedColumn<CatalogRow>("Stream", id: "name", width: 240, min: 160) { $0.name }
                .cell { row in
                    HStack(spacing: 6) {
                        Circle().fill(FamilyTint.color(row.family)).frame(width: 7, height: 7)
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(row.live > 0 ? .primary : .secondary)
                        if row.isMirror {
                            Text("mirror").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .help("Byte-identical copies of the per-app transcript records; counted once in totals.")
                        }
                    }
                },
            PagedColumn("Family", id: "family", width: 130, secondary: true, hiddenByDefault: true) { $0.family },
            PagedColumn("Device", id: "device", width: 104, min: 80, sensitivity: .personal) { $0.device }
                .cell { row in
                    HStack(spacing: 4) {
                        if row.live > 0 || row.deleted > 0 {
                            Image(systemName: row.isLocal ? "desktopcomputer" : "arrow.triangle.2.circlepath")
                                .imageScale(.small).foregroundStyle(row.isLocal ? Color.secondary : Color.teal)
                        }
                        Text(row.device).lineLimit(1).foregroundStyle(row.live > 0 ? .primary : .tertiary)
                    }
                },
            PagedColumn("Records", id: "live", width: 70, min: 60, alignment: .trailing) { countOrDash($0.live) },
            PagedColumn("Deleted", id: "deleted", width: 60, min: 56, alignment: .trailing, secondary: true) { countOrDash($0.deleted) },
            PagedColumn("Last \(CatalogRow.sparkDays) Days", id: "spark", width: 112, min: 90) { String($0.spark.reduce(0, +)) }
                .cell { row in
                    if row.spark.contains(where: { $0 > 0 }) {
                        Sparkline(values: row.spark, tint: FamilyTint.color(row.family))
                            .help("\(Format.count(row.spark.reduce(0, +))) records in the last \(CatalogRow.sparkDays) days, per day")
                    } else {
                        Text(row.live > 0 ? "older" : "").font(.caption).foregroundStyle(.tertiary)
                    }
                },
            PagedColumn("First", id: "first", width: 86, min: 84, secondary: true) { $0.first.map { DossierDate.sortable($0).prefix(10).description } ?? "" },
            PagedColumn("Last", id: "last", width: 122, min: 96, secondary: true) { $0.last.map { DossierDate.sortable($0).prefix(16).description } ?? "" },
            PagedColumn("Size", id: "bytes", width: 64, min: 60, alignment: .trailing, secondary: true) { $0.bytes > 0 ? Format.bytes($0.bytes) : "—" },
            PagedColumn("Decoder", id: "decoded", width: 70, secondary: true, hiddenByDefault: true) { $0.decoded ? "typed" : "generic" },
            PagedColumn("Origin", id: "origin", width: 110, secondary: true, hiddenByDefault: true) { $0.origin.rawValue },
            PagedColumn("What It Records", id: "summary", width: 520, min: 200, sortable: false, secondary: true) { $0.summary },
        ]
    }

    private static func filtered(_ rows: [CatalogRow], _ search: String) -> [CatalogRow] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.device.localizedCaseInsensitiveContains(needle) ||
            $0.summary.localizedCaseInsensitiveContains(needle) || $0.family.localizedCaseInsensitiveContains(needle)
        }
    }

    private static func page(_ rows: [CatalogRow], _ request: PageRequest) -> [CatalogRow] {
        var list = filtered(rows, request.search)
        let sort = request.sort ?? PageSort(columnID: "live", ascending: false)
        func ordered<T: Comparable>(_ key: (CatalogRow) -> T) {
            list.sort { a, b in
                let x = key(a), y = key(b)
                if x == y { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return sort.ascending ? x < y : x > y
            }
        }
        switch sort.columnID {
        case "name": list.sort { ($0.name.localizedStandardCompare($1.name) == .orderedAscending) == sort.ascending }
        case "family": ordered { $0.family }
        case "device": ordered { $0.device }
        case "deleted": ordered { $0.deleted }
        case "spark": ordered { $0.spark.reduce(0, +) }
        case "first": ordered { $0.first ?? (sort.ascending ? .distantFuture : .distantPast) }
        case "last": ordered { $0.last ?? (sort.ascending ? .distantFuture : .distantPast) }
        case "bytes": ordered { $0.bytes }
        case "decoded": ordered { $0.decoded ? 1 : 0 }
        case "origin": ordered { $0.origin.rawValue }
        default: ordered { $0.live }
        }
        guard request.offset < list.count else { return [] }
        return Array(list[request.offset..<min(list.count, request.offset + request.limit)])
    }
}

/// Inspector of the catalogue: documentation, per-device statistics and the field table.
struct StreamInfoInspector: View {
    let entry: CatalogEntry
    let namer: DeviceNamer
    let canOpen: Bool
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        InspectorPage(title: entry.displayName, subtitle: "\(entry.info.family) · \(entry.origin.rawValue)", onClose: onClose) {
            Text(entry.info.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                SensitivityBadge(entry.info.sensitivity)
                TagLabel(entry.info.schema != nil ? "typed decoder" : "generic decoder", tint: entry.info.schema != nil ? .green : .secondary)
                if entry.info.isActivity { TagLabel("owner activity", tint: .blue) }
                if entry.isMirror { TagLabel("mirror", tint: .orange) }
            }
            if canOpen && entry.live > 0 {
                Button("Show Records", systemImage: "list.bullet.rectangle", action: onOpen)
                    .controlSize(.small)
            }

            InspectorGroupTitle("Totals")
            KeyValueGrid([
                KeyValueItem("Live records", Format.count(entry.live)),
                KeyValueItem("Deleted", entry.deleted > 0 ? "\(Format.count(entry.deleted)) (zero-filled by the system)" : "none"),
                KeyValueItem("Time range", entry.range.map { DossierDate.range($0) } ?? "—"),
                KeyValueItem("On disk", "\(Format.bytes(entry.bytes)) in \(entry.devices.reduce(0) { $0 + $1.segments }) segment file(s)"),
            ])

            if entry.live > 0 {
                InspectorGroupTitle("Records per day")
                DayChart(points: entry.devices.count > 1
                         ? entry.devices.flatMap { DayChart.points($0.days, series: namer.label($0.device)) }
                         : DayChart.points(entry.days), height: 140)
                    .sensitive(.personal)
            }

            if !entry.devices.isEmpty {
                InspectorGroupTitle("Devices")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    GridRow {
                        Text("Device"); Text("Live").gridColumnAlignment(.trailing); Text("Deleted").gridColumnAlignment(.trailing); Text("Last record")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(entry.devices, id: \.device) { d in
                        GridRow {
                            Text(namer.label(d.device)).sensitive(.personal)
                            Text(Format.count(d.live)).monospacedDigit()
                            Text(countOrDash(d.deleted)).monospacedDigit().foregroundStyle(.secondary)
                            Text(d.last.map { DossierDate.short($0) } ?? "—").foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }

            if let schema = entry.info.schema {
                InspectorGroupTitle("Documented fields")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(Array(schema.fields.enumerated()), id: \.offset) { _, field in
                        GridRow {
                            Text("#" + field.pathLabel).font(.caption.monospaced()).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(field.name).font(.callout)
                            if field.sensitivity > .low { SensitivityBadge(field.sensitivity, compact: true) } else { Color.clear.frame(width: 1, height: 1) }
                        }
                    }
                }
                Text("Field meanings were established from the shape of real records; undocumented fields appear as #n in the record tree.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            InspectorGroupTitle("Location")
            Text(Format.tildePath(entry.stream.url))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .sensitive(.personal)
        }
    }
}
