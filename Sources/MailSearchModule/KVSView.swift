import SwiftUI
import DossierCore

/// (6) iCloud key-value cache — the local copy of every iCloud key-value store on the
/// account (apps' small synced settings, and several of Apple's own: recent mail
/// recipients, VIPs, account suggestions, block list, printers, Wi-Fi networks).
struct KVSView: View {
    @Environment(\.deepLink) private var deepLink
    @State private var selectedStore: String?
    @State private var listFilter = ""
    @State private var selected: KVSKey?
    @State private var keyFilter = ""
    @State private var widthClass = MSLayout.WidthClass.regular

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selectedStore, listFilter, selected, keyFilter)
        AsyncContent {
            guard let dir = MSPaths.kvs else { throw DossierError.missing("The iCloud key-value daemon (com.apple.kvs) has no container on this Mac.") }
            if case .inaccessible(let reason) = Paths.probe(dir) { throw DossierError.inaccessible(reason) }
            let stores = await KVSStore.stores()
            if stores.isEmpty { throw DossierError.missing("The iCloud key-value cache holds no stores. iCloud may be signed out.") }
            return stores
        } content: { stores in
            content(stores)
        }
    }

    private func current(_ stores: [KVSStoreInfo]) -> KVSStoreInfo? {
        if let selectedStore, let hit = stores.first(where: { $0.id == selectedStore }) { return hit }
        return stores.first
    }

    @ViewBuilder
    private func content(_ stores: [KVSStoreInfo]) -> some View {
        let active = current(stores)
        HStack(spacing: 0) {
            storeList(stores, active: active).frame(width: widthClass == .narrow ? 240 : 290)
            Divider()
            if let active {
                StorePane(store: active, filter: $keyFilter, selected: $selected).id(active.id)
                    .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                        if let selected { KeyInspector(store: active, key: selected) { self.selected = nil } }
                    }
            }
        }
        .tracksWidthClass($widthClass)
        .onChange(of: deepLink?.nonce, initial: true) { _, _ in
            guard let link = deepLink, !link.payload.isEmpty else { return }
            let parts = link.payload.components(separatedBy: "\t")
            guard parts.count >= 2, let store = stores.first(where: { $0.database.url.lastPathComponent == parts[0] && $0.identifier == parts[1] }) else { return }
            selectedStore = store.id
            keyFilter = ""
            if parts.count > 2, let pk = Int64(parts[2]) {
                Task {
                    if let data = try? await KVSStore.value(store, key: pk) {
                        let layout = KVSLayout.layout(for: store.identifier)
                        let name = (try? await KVSStore.keys(store, offset: 0, limit: KVSLayout.maxKeys, sort: nil, search: "", layout: layout).first { $0.id == pk })
                        selected = name ?? KVSKey(id: pk, key: "Key \(pk)", modified: nil, bytes: data.count, preview: "")
                    }
                }
            }
        }
    }

    private func storeList(_ stores: [KVSStoreInfo], active: KVSStoreInfo?) -> some View {
        let needle = listFilter.lowercased()
        let visible = stores.filter { needle.isEmpty || $0.identifier.lowercased().contains(needle) || ($0.highlight?.title.lowercased().contains(needle) ?? false) }
        let highlights = visible.filter { $0.highlight != nil }
        let databases = KVSStoreGroup.make(visible.filter { $0.highlight == nil })
        return VStack(spacing: 0) {
            FilterField("Filter stores", text: $listFilter)
            Divider()
            List(selection: Binding(get: { active?.id }, set: { if let id = $0 { selectedStore = id; selected = nil; keyFilter = "" } })) {
                if !highlights.isEmpty {
                    Section("Highlights") {
                        ForEach(highlights) { s in
                            MasterRow(symbol: s.highlight?.symbol ?? "icloud", title: s.highlight?.title ?? s.displayName, subtitle: s.database.title, count: Format.count(s.keys))
                                .tag(s.id)
                        }
                    }
                }
                ForEach(databases) { group in
                    Section("\(group.title) · \(group.stores.count) stores") {
                        ForEach(group.stores) { s in
                            MasterRow(symbol: s.identifier.hasPrefix("com.apple.") ? "apple.logo" : "app", title: s.displayName, count: Format.count(s.keys))
                                .tag(s.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }
}

private struct KVSStoreGroup: Identifiable {
    var id: String { title }
    let title: String
    let stores: [KVSStoreInfo]

    static func make(_ stores: [KVSStoreInfo]) -> [KVSStoreGroup] {
        var order: [String] = []
        var map: [String: [KVSStoreInfo]] = [:]
        for s in stores {
            if map[s.database.title] == nil { order.append(s.database.title) }
            map[s.database.title, default: []].append(s)
        }
        return order.map { KVSStoreGroup(title: $0, stores: map[$0] ?? []) }
    }
}

private struct StorePane: View {
    let store: KVSStoreInfo
    @Binding var filter: String
    @Binding var selected: KVSKey?

    /// Typed layout, for known stores small enough to be decoded as a whole.
    private var layout: KVSLayout? {
        store.keys <= KVSLayout.maxKeys ? KVSLayout.layout(for: store.identifier) : nil
    }

    var body: some View {
        let store = self.store
        VStack(spacing: 0) {
            PaneHeader(
                symbol: store.highlight?.symbol ?? "icloud",
                title: store.highlight?.title ?? store.displayName,
                subtitle: store.highlight?.explanation ?? "Key-value store \(store.identifier), synced through iCloud. \(store.database.explanation)"
            ) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Format.count(store.keys)) keys · \(Format.bytes(store.bytes))").font(.callout.monospacedDigit())
                    Text(store.range.map { DossierDate.range($0) } ?? store.database.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let layout {
                // Known value shape: decode the whole (small) store once, so every typed
                // column sorts and the filter matches names and addresses, not only keys.
                AsyncContent(reloadKey: store.id) {
                    try await KVSStore.keys(store, offset: 0, limit: KVSLayout.maxKeys, sort: nil, search: "", layout: layout)
                } content: { rows in
                    typedTable(rows, layout)
                }
            } else {
                rawTable
            }
            StoreFooter(store.database.url, note: "ZSYDMANAGEDKEYVALUE · \(store.identifier)")
        }
    }

    private func typedColumns(_ layout: KVSLayout) -> [PagedColumn<KVSKey>] {
        let level = store.highlight?.sensitivity ?? .personal
        var columns: [PagedColumn<KVSKey>] = layout.fields.enumerated().map { index, field in
            let sensitivity: Sensitivity = field.personal ? level : .low
            func value(_ row: KVSKey) -> KVSValue { index < row.values.count ? row.values[index] : .none }
            switch field.kind {
            case .date:
                return PagedColumn.date(field.title, id: field.id, width: field.width, secondary: field.secondary) { value($0).date }
            case .number:
                return PagedColumn(field.title, id: field.id, width: field.width, alignment: .trailing, secondary: field.secondary) { value($0).text }
            case .app:
                return PagedColumn(field.title, id: field.id, width: field.width, secondary: field.secondary) { row in
                    let bundle = value(row).text
                    return bundle.isEmpty ? "" : AppDirectory.name(bundle, unknown: bundle)
                }
                .cell { row in
                    let bundle = value(row).text
                    if !bundle.isEmpty { AppLabel(bundle: bundle, name: AppDirectory.name(bundle, unknown: bundle)).font(.callout) }
                }
            case .text:
                return PagedColumn(field.title, id: field.id, width: field.width, min: 60, sensitivity: sensitivity, secondary: field.secondary) { value($0).text }
            }
        }
        columns += [
            PagedColumn.date("Modified", id: "modified", width: 130, secondary: true, hiddenByDefault: true) { $0.modified },
            PagedColumn("Size", id: "bytes", width: 80, alignment: .trailing, secondary: true, hiddenByDefault: true) { Format.bytes($0.bytes) }
                .sortKey { Double($0.bytes) },
            PagedColumn("Key", id: "key", width: 120, min: 60, sensitivity: .personal, monospaced: true, secondary: true) { $0.key },
        ]
        return columns
    }

    private func typedTable(_ rows: [KVSKey], _ layout: KVSLayout) -> some View {
        PagedTable(
            rows: rows,
            columns: typedColumns(layout),
            searchPrompt: "Filter",
            reloadKey: "\(store.id)#\(rows.count)",
            exportName: "kvs-" + store.identifier,
            emptyTitle: "No Matching Entries",
            filter: $filter,
            initialSort: layout.initialSort.map { PageSort(columnID: $0, ascending: false) },
            onSelect: { selected = $0.count == 1 ? $0.first : nil }
        )
    }

    private var rawTable: some View {
        let store = self.store
        let level = store.highlight?.sensitivity ?? .personal
        return PagedTable(
            columns: [
                PagedColumn<KVSKey>("Key", id: "key", width: 280, min: 120, sensitivity: .personal, monospaced: true) { $0.key },
                PagedColumn("Value", id: "value", width: 420, min: 160, sortable: false, sensitivity: level) { $0.preview },
                PagedColumn.date("Modified", id: "modified", width: 150) { $0.modified },
                PagedColumn("Size", id: "bytes", width: 90, min: 80, alignment: .trailing, secondary: true) { Format.bytes($0.bytes) },
                PagedColumn("Row", id: "pk", width: 60, alignment: .trailing, sortable: false, secondary: true, hiddenByDefault: true) { String($0.id) },
            ],
            searchPrompt: "Filter keys",
            reloadKey: store.id,
            exportName: "kvs-" + store.identifier,
            filter: $filter,
            fetch: { req in try await KVSStore.keys(store, offset: req.offset, limit: req.limit, sort: req.sort, search: req.search) },
            count: { req in await KVSStore.keyCount(store, search: req.search) },
            onSelect: { selected = $0.count == 1 ? $0.first : nil }
        )
    }
}

private struct KeyInspector: View {
    let store: KVSStoreInfo
    let key: KVSKey
    let onClose: () -> Void

    private struct Loaded: Sendable {
        let data: Data
        /// Top-level entries of an untyped dictionary value, as labelled rows.
        let entries: [KeyValueItem]
    }

    /// Decoded fields of a store with a known value shape.
    private var typedItems: [KeyValueItem] {
        guard let layout = KVSLayout.layout(for: store.identifier), key.values.count == layout.fields.count else { return [] }
        let level = store.highlight?.sensitivity ?? .personal
        return zip(layout.fields, key.values).compactMap { field, value in
            var text = value.detail
            guard !text.isEmpty else { return nil }
            if field.kind == .app { text = AppDirectory.name(text, unknown: text) + " (" + text + ")" }
            return KeyValueItem(field.title, text, sensitivity: field.personal ? level : .low, id: "f:" + field.id)
        }
    }

    private var title: String {
        if let first = key.values.first?.text, !first.isEmpty { return first }
        return key.key
    }

    var body: some View {
        let store = self.store, key = self.key
        let level = store.highlight?.sensitivity ?? .personal
        let typed = typedItems
        InspectorPage(title: title, subtitle: store.highlight?.title ?? store.displayName, sensitivity: typed.isEmpty ? .personal : level, scrolls: false, onClose: onClose) {
            AsyncContent(reloadKey: "\(store.id)#\(key.id)") {
                let data = try await KVSStore.value(store, key: key.id)
                var entries: [KeyValueItem] = []
                if typed.isEmpty, data.count <= 262_144, let pairs = PlistDecoder.decodeAny(data)?.dict {
                    for pair in pairs.prefix(12) {
                        let text: String
                        switch pair.value {
                        case .dict, .array: text = MSFormat.preview(pair.value, max: 160)
                        case .date(let d): text = DossierDate.medium(d)
                        default: text = PlistDecoder.describe(pair.value)
                        }
                        entries.append(KeyValueItem(pair.key, text, sensitivity: level, id: "e:\(entries.count)"))
                    }
                }
                return Loaded(data: data, entries: entries)
            } content: { loaded in
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if !typed.isEmpty {
                                KeyValueGrid(typed)
                            } else if !loaded.entries.isEmpty {
                                KeyValueGrid(loaded.entries, valueLineLimit: 3)
                            }
                            InspectorGroupTitle("Record")
                            KeyValueGrid([
                                KeyValueItem("Key", key.key, sensitivity: .personal, monospaced: true),
                                KeyValueItem("Store", store.identifier, monospaced: true),
                                KeyValueItem("Synced As", store.database.title),
                                KeyValueItem("Modified", key.modified.map { DossierDate.medium($0) + " (" + DossierDate.relative($0) + ")" }),
                                KeyValueItem("Size", Format.bytes(key.bytes)),
                            ].filter { $0.value != "—" })
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 380)
                    .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    BlobInspector(data: loaded.data, title: "Raw Value", sensitivity: level)
                }
            }
        }
    }
}
