import SwiftUI
import DossierCore

/// (a) Store browser: every known store root with size, file count, freshness and
/// availability; the inspector lists the databases inside and links to the SQLite explorer.
struct StoresSection: View {
    private struct Loaded: Sendable {
        let rows: [StoreRow]
        let databases: [DatabaseEntry]
        let streams: [StreamEntry]
    }

    @State private var selected: StoreRow?
    @Environment(\.navigate) private var navigate
    @Environment(\.refreshToken) private var refreshToken

    var body: some View {
        let token = refreshToken
        AsyncContent(reloadKey: token) {
            await RawCatalog.shared.sync(token: token)
            async let rows = RawCatalog.shared.storeRows()
            async let databases = RawCatalog.shared.databases()
            async let streams = RawCatalog.shared.streams()
            return await Loaded(rows: rows, databases: databases, streams: streams)
        } content: { loaded in
            VStack(spacing: 0) {
                StatTileRow(stats(loaded))
                    .padding(Metrics.pagePadding)
                Divider()
                PagedTable(
                    rows: loaded.rows,
                    columns: columns(loaded),
                    searchPrompt: "Filter stores",
                    reloadKey: loaded.rows.count,
                    exportName: "stores",
                    onSelect: { selected = $0.first }
                )
                .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                    if let selected { inspector(selected, loaded) }
                }
            }
        }
    }

    private func stats(_ loaded: Loaded) -> [Stat] {
        let available = loaded.rows.filter { $0.availability.isAvailable }
        let blocked = loaded.rows.filter { if case .inaccessible = $0.availability { return true } else { return false } }
        let bytes = available.reduce(Int64(0)) { $0 + $1.bytes }
        let records = loaded.streams.reduce(0) { $0 + $1.stats.records }
        return [
            Stat("Stores", "\(available.count) of \(loaded.rows.count)", caption: blocked.isEmpty ? "all readable" : "\(blocked.count) without access", symbol: "externaldrive", tint: blocked.isEmpty ? .accentColor : .orange),
            Stat("On Disk", Format.bytes(bytes), caption: "\(Format.count(available.reduce(0) { $0 + $1.files })) files", symbol: "internaldrive"),
            Stat("SQLite Databases", Format.count(loaded.databases.count), caption: Format.bytes(loaded.databases.reduce(Int64(0)) { $0 + $1.size }), symbol: "cylinder.split.1x2"),
            Stat("Biome Streams", Format.count(loaded.streams.count), caption: "\(Format.count(records)) records", symbol: "waveform.path.ecg"),
        ]
    }

    private func columns(_ loaded: Loaded) -> [PagedColumn<StoreRow>] {
        let dbCounts = Dictionary(grouping: loaded.databases, by: \.storeID).mapValues(\.count)
        return [
            PagedColumn<StoreRow>("Store", width: 220, min: 150) { $0.store.title }
                .cell { row in
                    HStack(spacing: 6) {
                        Circle().fill(color(row.availability)).frame(width: 7, height: 7)
                        Text(row.store.title).font(.callout.weight(.medium)).lineLimit(1)
                    }
                },
            PagedColumn("Category", width: 150, min: 90, secondary: true) { $0.store.category.rawValue },
            PagedColumn("Contents", width: 300, min: 120, secondary: true) { $0.store.detail },
            PagedColumn("Status", width: 90, min: 76) { $0.availability.label },
            PagedColumn("Size", width: 86, min: 84, alignment: .trailing) { $0.availability.isAvailable ? Format.bytes($0.bytes) : "—" },
            PagedColumn("Files", width: 60, alignment: .trailing) { $0.availability.isAvailable ? Format.count($0.files) : "—" },
            PagedColumn("Databases", width: 80, alignment: .trailing) { Format.count(dbCounts[$0.store.id] ?? 0) },
            PagedColumn("Last Modified", width: 150, min: 146) { DossierDate.sortable($0.newest) },
            PagedColumn("Path", width: 320, sensitivity: .personal, monospaced: true, secondary: true, hiddenByDefault: true) { Format.tildePath($0.store.url) },
        ]
    }

    private func color(_ availability: Availability) -> Color {
        switch availability {
        case .available: return .green
        case .missing: return .gray
        case .inaccessible: return .orange
        }
    }

    @ViewBuilder private func inspector(_ row: StoreRow, _ loaded: Loaded) -> some View {
        let dbs = loaded.databases.filter { $0.storeID == row.store.id }
        InspectorPage(title: row.store.title, subtitle: row.store.category.rawValue, onClose: { selected = nil }) {
            Text(row.store.detail).font(.callout).foregroundStyle(.secondary)
            KeyValueGrid([
                KeyValueItem("Status", statusText(row.availability)),
                KeyValueItem("Size", row.availability.isAvailable ? Format.bytes(row.bytes) : nil),
                KeyValueItem("Files", row.availability.isAvailable ? Format.count(row.files) : nil),
                KeyValueItem("Modified", row.newest.map { DossierDate.medium($0) + " (" + DossierDate.relative($0) + ")" }),
                KeyValueItem("Path", Format.tildePath(row.store.url), sensitivity: .personal, monospaced: true),
            ])
            HStack {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.store.url]) }
                Button("Copy Path") { Pasteboard.copy(row.store.url.path) }
            }
            .controlSize(.small)
            if !dbs.isEmpty {
                InspectorGroupTitle("Databases (\(dbs.count))")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(dbs.prefix(200)) { db in
                        Button {
                            navigate?(DeepLink(sectionID: "raw.sqlite", payload: db.url.path))
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "cylinder").foregroundStyle(.secondary).imageScale(.small)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(db.name).font(.callout).lineLimit(1)
                                    if !db.folder.isEmpty {
                                        Text(db.folder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                                    }
                                }
                                Spacer(minLength: 4)
                                Text(Format.bytes(db.size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open in SQLite Explorer")
                        Divider()
                    }
                }
            }
        }
    }

    private func statusText(_ availability: Availability) -> String {
        switch availability {
        case .available: return "Readable"
        case .missing: return "Not present on this Mac"
        case .inaccessible(let reason): return "No access (\(reason))"
        }
    }
}
