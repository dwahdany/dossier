import SwiftUI
import DossierCore

/// (3) Unified timeline: all selected streams and devices merged by timestamp.
struct TimelineSection: View {
    @Environment(\.refreshToken) private var refreshToken

    var body: some View {
        let token = refreshToken
        AsyncContent(reloadKey: token, emptyTitle: "No Biome Streams", emptySymbol: "waveform.path.ecg") {
            try await CatalogueSection.load(token: token).snapshot
        } content: { snapshot in
            TimelineBody(snapshot: snapshot)
        }
    }
}

private struct TimelineBody: View {
    let snapshot: CatalogSnapshot

    @State private var activityOnly = true
    @State private var excludedFamilies: Set<String> = []
    @State private var excludedDevices: Set<String> = []
    @State private var includeKnowledge = true
    @State private var before: Date?
    @State private var pickerDate = Date()
    @State private var selected: TimelineRow?
    @State private var source = TimelineSource()
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink

    private var families: [String] {
        Array(Set(snapshot.nonEmpty.map { $0.info.family })).sorted()
    }

    private var deviceKeys: [(key: String, label: String)] {
        var seen: [String] = []
        for e in snapshot.nonEmpty { for d in e.devices where d.live > 0 {
            let key = d.device.identifier ?? "local"
            if !seen.contains(key) { seen.append(key) }
        } }
        return seen.sorted { a, b in a == "local" ? true : (b == "local" ? false : a < b) }
            .map { key in (key, snapshot.namer.label(key == "local" ? .local : .remote(key))) }
    }

    private var selectedEntries: [CatalogEntry] {
        // "Owner activity" takes each App Intents execution from one source (see `activityEntries`).
        (activityOnly ? snapshot.activityEntries : snapshot.nonEmpty).filter { !excludedFamilies.contains($0.info.family) }
    }

    private var selection: TimelineSelection {
        let keys = deviceKeys.map(\.key)
        let devices = excludedDevices.isEmpty ? nil : Set(keys).subtracting(excludedDevices)
        return TimelineSelection(streams: Set(selectedEntries.map(\.id)), devices: devices, before: before,
                                 includeKnowledge: includeKnowledge, search: "", refresh: refreshToken)
    }

    private var columns: [PagedColumn<TimelineRow>] {
        [
            PagedColumn<TimelineRow>("Time", id: "time", width: 150, min: 140, max: 190, sortable: false) { DossierDate.sortable($0.date) },
            PagedColumn("Device", id: "device", width: 110, min: 80, sortable: false, sensitivity: .personal, secondary: true) { $0.device },
            PagedColumn("Stream", id: "stream", width: 220, min: 140, sortable: false) { $0.source }
                .cell { row in
                    HStack(spacing: 6) {
                        Circle().fill(FamilyTint.color(row.family)).frame(width: 7, height: 7)
                        Text(row.source).lineLimit(1).truncationMode(.middle)
                    }
                },
            PagedColumn("Event", id: "summary", width: 640, min: 200, sortable: false, sensitivity: .sensitive) { $0.summary },
        ]
    }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (activityOnly, excludedFamilies, excludedDevices, includeKnowledge, before, pickerDate, selected, source)
        let selection = self.selection
        let snapshot = self.snapshot
        let source = self.source
        let streamCount = selection.streams.count
        VStack(spacing: 0) {
            HeaderStrip {
                // None of these controls can shrink, so the strip steps down instead: full
                // labels, short labels, icons only — the first set that fits the width.
                ViewThatFits(in: .horizontal) {
                    headerControls(streamCount: streamCount, level: 0)
                    headerControls(streamCount: streamCount, level: 1)
                    headerControls(streamCount: streamCount, level: 2)
                }
            }
            if streamCount == 0 && !includeKnowledge {
                StatePlaceholder(title: "No Streams Selected", symbol: "line.3.horizontal.decrease.circle",
                                 message: "Choose at least one stream family in the filter menu.")
            } else {
                PagedTable(
                    columns: columns,
                    pageSize: 200,
                    searchPrompt: "Search event contents",
                    reloadKey: selection,
                    exportName: "timeline",
                    emptyTitle: "No Events",
                    fetch: { request in
                        var s = selection
                        s.search = request.search
                        return try await source.page(s, catalog: snapshot, offset: request.offset, limit: request.limit)
                    },
                    onSelect: { selected = $0.count == 1 ? $0.first : nil }
                )
                // The inspector gives up width (down to its minimum) before the table drops below this.
                .frame(minWidth: 400)
                .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                    if let selected { inspector(selected).id(selected.id) }
                }
            }
            StoreFooter(Paths.biomeStreams, note: "k-way merge over \(streamCount) stream\(streamCount == 1 ? "" : "s"), newest first · segments opened lazily")
        }
        .onChange(of: deepLink?.nonce, initial: true) { _, _ in
            guard let link = deepLink, link.sectionID == "biome.timeline", link.payload.hasPrefix("t:"),
                  let seconds = Double(link.payload.dropFirst(2)) else { return }
            pickerDate = Date(timeIntervalSinceReferenceDate: seconds)
            before = pickerDate
        }
    }

    /// The header strip's controls. `level` 0: full labels; 1: short labels; 2: icons only.
    private func headerControls(streamCount: Int, level: Int) -> some View {
        let streamsTitle = "\(streamCount) stream\(streamCount == 1 ? "" : "s")"
        let devicesTitle = excludedDevices.isEmpty ? "All devices" : "\(deviceKeys.count - excludedDevices.count) of \(deviceKeys.count) devices"
        return HStack(alignment: .center, spacing: level == 0 ? 12 : 8) {
            if level < 2 { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary) }
            if before != nil {
                if level == 0 { Text("Events up to").font(.callout).lineLimit(1).fixedSize() }
                DatePicker("Events up to", selection: Binding(get: { pickerDate }, set: { pickerDate = $0; before = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .fixedSize()
                    .help("Show what was recorded at and before this moment")
                Button("Now") { before = nil }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Show the most recent events again")
            } else {
                Text("Most recent events").font(.callout).lineLimit(1).fixedSize()
                Button("Jump to Time…") { pickerDate = Date(); before = pickerDate }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Show what was recorded at and before a chosen moment")
            }
            Spacer(minLength: 4)
            Menu {
                Toggle("Owner Activity Only", isOn: $activityOnly)
                Toggle("Include knowledgeC", isOn: $includeKnowledge)
                Divider()
                Button("All Families") { excludedFamilies = [] }
                Button("No Families") { excludedFamilies = Set(families) }
                Divider()
                ForEach(families, id: \.self) { family in
                    Toggle(family, isOn: Binding(
                        get: { !excludedFamilies.contains(family) },
                        set: { if $0 { excludedFamilies.remove(family) } else { excludedFamilies.insert(family) } }
                    ))
                }
            } label: {
                Label(level == 0 ? streamsTitle + (includeKnowledge ? " + knowledgeC" : "") : (level == 1 ? streamsTitle : "\(streamCount)"),
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            .help("\(streamsTitle)\(includeKnowledge ? " + knowledgeC" : ""). “Owner activity” leaves out telemetry streams (model instrumentation, analytics ledgers, suggestion caches).")
            if deviceKeys.count > 1 {
                Menu {
                    Button("All Devices") { excludedDevices = [] }
                    Divider()
                    ForEach(deviceKeys, id: \.key) { device in
                        Toggle(device.label, isOn: Binding(
                            get: { !excludedDevices.contains(device.key) },
                            set: { if $0 { excludedDevices.remove(device.key) } else { excludedDevices.insert(device.key) } }
                        ))
                    }
                } label: {
                    Label(level < 2 ? devicesTitle : "\(deviceKeys.count - excludedDevices.count)", systemImage: "laptopcomputer.and.iphone")
                }
                .fixedSize()
                .help(devicesTitle)
                .sensitive(.personal)
            }
        }
    }

    @ViewBuilder
    private func inspector(_ row: TimelineRow) -> some View {
        switch row.origin {
        case .record(let ref):
            let info = snapshot.entries.first { $0.id == ref.streamID }?.info ?? BiomeStreamRegistry.info(for: row.source)
            RecordInspectorView(ref: ref, title: DossierDate.medium(row.date), subtitle: "\(row.source) · \(row.device)", info: info, onClose: { selected = nil })
        case .knowledge(let id):
            KnowledgeInspector(eventID: id, title: DossierDate.medium(row.date), subtitle: row.source, onClose: { selected = nil })
        }
    }
}
