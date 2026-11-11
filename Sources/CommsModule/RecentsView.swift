import SwiftUI
import DossierCore

/// (8) Recents, VIPs & favourites — CoreRecents plus the iCloud key-value cache (mail
/// recents, VIP senders, favourite and blocked contacts).
struct RecentsView: View {
    @State private var source = RecentSource.coreRecents
    @State private var selected: RecentRow?
    @Environment(\.refreshToken) private var refreshToken

    private var note: String {
        switch source {
        case .coreRecents:
            return "Addresses this Mac remembers for auto-completion — people you mailed or invited who may not be in your contacts."
        case .kvs:
            return "Lists synced through iCloud's key-value service and cached here: mail recents, VIP senders, favourites and blocked contacts."
        }
    }

    private var footerURL: URL {
        switch source {
        case .coreRecents: return CommsPaths.recentsDB
        case .kvs: return CommsPaths.kvsDirectory ?? Paths.daemonContainers
        }
    }

    var body: some View {
        let token = refreshToken
        let source = source
        VStack(spacing: 0) {
            HeaderStrip {
                Picker("Source", selection: $source) {
                    ForEach(RecentSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                HeaderNote(note)
            }
            PagedTable(
                columns: columns(source),
                searchPrompt: "Filter names, addresses or lists",
                reloadKey: AnyHashable([AnyHashable(token), AnyHashable(source)]),
                exportName: "recents",
                emptyTitle: "No Entries",
                fetch: { request in try await Self.table(source, token).page(request) },
                count: { request in try await Self.table(source, token).count(request) },
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { inspector(selected) }
            }
            StoreFooter(footerURL, note: source == .coreRecents ? "recents ⨝ contacts" : "ZSYDMANAGEDKEYVALUE (binary plists)")
        }
        .onChange(of: source) { selected = nil }
    }

    private static func table(_ source: RecentSource, _ token: Int) async throws -> MemoryTable<RecentRow> {
        MemoryTable(
            rows: try await CommsCache.shared.recents(source, token),
            search: { [$0.name, $0.address, $0.category, AppNames.name($0.bundle), $0.kind, $0.detail].joined(separator: " ") },
            keys: [
                "category": .text { $0.category },
                "name": .text { $0.name.isEmpty ? $0.address : $0.name },
                "address": .text { $0.address },
                "kind": .text { $0.kind },
                "app": .text { AppNames.name($0.bundle) },
                "count": .number { Double($0.count) },
                "last": .number { $0.last?.timeIntervalSince1970 ?? 0 },
                "detail": .text { $0.detail },
            ])
    }

    private func columns(_ source: RecentSource) -> [PagedColumn<RecentRow>] {
        [
            PagedColumn<RecentRow>("List", id: "category", width: 130, min: 76) { $0.category }
                .cell { row in TagLabel(row.category, tint: tint(row.category)) },
            PagedColumn("Name", id: "name", width: 200, min: 90, sensitivity: .sensitive) { $0.name }
                .cell { row in
                    Text(row.name.isEmpty ? "—" : row.name).font(.callout.weight(.medium)).lineLimit(1)
                        .foregroundStyle(row.name.isEmpty ? .tertiary : .primary)
                },
            PagedColumn("Address", id: "address", width: 260, min: 100, sensitivity: .sensitive) { $0.address },
            PagedColumn("Kind", id: "kind", width: 90, secondary: true) { $0.kind },
            PagedColumn("App", id: "app", width: 150, min: 84, sensitivity: .personal) { $0.bundle.isEmpty ? "" : AppNames.name($0.bundle) },
            PagedColumn("Uses", id: "count", width: 56, alignment: .trailing) { $0.count > 0 ? Format.count($0.count) : "—" },
            PagedColumn("Last Used", id: "last", width: 150, min: 146) { DossierDate.sortable($0.last) },
            PagedColumn("Details", id: "detail", width: 220, sensitivity: .personal, secondary: true) { $0.detail },
        ]
    }

    private func tint(_ category: String) -> Color {
        switch category {
        case "Mail VIP": return .yellow
        case "Favourite": return .pink
        case "Blocked": return .red
        case "Calendar recent": return .orange
        case "FaceTime recent": return .green
        default: return .blue
        }
    }

    @ViewBuilder private func inspector(_ row: RecentRow) -> some View {
        InspectorPage(title: row.name.isEmpty ? row.address : row.name, subtitle: row.category, sensitivity: .sensitive, onClose: { selected = nil }) {
            KeyValueGrid([
                KeyValueItem("List", row.category),
                KeyValueItem("Name", row.name.isEmpty ? nil : row.name, sensitivity: .sensitive),
                KeyValueItem("Address", row.address, sensitivity: .sensitive, monospaced: true),
                KeyValueItem("Kind", row.kind.isEmpty ? nil : row.kind),
                KeyValueItem("App", row.bundle.isEmpty ? nil : AppNames.name(row.bundle), sensitivity: .personal),
                KeyValueItem("Bundle id", row.bundle.isEmpty ? nil : row.bundle, monospaced: true),
                KeyValueItem("Uses", row.count > 0 ? Format.count(row.count) : nil),
                KeyValueItem("Last used", row.last.map { "\(DossierDate.medium($0)) (\(DossierDate.relative($0)))" }),
                KeyValueItem("Details", row.detail.isEmpty ? nil : row.detail, sensitivity: .personal),
                KeyValueItem("Store", row.source, monospaced: true),
            ])
            Text(note).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
