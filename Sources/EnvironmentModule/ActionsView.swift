import SwiftUI
import DossierCore

/// Section 4 — one chronological log of everything the system recorded you *doing* at the
/// system level: App Intents, menu commands, documents, screenshots, settings panes,
/// authentication dialogs and searches.
struct ActionsView: View {
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var kind: ActionKind?
    @State private var filter = ""
    @State private var selected: ActionRow?

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (kind, filter, selected)
        let token = refreshToken
        AsyncContent(reloadKey: token, emptyTitle: "No Actions Recorded", emptySymbol: "bolt.slash") {
            try await ActionsLoader.load(token: token)
        } isEmpty: { $0.rows.isEmpty } content: { data in
            content(data)
        }
        .task(id: deepLink?.nonce) {
            guard let link = deepLink, !link.payload.isEmpty else { return }
            guard let data = try? await ActionsLoader.load(token: token), let row = data.rows.first(where: { $0.id == link.payload }) else { return }
            kind = nil
            filter = row.title.trimmingCharacters(in: CharacterSet(charactersIn: "“”"))
            selected = row
        }
    }

    private func content(_ data: ActionsData) -> some View {
        let rows = kind.map { k in data.rows.filter { $0.kind == k } } ?? data.rows
        let chips = [Chip(id: "", title: "All", symbol: nil, count: data.rows.count)]
            + ActionKind.allCases.filter { (data.counts[$0] ?? 0) > 0 }.map { Chip(id: $0.rawValue, title: $0.rawValue, symbol: $0.symbol, count: data.counts[$0]) }
        return VStack(spacing: 0) {
            HeaderStrip {
                ChipBar(chips: chips, isOn: { $0 == (kind?.rawValue ?? "") }, toggle: { id in
                    kind = ActionKind(rawValue: id)
                    selected = nil
                })
            }
            PagedTable(
                rows: rows,
                columns: [
                    PagedColumn<ActionRow>("Time", id: "time", width: 150, min: 140) { DossierDate.sortable($0.date) },
                    PagedColumn("Kind", id: "kind", width: 120) { $0.kind.rawValue }.cell { row in
                        Label(row.kind.rawValue, systemImage: row.kind.symbol).labelStyle(.titleAndIcon).lineLimit(1)
                    },
                    PagedColumn("Action", id: "title", width: 280, sensitivity: .personal) { $0.title },
                    PagedColumn("Details", id: "detail", width: 320, sensitivity: .personal) { $0.detail },
                    PagedColumn("App", id: "app", width: 180, sensitivity: .personal) { EnvFormat.appName($0.app) }.cell { row in
                        if !row.app.isEmpty { AppLabel(bundle: EnvFormat.bundleID(row.app), name: EnvFormat.appName(row.app)).font(.callout) }
                    },
                    PagedColumn("Bundle ID", id: "bundle", width: 220, sensitivity: .personal, monospaced: true, secondary: true, hiddenByDefault: true) { $0.app },
                    PagedColumn("Device", id: "device", width: 130, secondary: true, hiddenByDefault: true) { $0.device },
                    PagedColumn("Source", id: "store", width: 200, secondary: true, hiddenByDefault: true) { $0.store },
                ].readableMinimums(),
                searchPrompt: "Filter actions",
                reloadKey: AnyHashable([AnyHashable(kind?.rawValue ?? ""), AnyHashable(data.rows.count), AnyHashable(refreshToken)]),
                exportName: "actions-log",
                emptyTitle: "No Matching Actions",
                filter: $filter,
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { ActionInspector(row: selected) { self.selected = nil } }
            }
            StoreFooter(Paths.biomeRestrictedStreams, note: "Biome streams · linkd ActionTranscript · knowledgeC /app/intents")
        }
    }
}

private struct ActionInspector: View {
    let row: ActionRow
    let onClose: () -> Void

    var body: some View {
        InspectorPage(title: row.title, subtitle: row.kind.rawValue, sensitivity: .personal, onClose: onClose) {
            KeyValueGrid([
                KeyValueItem("When", DossierDate.medium(row.date) + " (" + DossierDate.relative(row.date) + ")"),
                KeyValueItem("App", row.app.isEmpty ? nil : EnvFormat.appName(row.app), sensitivity: .personal),
                KeyValueItem("Bundle ID", row.app.isEmpty || EnvFormat.appName(row.app) == row.app ? nil : row.app, sensitivity: .personal, monospaced: true),
                KeyValueItem("Recorded on", row.device),
                KeyValueItem("Store", row.store),
            ])
            if !row.detail.isEmpty {
                Text(row.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).sensitive(.personal)
            }
            InspectorGroupTitle("Decoded Parameters")
            KeyValueGrid(row.params.items(sensitivity: .personal), valueLineLimit: 8)
            Explainer(row.kind.explanation)
            if row.ref != .none {
                InspectorGroupTitle("Raw Record")
                RawRecordView(ref: row.ref, title: row.store)
            }
        }
    }
}
