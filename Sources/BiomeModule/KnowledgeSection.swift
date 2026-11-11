import SwiftUI
import DossierCore

/// (4) knowledgeC: the legacy CoreDuet event store, stream by stream.
struct KnowledgeSection: View {
    @State private var selectedName: String?
    @State private var filter = ""
    @State private var showBookkeeping = false
    @State private var eventFilter = ""
    /// Reported by the events pane; lets the split tuck the stream list away when narrow.
    @State private var inspectorOpen = false
    @Environment(\.deepLink) private var deepLink

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selectedName, filter, showBookkeeping, eventFilter, inspectorOpen)
        AsyncContent(emptyTitle: "No Events", emptySymbol: "clock.badge.questionmark") {
            try await KnowledgeStore.streams()
        } isEmpty: { $0.isEmpty } content: { streams in
            let selected = streams.first { $0.name == selectedName } ?? streams.first { !$0.isBookkeeping } ?? streams.first
            MasterDetailSplit(masterWidth: 280, compactMasterWidth: 230, inspectorOpen: inspectorOpen) {
                list(streams, selected: selected)
            } detail: {
                if let selected {
                    KnowledgeEventsView(stream: selected, eventFilter: $eventFilter, inspectorOpen: $inspectorOpen).id(selected.name)
                } else {
                    StatePlaceholder(title: "Select a Stream", symbol: "clock")
                }
            }
            .onChange(of: deepLink?.nonce, initial: true) { _, _ in
                guard let link = deepLink, link.sectionID == "biome.knowledge", !link.payload.isEmpty else { return }
                let parts = link.payload.components(separatedBy: "\t")
                if streams.contains(where: { $0.name == parts[0] }) {
                    selectedName = parts[0]
                    eventFilter = parts.count > 1 ? parts[1] : ""
                }
            }
        }
    }

    private func list(_ streams: [KnowledgeStream], selected: KnowledgeStream?) -> some View {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let visible = streams.filter {
            (showBookkeeping || !$0.isBookkeeping || $0.name == selected?.name) && (needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle))
        }
        let hidden = streams.filter(\.isBookkeeping).count
        return VStack(spacing: 0) {
            PaneFilter(prompt: "Filter streams", text: $filter) {
                Toggle("Sync", isOn: $showBookkeeping)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .help("Also list the \(hidden) sync bookkeeping streams (bookmarks and windows per synced device)")
            }
            Divider()
            List(selection: Binding(get: { selected?.name }, set: { if let n = $0 { selectedName = n; eventFilter = "" } })) {
                ForEach(visible) { stream in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stream.isBookkeeping ? bookkeepingName(stream.name) : stream.name)
                                .font(.callout).lineLimit(1).truncationMode(.middle)
                            Text(subtitle(stream)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(Format.compact(stream.count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(stream.name)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            PaneFooter("\(visible.count) of \(streams.count) streams · \(Format.count(streams.reduce(0) { $0 + $1.count })) events")
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    /// The trailing device UUID of bookkeeping streams is personal: show the kind only.
    private func bookkeepingName(_ name: String) -> String {
        let parts = name.split(separator: "/")
        return "/" + (parts.first.map(String.init) ?? name) + "/…" + (parts.last.map { String($0.suffix(4)) } ?? "")
    }

    private func subtitle(_ stream: KnowledgeStream) -> String {
        var parts: [String] = []
        if let last = stream.last { parts.append("until " + DossierDate.day(last)) }
        if !stream.devices.isEmpty { parts.append("from " + stream.devices.prefix(2).joined(separator: ", ")) }
        return parts.isEmpty ? "no dated events" : parts.joined(separator: " · ")
    }
}

private struct KnowledgeEventsView: View {
    let stream: KnowledgeStream
    @Binding var eventFilter: String
    @Binding var inspectorOpen: Bool
    @State private var selected: KnowledgeEvent?

    /// nil until the first page has been inspected; true when (nearly) every event of that
    /// page carries the same structured metadata (e.g. the Screen Time flags of `/app/usage`).
    @State private var uniformMetadata: Bool?

    private var columns: [PagedColumn<KnowledgeEvent>] {
        let name = stream.name
        let valueIsApp = KnowledgeStreamRegistry.valueIsApp(name)
        let value = PagedColumn<KnowledgeEvent>(KnowledgeStreamRegistry.valueTitle(for: name), id: "value", width: valueIsApp ? 300 : 240, min: 80, sensitivity: .personal) { event in
            let shown = KnowledgeStreamRegistry.displayValue(event.value, stream: name)
            return shown == event.value ? shown : (valueIsApp ? "\(shown) (\(event.value))" : shown)
        }
        return [
            PagedColumn<KnowledgeEvent>("Start", id: "start", width: 150, min: 140, max: 190) { DossierDate.sortable($0.start) },
            PagedColumn("End", id: "end", width: 150, min: 140, secondary: true, hiddenByDefault: true) { DossierDate.sortable($0.end) },
            PagedColumn("Duration", id: "duration", width: 80, min: 60, max: 110, alignment: .trailing) { $0.duration.map { Format.duration($0) } ?? "" },
            valueIsApp ? value.cell { AppCell(identifier: $0.value) } : value,
            PagedColumn<KnowledgeEvent>("Source App", id: "bundle", width: 170, sortable: false, sensitivity: .personal, hiddenByDefault: stream.devices.isEmpty) { event in
                let shown = RecordDecoder.appName(event.bundle)
                return shown == event.bundle ? shown : "\(shown) (\(event.bundle))"
            }.cell { event in
                if RecordDecoder.looksLikeBundleID(event.bundle) { AppLabel(bundle: event.bundle) } else { Text(event.bundle).lineLimit(1) }
            },
            PagedColumn("Device", id: "device", width: 100, sortable: false, secondary: true, hiddenByDefault: stream.devices.isEmpty) { $0.device },
            // Constant metadata reads as a debug dump in every row; the inspector shows it.
            PagedColumn("Structured Metadata", id: "metadata", width: 560, min: 160, sortable: false, sensitivity: .sensitive, secondary: true,
                        hiddenByDefault: uniformMetadata ?? true) { $0.metadata },
            PagedColumn("Row", id: "id", width: 70, alignment: .trailing, secondary: true, hiddenByDefault: true) { String($0.id) },
        ]
    }

    var body: some View {
        let name = stream.name
        VStack(spacing: 0) {
            HeaderStrip {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(stream.isBookkeeping ? "Sync bookkeeping" : name).font(.headline).lineLimit(1).truncationMode(.middle)
                            .layoutPriority(1)
                        // Totals: complete, then the count only, then nothing — never a squeezed ellipsis.
                        FittingText([
                            [
                                "\(Format.count(stream.count)) events",
                                stream.withMetadata > 0 ? "\(Format.count(stream.withMetadata)) with metadata" : nil,
                                (stream.first != nil && stream.last != nil) ? DossierDate.range(stream.first!...stream.last!) : nil,
                            ].compactMap { $0 }.joined(separator: " · "),
                            "\(Format.count(stream.count)) events",
                        ], orNothing: true)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Text(KnowledgeStreamRegistry.summary(for: name))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(KnowledgeStreamRegistry.summary(for: name))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if uniformMetadata == nil {
                // One cheap query decides the default column set before the table appears
                // (so the metadata column does not flash in or out).
                LoadingPlaceholder("Loading events…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: name) {
                        let uniform = await SnapshotReadiness.track { await KnowledgeStore.metadataIsUniform(stream: name) }
                        if !Task.isCancelled { uniformMetadata = uniform }
                    }
            } else {
            PagedTable(
                columns: columns,
                pageSize: 200,
                searchPrompt: "Filter by value or source app",
                reloadKey: name,
                exportName: "knowledgeC" + name.replacingOccurrences(of: "/", with: "-"),
                emptyTitle: "No Events",
                filter: $eventFilter,
                fetch: { request in
                    try await KnowledgeStore.events(stream: name, search: request.search, sort: request.sort, offset: request.offset, limit: request.limit)
                },
                count: { request in try await KnowledgeStore.count(stream: name, search: request.search) },
                onSelect: { selected = $0.count == 1 ? $0.first : nil }
            )
            // The inspector gives up width (down to its minimum) before the table drops below this.
            .frame(minWidth: 400)
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected {
                    KnowledgeInspector(eventID: selected.id, title: DossierDate.medium(selected.start), subtitle: stream.isBookkeeping ? "Sync bookkeeping" : name,
                                       onClose: { self.selected = nil })
                        .id(selected.id)
                }
            }
            }
            StoreFooter(KnowledgeStore.url, note: "ZOBJECT ⨝ ZSTRUCTUREDMETADATA ⨝ ZSOURCE")
        }
        .onChange(of: selected != nil, initial: true) { _, open in inspectorOpen = open }
    }
}

/// Inspector of one knowledgeC event: object columns, structured metadata, decoded blobs.
struct KnowledgeInspector: View {
    let eventID: Int64
    let title: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        InspectorPage(title: title, subtitle: subtitle, onClose: onClose) {
            AsyncContent(reloadKey: eventID) {
                try await KnowledgeStore.detail(id: eventID)
            } content: { detail in
                VStack(alignment: .leading, spacing: 14) {
                    InspectorGroupTitle("Event")
                    KeyValueGrid(detail.items)
                    if !detail.metadata.isEmpty {
                        InspectorGroupTitle("Structured metadata")
                        KeyValueGrid(detail.metadata, valueLineLimit: 10)
                    }
                    ForEach(Array(detail.blobs.enumerated()), id: \.offset) { _, blob in
                        InspectorGroupTitle("\(blob.name) · \(Format.bytes(blob.data.count))")
                        BlobInspector(data: blob.data, title: blob.name)
                            .frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    }
                    Text("knowledgeC.db is the older CoreDuet event store. Biome streams have replaced most of it; what remains here is mainly app usage on this Mac and intents synced from other devices.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
