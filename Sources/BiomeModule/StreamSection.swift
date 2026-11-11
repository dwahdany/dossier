import SwiftUI
import DossierCore

/// (2) Stream detail: typed record table for one stream, driven by the registry.
struct StreamSection: View {
    @State private var selectedID: String?
    @State private var filter = ""
    @State private var showEmpty = false
    @State private var recordFilter = ""
    /// Reported by the records pane; lets the split tuck the stream list away when narrow.
    @State private var inspectorOpen = false
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selectedID, filter, showEmpty, recordFilter, inspectorOpen)
        let token = refreshToken
        AsyncContent(reloadKey: token, emptyTitle: "No Biome Streams", emptySymbol: "waveform.path.ecg") {
            try await CatalogueSection.load(token: token).snapshot
        } content: { snapshot in
            let selected = snapshot.entries.first { $0.id == selectedID } ?? defaultEntry(snapshot)
            MasterDetailSplit(masterWidth: 280, compactMasterWidth: 230, inspectorOpen: inspectorOpen) {
                streamList(snapshot, selected: selected)
            } detail: {
                if let selected {
                    StreamRecordsView(entry: selected, namer: snapshot.namer, recordFilter: $recordFilter, inspectorOpen: $inspectorOpen)
                        .id(selected.id)
                } else {
                    StatePlaceholder(title: "Select a Stream", symbol: "waveform.path.ecg")
                }
            }
            .onChange(of: deepLink?.nonce, initial: true) { _, _ in
                guard let link = deepLink, link.sectionID == "biome.stream", !link.payload.isEmpty else { return }
                let parts = link.payload.components(separatedBy: "\t")
                if let match = snapshot.entry(named: parts[0]) {
                    selectedID = match.id
                    if match.live == 0 { showEmpty = true }
                    recordFilter = parts.count > 1 ? parts[1] : ""
                }
            }
        }
    }

    private func defaultEntry(_ snapshot: CatalogSnapshot) -> CatalogEntry? {
        snapshot.entry(named: "App.InFocus").flatMap { $0.live > 0 ? $0 : nil } ?? snapshot.entries.max { $0.live < $1.live }
    }

    private func streamList(_ snapshot: CatalogSnapshot, selected: CatalogEntry?) -> some View {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let visible = snapshot.entries.filter {
            (showEmpty || $0.live > 0 || $0.id == selected?.id) &&
            (needle.isEmpty || $0.displayName.localizedCaseInsensitiveContains(needle) || $0.info.family.localizedCaseInsensitiveContains(needle))
        }
        let groups = Dictionary(grouping: visible, by: { $0.info.family })
        let order = groups.keys.sorted { a, b in
            let x = groups[a]!.reduce(0) { $0 + $1.live }, y = groups[b]!.reduce(0) { $0 + $1.live }
            return x == y ? a < b : x > y
        }
        return VStack(spacing: 0) {
            PaneFilter(prompt: "Filter streams", text: $filter) {
                Toggle("Empty", isOn: $showEmpty)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .help("Also list streams without records")
            }
            Divider()
            List(selection: Binding(get: { selected?.id }, set: { if let id = $0 { selectedID = id; recordFilter = "" } })) {
                ForEach(order, id: \.self) { family in
                    Section(family) {
                        ForEach(groups[family] ?? []) { entry in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(shortName(entry)).font(.callout).lineLimit(1).truncationMode(.middle)
                                    HStack(spacing: 4) {
                                        if entry.info.schema != nil { Text("typed") } else { Text("generic") }
                                        if entry.devices.contains(where: { !$0.device.isLocal && $0.live > 0 }) {
                                            Text("· \(entry.devices.filter { !$0.device.isLocal && $0.live > 0 }.count) synced")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Text(entry.live > 0 ? Format.compact(entry.live) : "—")
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(entry.live > 0 ? .secondary : .tertiary)
                            }
                            .tag(entry.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            PaneFooter("\(visible.count) of \(snapshot.entries.count) streams · \(Format.count(snapshot.totalLive)) records")
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func shortName(_ entry: CatalogEntry) -> String {
        entry.origin == .linkd ? entry.stream.name : entry.displayName
    }
}

private struct StreamRecordsView: View {
    let entry: CatalogEntry
    let namer: DeviceNamer
    @Binding var recordFilter: String
    @Binding var inspectorOpen: Bool

    /// "all" | "local" | remote device identifier
    @State private var deviceKey = "all"
    @State private var selected: StreamRow?
    @State private var source: StreamRecordSource

    init(entry: CatalogEntry, namer: DeviceNamer, recordFilter: Binding<String>, inspectorOpen: Binding<Bool>) {
        self.entry = entry
        self.namer = namer
        _recordFilter = recordFilter
        _inspectorOpen = inspectorOpen
        _source = State(initialValue: StreamRecordSource(entry: entry))
    }

    private var device: BiomeDevice? {
        switch deviceKey {
        case "all": return nil
        case "local": return .local
        default: return .remote(deviceKey)
        }
    }

    private var columns: [PagedColumn<StreamRow>] {
        let namer = self.namer
        var cols: [PagedColumn<StreamRow>] = [
            PagedColumn("Time", id: "time", width: 150, min: 140, max: 190, sortable: true) { DossierDate.sortable($0.timestamp) },
        ]
        if entry.devices.filter({ $0.live > 0 }).count > 1 {
            cols.append(PagedColumn("Device", id: "device", width: 110, min: 80, sortable: false, sensitivity: .personal, secondary: true) { namer.label($0.device) })
        }
        if let schema = entry.info.schema {
            for (i, field) in schema.columns.enumerated() {
                let trailing: Bool
                switch field.kind {
                case .integer, .number, .seconds, .percent: trailing = true
                default: trailing = false
                }
                if case .app = field.kind {
                    // The cell holds the bundle identifier; show the app (icon + name) with
                    // the identifier as secondary text. Copy / export get "Name (identifier)".
                    cols.append(PagedColumn<StreamRow>(field.name, id: "f\(i)", width: CGFloat(max(field.width, 260)), min: 80, sortable: false, sensitivity: field.sensitivity) { row in
                        let id = row.cells.indices.contains(i) ? row.cells[i] : ""
                        let name = AppCell.name(id)
                        return name == id ? id : "\(name) (\(id))"
                    }.cell { row in AppCell(identifier: row.cells.indices.contains(i) ? row.cells[i] : "") })
                    continue
                }
                cols.append(PagedColumn(field.name, id: "f\(i)", width: CGFloat(field.width), min: 50, alignment: trailing ? .trailing : .leading,
                                        sortable: false, sensitivity: field.sensitivity) { $0.cells.indices.contains(i) ? $0.cells[i] : "" })
            }
        } else {
            cols.append(PagedColumn("Content (strings found in the record)", id: "content", width: 640, sortable: false, sensitivity: entry.info.sensitivity) { $0.cells.first ?? "" })
        }
        cols.append(PagedColumn("Size", id: "size", width: 70, min: 60, alignment: .trailing, sortable: false, secondary: true, hiddenByDefault: entry.info.schema != nil) { Format.bytes($0.length) })
        cols.append(PagedColumn("Segment", id: "segment", width: 170, sortable: false, monospaced: true, secondary: true, hiddenByDefault: true) { "\($0.ref.segmentURL.lastPathComponent) #\($0.ref.entryIndex)" })
        return cols
    }

    var body: some View {
        let source = self.source
        let device = self.device
        let liveDevices = entry.devices.filter { $0.live > 0 }
        VStack(spacing: 0) {
            HeaderStrip {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.displayName).font(.headline).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .layoutPriority(1)
                        TagLabel(entry.info.schema != nil ? "typed" : "generic", tint: entry.info.schema != nil ? .green : .secondary)
                            .fixedSize()
                        SensitivityBadge(entry.info.sensitivity, compact: true)
                            .fixedSize()
                        // Totals: complete, then records only, then nothing — never a squeezed ellipsis.
                        FittingText([
                            [
                                "\(Format.count(entry.live)) records",
                                entry.deleted > 0 ? "\(Format.count(entry.deleted)) deleted" : nil,
                                entry.range.map { DossierDate.range($0) },
                            ].compactMap { $0 }.joined(separator: " · "),
                            "\(Format.count(entry.live)) records",
                        ], orNothing: true)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Text(entry.info.summary)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(entry.info.summary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if liveDevices.count > 1 {
                    Picker("Device", selection: $deviceKey) {
                        Text("All Devices").tag("all")
                        ForEach(liveDevices, id: \.device) { d in
                            Text("\(namer.label(d.device)) (\(Format.compact(d.live)))").tag(d.device.identifier ?? "local")
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .sensitive(.personal)
                }
            }
            PagedTable(
                columns: columns,
                pageSize: 200,
                searchPrompt: "Search record contents",
                reloadKey: deviceKey,
                exportName: entry.stream.name,
                emptyTitle: entry.live == 0 ? "No Records in This Stream" : "No Matching Records",
                filter: $recordFilter,
                fetch: { request in
                    await source.page(device: device, search: request.search, ascending: request.sort?.ascending ?? false, offset: request.offset, limit: request.limit)
                },
                count: { request in await source.count(device: device, search: request.search) },
                onSelect: { selected = $0.count == 1 ? $0.first : nil }
            )
            // The inspector gives up width (down to its minimum) before the table drops below this.
            .frame(minWidth: 400)
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected {
                    RecordInspectorView(ref: selected.ref, title: DossierDate.medium(selected.timestamp),
                                        subtitle: "\(entry.displayName) · \(namer.label(selected.device))",
                                        info: entry.info, onClose: { self.selected = nil })
                        .id(selected.id)
                }
            }
            StoreFooter(entry.stream.url, note: "SEGB · memory-mapped, read-only")
        }
        .onChange(of: selected != nil, initial: true) { _, open in inspectorOpen = open }
    }
}
