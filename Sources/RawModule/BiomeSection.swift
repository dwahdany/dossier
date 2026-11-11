import SwiftUI
import DossierCore

/// One record row of the generic stream browser (payload is loaded on demand).
struct RecordRow: Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let device: BiomeDevice
    let state: SEGBFile.State
    let length: Int
    let preview: String
    let segmentURL: URL
    let entryIndex: Int
    let crc: UInt32
    let kind: String
}

/// Pages through the records of one stream. Keeps the (memory-mapped) segment files and a
/// compact index of matching records; payloads are copied only for the requested page.
actor StreamRecordSource {
    private struct Ref { let segment: Int; let entry: Int }

    let stream: BiomeStream
    private var segmentsByDevice: [String: [BiomeSegment]] = [:]
    private var files: [String: SEGBFile] = [:]
    private var cacheKey: String?
    private var cache: [Ref] = []
    private var cacheSegments: [BiomeSegment] = []

    init(stream: BiomeStream) { self.stream = stream }

    private func file(_ segment: BiomeSegment) -> SEGBFile? {
        if let f = files[segment.id] { return f }
        guard let f = try? SEGBFile(url: segment.url) else { return nil }
        files[segment.id] = f
        return f
    }

    /// Newest-first list of live records matching the device / search filter.
    private func refs(device: BiomeDevice?, search: String) -> ([Ref], [BiomeSegment]) {
        let key = (device?.identifier ?? (device == nil ? "*" : "local")) + "\u{1}" + search
        if key == cacheKey { return (cache, cacheSegments) }
        let segments = Array(stream.dataSegments(device: device).reversed())
        var out: [Ref] = []
        for (si, segment) in segments.enumerated() {
            if Task.isCancelled { break }
            guard let file = file(segment) else { continue }
            for entry in file.entries.reversed() where entry.state.isLive {
                if !search.isEmpty {
                    let text = String(decoding: file.payload(entry), as: UTF8.self)
                    if text.range(of: search, options: [.caseInsensitive]) == nil { continue }
                }
                out.append(Ref(segment: si, entry: entry.index))
            }
        }
        cacheKey = key
        cache = out
        cacheSegments = segments
        return (out, segments)
    }

    func count(device: BiomeDevice?, search: String) -> Int { refs(device: device, search: search).0.count }

    func page(device: BiomeDevice?, search: String, ascending: Bool, offset: Int, limit: Int) -> [RecordRow] {
        let (all, segments) = refs(device: device, search: search)
        guard offset < all.count else { return [] }
        let upper = min(all.count, offset + limit)
        var rows: [RecordRow] = []
        rows.reserveCapacity(upper - offset)
        for i in offset..<upper {
            let ref = ascending ? all[all.count - 1 - i] : all[i]
            let segment = segments[ref.segment]
            guard let file = file(segment), ref.entry < file.entries.count else { continue }
            let entry = file.entries[ref.entry]
            let payload = file.payload(entry)
            let (preview, kind) = StreamRecordSource.describe(payload)
            rows.append(RecordRow(
                id: "\(segment.device.identifier ?? "local")/\(segment.url.lastPathComponent)#\(entry.index)",
                timestamp: entry.timestamp, device: segment.device, state: entry.state,
                length: entry.length, preview: preview,
                segmentURL: segment.url, entryIndex: entry.index, crc: entry.crc, kind: kind
            ))
        }
        return rows
    }

    func payload(of row: RecordRow) -> Data {
        guard let segment = stream.segments.first(where: { $0.url == row.segmentURL }), let file = file(segment),
              row.entryIndex < file.entries.count else { return Data() }
        return file.payload(file.entries[row.entryIndex])
    }

    func crcMatches(_ row: RecordRow) -> Bool {
        guard let segment = stream.segments.first(where: { $0.url == row.segmentURL }), let file = file(segment),
              row.entryIndex < file.entries.count else { return false }
        return file.crcMatches(file.entries[row.entryIndex])
    }

    /// A one-line preview: the string leaves of the protobuf payload, or the blob kind.
    static func describe(_ payload: Data) -> (preview: String, kind: String) {
        if payload.isEmpty { return ("", "empty") }
        if let message = ProtoMessage(payload), !message.fields.isEmpty {
            let strings = message.allStrings(limit: 12).filter { $0.count > 1 }
            if !strings.isEmpty {
                return (Format.oneLine(strings.joined(separator: "  ·  "), max: 260), "protobuf")
            }
            return ("\(message.fields.count) fields", "protobuf")
        }
        let kind = BlobSniffer.sniff(payload)
        if case .text = kind { return (Format.oneLine(String(decoding: payload, as: UTF8.self), max: 260), "text") }
        return ("", kind.label)
    }
}

/// (c) Generic Biome stream explorer: all streams with device, size, record count and time
/// range; records with timestamp, decoded protobuf tree and hex.
struct BiomeSection: View {
    private struct Loaded: Sendable {
        let streams: [StreamEntry]
        let peers: [String: BiomeDevicePeer]
    }

    @State private var selectedID: String?
    @State private var filter = ""
    @State private var hideEmpty = true
    @Environment(\.deepLink) private var deepLink
    @Environment(\.refreshToken) private var refreshToken

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selectedID, filter, hideEmpty)
        let token = refreshToken
        AsyncContent(reloadKey: token, emptyTitle: "No Biome Streams", emptySymbol: "waveform.path.ecg") {
            await RawCatalog.shared.sync(token: token)
            async let streams = RawCatalog.shared.streams()
            async let peers = RawCatalog.shared.devicePeers()
            return await Loaded(streams: streams, peers: peers)
        } isEmpty: { $0.streams.isEmpty } content: { loaded in
            let selected = loaded.streams.first { $0.id == selectedID } ?? defaultStream(loaded.streams)
            // The stream list gives up width in a narrow window so the records keep theirs.
            ExplorerPanesLayout(ideal: [300], minimum: [210], comfortableContent: 520) {
                streamList(loaded, selected: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PaneSeparator()
                Group {
                    if let selected {
                        StreamDetail(entry: selected, peers: loaded.peers).id(selected.id)
                    } else {
                        StatePlaceholder(title: "Select a Stream", symbol: "waveform.path.ecg")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: deepLink?.nonce, initial: true) { _, _ in
                if let link = deepLink, link.sectionID == "raw.biome", !link.payload.isEmpty {
                    if let match = loaded.streams.first(where: { $0.id == link.payload || $0.stream.name == link.payload }) {
                        selectedID = match.id
                        hideEmpty = false
                    }
                }
            }
        }
    }

    private func defaultStream(_ streams: [StreamEntry]) -> StreamEntry? {
        streams.max { $0.stats.records < $1.stats.records } ?? streams.first
    }

    private func streamList(_ loaded: Loaded, selected: StreamEntry?) -> some View {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let visible = loaded.streams.filter {
            (!hideEmpty || $0.stats.records > 0 || $0.id == selected?.id) &&
            (needle.isEmpty || $0.stream.name.localizedCaseInsensitiveContains(needle) || $0.origin.localizedCaseInsensitiveContains(needle))
        }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                PaneFilterField(prompt: "Filter streams", text: $filter)
                Toggle("Non-empty", isOn: $hideEmpty)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .padding(.trailing, 8)
                    .help("Hide streams without records")
            }
            Divider()
            List(selection: Binding(get: { selected?.id }, set: { selectedID = $0 })) {
                ForEach(visible) { entry in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.stream.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 4) {
                                Text(entry.origin).lineLimit(1)
                                if entry.remoteDevices > 0 {
                                    Text("· \(entry.remoteDevices) remote")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(entry.stats.records > 0 ? Format.compact(entry.stats.records) : "—")
                            .font(.caption)
                            .foregroundStyle(entry.stats.records > 0 ? .secondary : .tertiary)
                            .monospacedDigit()
                    }
                    .tag(entry.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            PaneFooter("\(visible.count) of \(loaded.streams.count) streams · \(Format.count(loaded.streams.reduce(0) { $0 + $1.stats.records })) records")
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }
}

private struct StreamDetail: View {
    let entry: StreamEntry
    let peers: [String: BiomeDevicePeer]

    /// "all" | "local" | remote device identifier
    @State private var deviceKey = "all"
    @State private var selected: RecordRow?
    @State private var source: StreamRecordSource

    init(entry: StreamEntry, peers: [String: BiomeDevicePeer]) {
        self.entry = entry
        self.peers = peers
        _source = State(initialValue: StreamRecordSource(stream: entry.stream))
    }

    private var device: BiomeDevice? {
        switch deviceKey {
        case "all": return nil
        case "local": return .local
        default: return .remote(deviceKey)
        }
    }

    private func deviceLabel(_ device: BiomeDevice) -> String {
        switch device {
        case .local: return "This Mac"
        case .remote(let id): return peers[id]?.displayName ?? "Remote device"
        }
    }

    private var columns: [PagedColumn<RecordRow>] {
        [
            PagedColumn("Time", id: "time", width: 160, min: 150, sortable: true) { DossierDate.sortable($0.timestamp) },
            PagedColumn("Device", width: 120, min: 80, sortable: false, sensitivity: .personal, secondary: true) { deviceLabel($0.device) },
            PagedColumn("Size", width: 70, min: 64, alignment: .trailing, sortable: false, secondary: true) { Format.bytes($0.length) },
            PagedColumn("Kind", width: 70, sortable: false, secondary: true, hiddenByDefault: true) { $0.kind },
            PagedColumn("State", width: 70, sortable: false, secondary: true, hiddenByDefault: true) { $0.state.label },
            PagedColumn("Segment", width: 150, sortable: false, monospaced: true, secondary: true, hiddenByDefault: true) { "\($0.segmentURL.lastPathComponent) #\($0.entryIndex)" },
            PagedColumn("Content (decoded strings)", id: "content", width: 620, sortable: false, sensitivity: .sensitive) { $0.preview },
        ]
    }

    var body: some View {
        let stats = entry.stats
        let source = self.source
        let device = self.device
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.stream.name).font(.headline).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        ForEach(stats.versions.sorted(), id: \.self) { TagLabel("SEGB v\($0)", tint: .teal) }
                    }
                    Text([
                        "\(Format.count(stats.records)) records",
                        stats.deleted > 0 ? "\(Format.count(stats.deleted)) deleted" : nil,
                        "\(stats.segments) segment\(stats.segments == 1 ? "" : "s")",
                        Format.bytes(stats.bytes),
                        stats.timeRange.map { DossierDate.range($0) },
                    ].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if entry.stream.devices.count > 1 {
                    Picker("Device", selection: $deviceKey) {
                        Text("All Devices").tag("all")
                        ForEach(entry.stream.devices, id: \.self) { d in
                            Text(deviceLabel(d)).tag(d.identifier ?? "local")
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .sensitive(.personal)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            Divider()
            PagedTable(
                columns: columns,
                pageSize: 200,
                searchPrompt: "Search record contents",
                reloadKey: deviceKey,
                exportName: entry.stream.name,
                emptyTitle: "No Records",
                fetch: { request in
                    await source.page(device: device, search: request.search, ascending: request.sort?.ascending ?? false, offset: request.offset, limit: request.limit)
                },
                count: { request in await source.count(device: device, search: request.search) },
                onSelect: { selected = $0.count == 1 ? $0.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected {
                    RecordInspector(row: selected, deviceLabel: deviceLabel(selected.device), source: source, onClose: { self.selected = nil })
                        .id(selected.id)
                }
            }
            StoreFooter(entry.stream.url, note: "read-only · mmap")
        }
    }
}

private struct RecordInspector: View {
    let row: RecordRow
    let deviceLabel: String
    let source: StreamRecordSource
    let onClose: () -> Void

    private struct Loaded: Sendable { let payload: Data; let crcOK: Bool }

    var body: some View {
        InspectorPage(title: DossierDate.medium(row.timestamp), subtitle: deviceLabel, scrolls: false, onClose: onClose) {
            AsyncContent(reloadKey: row.id) {
                Loaded(payload: await source.payload(of: row), crcOK: await source.crcMatches(row))
            } content: { loaded in
                VStack(spacing: 0) {
                    KeyValueGrid([
                        KeyValueItem("Timestamp", DossierDate.iso(row.timestamp)),
                        KeyValueItem("State", row.state.label),
                        KeyValueItem("Payload", "\(Format.bytes(row.length)) · \(row.kind)"),
                        KeyValueItem("CRC-32", String(format: "%08x", row.crc) + (loaded.crcOK ? " ✓" : " ✗ mismatch"), monospaced: true),
                        KeyValueItem("Segment", "\(row.segmentURL.lastPathComponent) #\(row.entryIndex)", monospaced: true),
                    ])
                    .padding(12)
                    Divider()
                    BlobInspector(data: loaded.payload, title: "Payload")
                }
            }
        }
    }
}
